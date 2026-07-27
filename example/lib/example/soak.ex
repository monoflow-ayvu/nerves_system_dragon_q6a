defmodule Example.Soak do
  @moduledoc """
  Overnight soak test: run inference back-to-back forever and log thermals and
  throughput to `/data` once a minute.

  ## Running it

      Example.Soak.enable()     # starts now AND on every future boot
      Example.Soak.status()
      Example.Soak.disable()    # stops now and clears the boot flag

  `enable/1` writes `/data/soak.enabled`, and `Example.Application` starts this
  process at boot whenever that file exists. That matters for an unattended run:
  if the board reboots at 3am - watchdog, power blip, an OTA - the soak resumes by
  itself instead of leaving a gap until morning.

  ## What it logs

  A CSV at `/data/soak.csv`, appended one row per minute, with a header written
  when the file is created. Columns:

    * `run_started_at`, `sampled_at` - wall clock. Note that early rows can carry
      a wrong wall time: NTP has not necessarily synced when the app starts, so
      trust `uptime_s` for ordering and use `run_started_at` to group a run.
    * `uptime_s`, `elapsed_s`
    * `iters`, `fps`, `mean_us`, `min_us`, `max_us`, `errors` - inference in the
      last interval only, so throttling shows up as a falling `fps` over the night.
    * one column per thermal zone, in millidegrees C, named after the zone's own
      `type` - including `nspss0-thermal`/`nspss1-thermal`, which are the Hexagon
      NSP subsystem the NPU runs on, and `msm-skin-thermal`, the closest thing to
      a case temperature.
    * `cpufreq_policyN` - current kHz per policy.
    * `cool_<device>` - `cur_state` of each cooling device (`cpufreq-cpu0/4/7`,
      `devfreq-3d00000.gpu`). These are the direct evidence of throttling: they
      sit at 0 until something starts limiting, so a nonzero value pinpoints when
      and which domain.

  The image is decoded, resized and letterboxed **once** at startup; the loop only
  calls `Ortex.run/2`. So `fps` here is model throughput under sustained load and
  it isolates NPU behaviour from JPEG decoding. It runs a few percent below
  `Example.Yolo.bench/2` (~24 fps vs ~28) because each iteration also sends a
  message to this process for the latency accounting - constant overhead, so the
  trend across the night is still the thing to read.

  ## Reading it back

      Example.Soak.summary()          # min/max/mean per zone, fps trend, throttle events
  """

  # :transient - a crash is worth restarting (that is the point of running all
  # night), but an explicit stop from disable/0 must stay stopped.
  use GenServer, restart: :transient
  require Logger

  @flag "/data/soak.enabled"
  @csv "/data/soak.csv"
  @interval :timer.minutes(1)
  @default_image "/root/bus.jpg"

  ## API

  @doc """
  Start soaking now and on every boot.

  Options: `:image` (default `/root/bus.jpg`), `:model`, `:ep`, `:workers`
  (default 1 - a single sequential loop, which is what makes `fps` comparable to
  `bench/2`).
  """
  def enable(opts \\ []) do
    File.mkdir_p!(Path.dirname(@flag))
    File.write!(@flag, :erlang.term_to_binary(opts))

    # Started under the application supervisor, NOT linked to the caller. Calling
    # start_link/1 from an IEx-over-SSH session would tie the soak's lifetime to
    # that session, so closing the terminal would end the overnight run.
    case Supervisor.start_child(Example.Supervisor, {__MODULE__, opts}) do
      {:ok, pid} -> {:ok, pid}
      {:error, {:already_started, pid}} -> {:ok, pid}
      {:error, :already_present} -> Supervisor.restart_child(Example.Supervisor, __MODULE__)
      other -> other
    end
  end

  @doc "Stop soaking and clear the boot flag."
  def disable do
    File.rm(@flag)

    case Process.whereis(__MODULE__) do
      nil ->
        :not_running

      _pid ->
        # terminate_child, not GenServer.stop: the child is supervised, so stopping
        # it directly would just be undone by the supervisor.
        Supervisor.terminate_child(Example.Supervisor, __MODULE__)
        Supervisor.delete_child(Example.Supervisor, __MODULE__)
        :stopped
    end
  end

  @doc "Whether the boot flag is set, and the options it carries."
  def enabled? do
    case File.read(@flag) do
      {:ok, bin} -> {true, safe_opts(bin)}
      _ -> false
    end
  end

  @doc "Live counters for the current interval, plus totals since start."
  def status, do: GenServer.call(__MODULE__, :status)

  @doc "Force a sample row to be written now, without waiting for the next minute."
  def sample_now, do: GenServer.call(__MODULE__, :sample_now, 30_000)

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Summarise `/data/soak.csv`: run duration, fps trend, per-zone min/mean/max, and any
  interval where a cooling device was engaged.
  """
  def summary(path \\ @csv) do
    with {:ok, contents} <- File.read(path) do
      [header | rows] =
        contents |> String.split("\n", trim: true) |> Enum.map(&String.split(&1, ","))

      cols = Enum.with_index(header) |> Map.new()
      rows = Enum.filter(rows, &(length(&1) == length(header)))
      col = fn row, name -> Enum.at(row, Map.get(cols, name, -1)) end
      nums = fn name -> for r <- rows, v = col.(r, name), v not in [nil, ""], do: to_num(v) end

      fps = nums.("fps")
      zone_names = Enum.filter(header, &String.ends_with?(&1, "-thermal"))
      cool_names = Enum.filter(header, &String.starts_with?(&1, "cool_"))

      %{
        file: path,
        samples: length(rows),
        minutes: length(rows),
        fps: stats(fps),
        fps_first_10: fps |> Enum.take(10) |> stats(),
        fps_last_10: fps |> Enum.take(-10) |> stats(),
        errors: nums.("errors") |> Enum.sum(),
        zones_c:
          Map.new(zone_names, fn z ->
            {z, nums.(z) |> Enum.map(&(&1 / 1000)) |> stats()}
          end),
        throttling:
          Map.new(cool_names, fn c ->
            states = nums.(c)
            {c, %{max_state: Enum.max(states, fn -> 0 end), intervals_engaged: Enum.count(states, &(&1 > 0))}}
          end)
      }
    end
  end

  ## GenServer

  # Setup is retried from a handle_info rather than done here, and a failure never
  # stops the process. At boot the CDSP can still be establishing its FastRPC
  # session, so the first Ortex.load can legitimately fail; stopping would put
  # this child into a supervisor restart loop and eventually take the whole
  # application - and the device - down unattended.
  @impl true
  def init(opts) do
    Process.flag(:trap_exit, true)
    send(self(), :setup)
    {:ok, %{status: :starting, opts: opts, attempts: 0}}
  end

  @impl true
  def handle_info(:setup, %{status: :starting} = state) do
    opts = state.opts
    image = Keyword.get(opts, :image, @default_image)

    with {:ok, session} <- Example.Yolo.load(opts),
         {:ok, frame} <- Example.Yolo.prepare(image, Keyword.put(opts, :input_size, session.side)) do
      zones = discover_zones()
      cooling = discover_cooling()
      ensure_header(zones, cooling)

      workers =
        for _ <- 1..Keyword.get(opts, :workers, 1), do: spawn_worker(session.ortex, frame.input)

      Logger.info(
        "Soak started: #{image}, #{length(workers)} worker(s), logging to #{@csv} every minute"
      )

      Process.send_after(self(), :sample, @interval)
      now = System.monotonic_time(:millisecond)

      {:noreply,
       %{
         status: :running,
         opts: opts,
         started: DateTime.utc_now(),
         started_mono: now,
         interval_start: now,
         zones: zones,
         cooling: cooling,
         image: image,
         session: session,
         frame: frame,
         workers: workers,
         acc: new_acc(),
         totals: %{iters: 0, errors: 0, samples: 0}
       }}
    else
      {:error, reason} ->
        Logger.warning("Soak setup failed (attempt #{state.attempts + 1}): #{inspect(reason)}")
        Process.send_after(self(), :setup, :timer.seconds(15))
        {:noreply, %{state | attempts: state.attempts + 1}}
    end
  end

  @impl true
  def handle_info({:tick, us}, %{status: :running} = state) do
    {:noreply, %{state | acc: accumulate(state.acc, us)}}
  end

  @impl true
  def handle_info({:tick_error, _reason}, %{status: :running} = state) do
    {:noreply, %{state | acc: Map.update!(state.acc, :errors, &(&1 + 1))}}
  end

  @impl true
  def handle_info(:sample, %{status: :running} = state) do
    Process.send_after(self(), :sample, @interval)
    {:noreply, write_sample(state)}
  end

  # A worker died. Replace it rather than taking the soak down - the point is to
  # still be running in the morning.
  @impl true
  def handle_info({:EXIT, pid, reason}, state) do
    if pid in Map.get(state, :workers, []) do
      Logger.warning("Soak worker exited (#{inspect(reason)}); restarting it")
      worker = spawn_worker(state.session.ortex, state.frame.input)

      {:noreply,
       %{
         state
         | workers: [worker | List.delete(state.workers, pid)],
           acc: Map.update!(state.acc, :errors, &(&1 + 1))
       }}
    else
      {:noreply, state}
    end
  end

  @impl true
  def handle_info(_other, state), do: {:noreply, state}

  @impl true
  def handle_call(:status, _from, %{status: :starting} = state) do
    {:reply, %{status: :starting, setup_attempts: state.attempts, csv: @csv}, state}
  end

  @impl true
  def handle_call(:status, _from, state) do
    elapsed_ms = System.monotonic_time(:millisecond) - state.interval_start

    {:reply,
     %{
       image: state.image,
       started: state.started,
       uptime_s: div(System.monotonic_time(:millisecond) - state.started_mono, 1000),
       workers: length(state.workers),
       current_interval: Map.put(state.acc, :elapsed_ms, elapsed_ms),
       totals: state.totals,
       csv: @csv
     }, state}
  end

  @impl true
  def handle_call(:sample_now, _from, %{status: :starting} = state),
    do: {:reply, {:error, :not_running_yet}, state}

  @impl true
  def handle_call(:sample_now, _from, state), do: {:reply, :ok, write_sample(state)}

  @impl true
  def terminate(_reason, state) do
    Enum.each(Map.get(state, :workers, []), &Process.exit(&1, :kill))
    :ok
  end

  ## Inference loop

  defp spawn_worker(model, input) do
    parent = self()

    spawn_link(fn ->
      loop = fn loop ->
        try do
          {us, _} = :timer.tc(fn -> Ortex.run(model, {input}) end)
          send(parent, {:tick, us})
        rescue
          e -> send(parent, {:tick_error, Exception.message(e)})
        end

        loop.(loop)
      end

      loop.(loop)
    end)
  end

  defp new_acc, do: %{iters: 0, sum_us: 0, min_us: nil, max_us: nil, errors: 0}

  defp accumulate(acc, us) do
    %{
      acc
      | iters: acc.iters + 1,
        sum_us: acc.sum_us + us,
        min_us: min(acc.min_us || us, us),
        max_us: max(acc.max_us || us, us)
    }
  end

  ## Sampling

  defp write_sample(state) do
    now_mono = System.monotonic_time(:millisecond)
    interval_ms = now_mono - state.interval_start
    acc = state.acc

    fps =
      if acc.iters > 0 and interval_ms > 0,
        do: Float.round(acc.iters * 1000 / interval_ms, 2),
        else: 0.0

    row =
      [
        DateTime.to_iso8601(state.started),
        DateTime.to_iso8601(DateTime.utc_now()),
        div(now_mono - state.started_mono, 1000),
        div(interval_ms, 1000),
        acc.iters,
        fps,
        if(acc.iters > 0, do: div(acc.sum_us, acc.iters), else: 0),
        acc.min_us || 0,
        acc.max_us || 0,
        acc.errors
      ] ++
        Enum.map(state.zones, fn {_name, path} -> read_int(path) end) ++
        Enum.map(cpufreq_paths(), &read_int/1) ++
        Enum.map(state.cooling, fn {_name, path} -> read_int(path) end)

    append(Enum.map_join(row, ",", &to_string/1))

    %{
      state
      | acc: new_acc(),
        interval_start: now_mono,
        totals: %{
          iters: state.totals.iters + acc.iters,
          errors: state.totals.errors + acc.errors,
          samples: state.totals.samples + 1
        }
    }
  end

  defp ensure_header(zones, cooling) do
    File.mkdir_p!(Path.dirname(@csv))

    header =
      Enum.join(
        ~w(run_started_at sampled_at uptime_s elapsed_s iters fps mean_us min_us max_us errors) ++
          Enum.map(zones, fn {name, _} -> name end) ++
          Enum.map(cpufreq_paths(), &("cpufreq_" <> (&1 |> Path.split() |> Enum.at(-2)))) ++
          Enum.map(cooling, fn {name, _} -> "cool_" <> name end),
        ","
      )

    case File.read(@csv) do
      {:error, _} ->
        append(header)

      {:ok, contents} ->
        # A file whose first line is not the header cannot be parsed tomorrow.
        # This is reachable: the header is written at startup, and an unclean
        # reset before the filesystem flushed it left a file of data rows with no
        # header at all. Move that aside rather than appending a header mid-file.
        unless String.starts_with?(contents, "run_started_at,") do
          File.rename(@csv, @csv <> ".unheadered-" <> Integer.to_string(System.os_time(:second)))
          append(header)
        end
    end
  end

  # Written with :sync, so each row is on the medium before the call returns. An
  # unattended run must not lose the night to an unflushed page cache: an earlier
  # reset cost exactly the header and the first sample row that way. One fsync a
  # minute is free.
  defp append(line) do
    {:ok, io} = :file.open(@csv, [:append, :raw, :binary, :sync])

    try do
      :ok = :file.write(io, line <> "\n")
    after
      :file.close(io)
    end
  end

  defp discover_zones do
    "/sys/class/thermal/thermal_zone*"
    |> Path.wildcard()
    |> Enum.map(fn dir -> {read_trim("#{dir}/type"), "#{dir}/temp"} end)
    |> Enum.reject(fn {name, _} -> is_nil(name) end)
    |> Enum.sort()
  end

  defp discover_cooling do
    "/sys/class/thermal/cooling_device*"
    |> Path.wildcard()
    |> Enum.map(fn dir -> {read_trim("#{dir}/type"), "#{dir}/cur_state"} end)
    |> Enum.reject(fn {name, _} -> is_nil(name) end)
    |> Enum.sort()
  end

  defp cpufreq_paths do
    Path.wildcard("/sys/devices/system/cpu/cpufreq/policy*/scaling_cur_freq") |> Enum.sort()
  end

  defp read_trim(path) do
    case File.read(path) do
      {:ok, s} -> String.trim(s)
      _ -> nil
    end
  end

  defp read_int(path) do
    case read_trim(path) do
      nil -> ""
      s -> s
    end
  end

  defp to_num(s) do
    case Float.parse(s) do
      {f, _} -> f
      :error -> 0
    end
  end

  defp stats([]), do: %{n: 0}

  defp stats(values) do
    sorted = Enum.sort(values)
    n = length(values)

    %{
      n: n,
      min: Float.round(List.first(sorted) / 1, 2),
      max: Float.round(List.last(sorted) / 1, 2),
      mean: Float.round(Enum.sum(values) / n, 2),
      p50: Float.round(Enum.at(sorted, div(n, 2)) / 1, 2)
    }
  end

  defp safe_opts(bin) do
    :erlang.binary_to_term(bin, [:safe])
  rescue
    _ -> []
  end
end
