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
    * `uptime_s` - seconds since the *current soak process* started.
    * `sys_uptime_s` - seconds since the *board* booted. A drop here means the device
      restarted and the soak auto-resumed; `uptime_s` restarting from 0 while
      `sys_uptime_s` keeps climbing means only the soak process restarted.
    * `elapsed_s` - length of the interval this row covers.
    * `iters`, `fps`, `mean_us`, `min_us`, `max_us`, `errors` - inference in the
      last interval only, so throttling shows up as a falling `fps` over the night.
    * one column per thermal zone, in millidegrees C, named after the zone's own
      `type` - including `nspss0-thermal`/`nspss1-thermal`, which are the Hexagon
      NSP subsystem the NPU runs on, and `msm-skin-thermal`, the closest thing to
      a case temperature.
    * `workers` - how many worker processes, each with its OWN session. More than
      one is pipelining, not parallelism across devices; see `spawn_worker/2`.
    * `model` - which model directory was benchmarked, so a row is self-describing.
    * `governor` - the cpufreq governor in effect. `performance` is set on start
      and the previous value restored on stop; see `set_governor/1` for why that is
      load-bearing rather than cosmetic.
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
  @default_model "/root/det/model.onnx"

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
    #
    # An already-running soak is replaced rather than left alone: enable/1 is how
    # the configuration is changed, and returning the existing process would keep
    # reporting numbers for a model set and mode the caller did not ask for. That
    # bug cost a debugging round - a two-model pipeline request silently kept
    # running a single-model inference soak from a previous call.
    _ = Supervisor.terminate_child(Example.Supervisor, __MODULE__)
    _ = Supervisor.delete_child(Example.Supervisor, __MODULE__)
    Supervisor.start_child(Example.Supervisor, {__MODULE__, opts})
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

    # `models:` gives one entry per model; `workers:` replicates each model that
    # many times. Replicas of the same model share a label, so per-model counters
    # sum across its sessions - two sessions of the detector still report as "det".
    #
    # Each entry gets its OWN session. Ortex.run holds a Mutex<Session>, so workers
    # sharing a session merely queue: 32.5 fps with p50 latency doubled, against
    # 46.8 fps for two independent sessions. That is pipelining, not parallelism
    # across devices - there is one NPU, ~21 ms of an inference is serial DSP
    # compute and ~12 ms is ARM-side work, so a second in-flight request overlaps
    # its ARM phase with the first's DSP phase. The DSP saturates at ~47 inf/s.
    decode? = Keyword.get(opts, :decode, false)
    replicas = Keyword.get(opts, :workers, 1)

    models =
      opts
      |> Keyword.get(:models, [Keyword.get(opts, :model, @default_model)])
      |> Enum.map(&normalize_model/1)

    try do
      loaded =
        for {path, kind} <- models, _ <- 1..replicas//1 do
          {:ok, sess} = Example.Yolo.load(Keyword.put(opts, :model, path))
          {:ok, fr} = Example.Yolo.prepare(image, Keyword.put(opts, :input_size, sess.side))
          %{label: label_for(path), path: path, kind: kind, session: sess, frame: fr}
        end

      labels = loaded |> Enum.map(& &1.label) |> Enum.uniq()
      zones = discover_zones()
      cooling = discover_cooling()
      ensure_header(zones, cooling, labels)
      previous_governor = set_governor(Keyword.get(opts, :governor, "performance"))
      workers = Map.new(loaded, fn m -> {spawn_worker(m, decode?), m.label} end)

      Logger.info(
        "Soak started: #{image}, models #{inspect(labels)}, #{map_size(workers)} session(s), " <>
          "mode=#{if decode?, do: "pipeline", else: "inference"}, logging to #{@csv} every minute"
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
         decode?: decode?,
         loaded: loaded,
         labels: labels,
         workers: workers,
         previous_governor: previous_governor,
         acc: new_acc(labels),
         totals: %{iters: 0, errors: 0, samples: 0}
       }}
    rescue
      e ->
        Logger.warning("Soak setup failed (attempt #{state.attempts + 1}): #{Exception.message(e)}")
        Process.send_after(self(), :setup, :timer.seconds(15))
        {:noreply, %{state | attempts: state.attempts + 1}}
    end
  end

  @impl true
  def handle_info({:tick, label, us}, %{status: :running} = state) do
    {:noreply, %{state | acc: accumulate(state.acc, label, us)}}
  end

  @impl true
  def handle_info({:tick_error, label, _reason}, %{status: :running} = state) do
    {:noreply,
     %{state | acc: Map.update!(state.acc, label, &%{&1 | errors: &1.errors + 1})}}
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
    case Map.fetch(Map.get(state, :workers, %{}), pid) do
      {:ok, label} ->
        Logger.warning("Soak worker for #{label} exited (#{inspect(reason)}); restarting it")
        m = Enum.find(state.loaded, &(&1.label == label))
        new_pid = spawn_worker(m, state.decode?)

        {:noreply,
         %{
           state
           | workers: state.workers |> Map.delete(pid) |> Map.put(new_pid, label),
             acc: Map.update!(state.acc, label, &%{&1 | errors: &1.errors + 1})
         }}

      :error ->
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
       mode: if(state.decode?, do: :pipeline, else: :inference),
       models: Map.new(state.loaded, fn m -> {m.label, {m.path, m.kind}} end),
       workers_configured: map_size(state.workers),
       started: state.started,
       uptime_s: div(System.monotonic_time(:millisecond) - state.started_mono, 1000),
       current_interval: %{elapsed_ms: elapsed_ms, per_model: state.acc},
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
    state |> Map.get(:workers, %{}) |> Map.keys() |> Enum.each(&Process.exit(&1, :kill))
    if g = Map.get(state, :previous_governor), do: set_governor(g)
    :ok
  end

  # The cpufreq governor is what makes disabling onnxruntime's spin-wait a win
  # rather than a 43% throughput loss: without spinning there is no CPU load for
  # schedutil to react to, so the cores sit at 691 MHz and every CPU-side segment
  # and RPC dispatch takes twice as long. Under `performance` we get the spinning
  # configuration's throughput for a twentieth of its CPU. Restored on stop.
  defp set_governor(nil), do: nil

  defp set_governor(governor) do
    paths = Path.wildcard("/sys/devices/system/cpu/cpufreq/policy*/scaling_governor")
    previous = paths |> Enum.map(&read_trim/1) |> Enum.reject(&is_nil/1) |> List.first()

    Enum.each(paths, fn path ->
      case File.write(path, governor) do
        :ok -> :ok
        {:error, reason} -> Logger.warning("Could not set #{path} to #{governor}: #{inspect(reason)}")
      end
    end)

    if previous != governor, do: Logger.info("cpufreq governor: #{previous} -> #{governor}")
    previous
  end

  ## Inference loop

  defp spawn_worker(m, decode?) do
    parent = self()
    label = m.label

    work =
      case {decode?, m.kind} do
        {true, :pose} -> fn -> Example.Yolo.detect_pose(m.frame, session: m.session) end
        {true, _} -> fn -> Example.Yolo.detect(m.frame, session: m.session) end
        {false, _} -> fn -> Ortex.run(m.session.ortex, {m.frame.input}) end
      end

    spawn_link(fn ->
      loop = fn loop ->
        try do
          {us, _} = :timer.tc(work)
          send(parent, {:tick, label, us})
        rescue
          e -> send(parent, {:tick_error, label, Exception.message(e)})
        end

        loop.(loop)
      end

      loop.(loop)
    end)
  end

  defp new_acc(labels) do
    Map.new(labels, fn l -> {l, %{iters: 0, sum_us: 0, min_us: nil, max_us: nil, errors: 0}} end)
  end

  defp accumulate(acc, label, us) do
    Map.update!(acc, label, fn a ->
      %{
        a
        | iters: a.iters + 1,
          sum_us: a.sum_us + us,
          min_us: min(a.min_us || us, us),
          max_us: max(a.max_us || us, us)
      }
    end)
  end

  defp totals_of(acc) do
    Enum.reduce(acc, %{iters: 0, errors: 0, sum_us: 0}, fn {_l, a}, t ->
      %{iters: t.iters + a.iters, errors: t.errors + a.errors, sum_us: t.sum_us + a.sum_us}
    end)
  end

  # A bare path means "decode it with the detection head". Anything whose directory
  # name mentions pose gets the pose decoder, since the two heads are not
  # interchangeable; pass {path, :detect | :pose | :none} to be explicit.
  defp normalize_model({path, kind}), do: {path, kind}

  defp normalize_model(path) when is_binary(path) do
    if String.contains?(String.downcase(path), "pose"), do: {path, :pose}, else: {path, :detect}
  end

  defp label_for(path), do: Path.basename(Path.dirname(path))

  ## Sampling

  defp write_sample(state) do
    now_mono = System.monotonic_time(:millisecond)
    interval_ms = now_mono - state.interval_start
    tot = totals_of(state.acc)

    fps = fn iters -> if interval_ms > 0, do: Float.round(iters * 1000 / interval_ms, 2), else: 0.0 end

    # Per-model columns come first as a block per label, so the header stays stable
    # for a given model set and a row is readable without cross-referencing.
    per_model =
      Enum.flat_map(state.labels, fn label ->
        a = state.acc[label]
        [a.iters, fps.(a.iters), if(a.iters > 0, do: div(a.sum_us, a.iters), else: 0), a.errors]
      end)

    row =
      [
        DateTime.to_iso8601(state.started),
        DateTime.to_iso8601(DateTime.utc_now()),
        div(now_mono - state.started_mono, 1000),
        system_uptime_s(),
        div(interval_ms, 1000),
        tot.iters,
        fps.(tot.iters),
        if(tot.iters > 0, do: div(tot.sum_us, tot.iters), else: 0),
        tot.errors,
        read_trim("/sys/devices/system/cpu/cpufreq/policy0/scaling_governor") || "",
        map_size(state.workers),
        if(state.decode?, do: "pipeline", else: "inference")
      ] ++
        per_model ++
        Enum.map(state.zones, fn {_name, path} -> read_int(path) end) ++
        Enum.map(cpufreq_paths(), &read_int/1) ++
        Enum.map(state.cooling, fn {_name, path} -> read_int(path) end)

    append(Enum.map_join(row, ",", &to_string/1))

    %{
      state
      | acc: new_acc(state.labels),
        interval_start: now_mono,
        totals: %{
          iters: state.totals.iters + tot.iters,
          errors: state.totals.errors + tot.errors,
          samples: state.totals.samples + 1
        }
    }
  end

  defp ensure_header(zones, cooling, labels) do
    File.mkdir_p!(Path.dirname(@csv))

    header =
      Enum.join(
        ~w(run_started_at sampled_at uptime_s sys_uptime_s elapsed_s iters fps mean_us errors
           governor workers mode) ++
          Enum.flat_map(labels, fn l -> ["frames_#{l}", "fps_#{l}", "mean_us_#{l}", "errors_#{l}"] end) ++
          Enum.map(zones, fn {name, _} -> name end) ++
          Enum.map(cpufreq_paths(), &("cpufreq_" <> (&1 |> Path.split() |> Enum.at(-2)))) ++
          Enum.map(cooling, fn {name, _} -> "cool_" <> name end),
        ","
      )

    case File.read(@csv) do
      {:error, _} ->
        append(header)

      {:ok, contents} ->
        # Rotate unless the first line is EXACTLY this header. Reachable two ways: an
        # unclean reset before the filesystem flushed leaves rows with no header, and
        # changing the model set (or adding a column) changes the schema - appending
        # would produce a file with two different row widths and no way to tell which
        # is which.
        if String.split(contents, "\n") |> hd() != header do
          File.rename(@csv, @csv <> ".old-" <> Integer.to_string(System.os_time(:second)))
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

  # Seconds since the board booted, straight from /proc/uptime. This is the column
  # that tells you whether the device restarted mid-run: it climbs monotonically and
  # DROPS across a reboot, whereas the wall clock can be wrong before NTP syncs and
  # `uptime_s` only measures the current soak process.
  defp system_uptime_s do
    case read_trim("/proc/uptime") do
      nil -> ""
      s -> s |> String.split() |> hd() |> String.to_float() |> trunc()
    end
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
