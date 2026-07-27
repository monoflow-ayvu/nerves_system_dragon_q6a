defmodule Example.Yolo do
  @moduledoc """
  Run a YOLO model on an image file, on the Hexagon NPU.

  ## Usage

      iex> Example.Yolo.detect("/root/bus.jpg")
      {:ok,
       %{
         detections: [
           %{class: "bus", class_id: 5, score: 0.942, box: {22, 229, 793, 739}},
           %{class: "person", class_id: 0, score: 0.904, box: {49, 396, 246, 903}}
         ],
         count: 5,
         inference_us: 43_078,
         preprocess_us: 146_706
       }}

  `box` is `{x1, y1, x2, y2}` in the *original* image's pixel coordinates, with
  letterbox padding and scaling already undone.

  For more than a one-off call, keep the session - a fresh one re-compiles the
  graph for the HTP:

      {:ok, s} = Example.Yolo.load()
      Example.Yolo.detect("/root/bus.jpg", session: s)

  ## Options

    * `:session` - a handle from `load/1`. Avoids re-compiling the model.
    * `:model` - path to a YOLO ONNX file. Defaults to `:yolo_model` in the
      application env, else `/root/det/model.onnx`.
    * `:ep` - `:qnn` (default, the NPU), `:cpu`, or `:cpu_forced`. Note that
      `:cpu` is *not* a guarantee of CPU execution - see `bench/2`.
    * `:conf` - confidence threshold, default `0.25`.
    * `:iou` - NMS IoU threshold, default `0.45`.
    * `:max_detections` - default `100`.
    * `:input_size` - model input side, default `640`.
    * `:classes` - list of class names, default the 80 COCO names. Pass your own
      for a differently-trained model.
    * `:trace_path` - write ort's `tracing` output and onnxruntime's VERBOSE log to
      this file. The only way to see why a QNN session misbehaved, since a NIF's
      stdout goes to the console rather than to the caller. To get the
      **node-placement report** - the line that actually says whether QNN claimed
      the graph - pass `"env.RUST_LOG": "trace"` as well: onnxruntime logs it at
      VERBOSE, which `ort` maps onto tracing's TRACE level, and the default filter
      is `debug`. Expect ~8 MB of trace for one session.

          Example.Yolo.load(trace_path: "/tmp/t.log", "env.RUST_LOG": "trace")
          # => ... Node(s) placed on [QNN]. Number of nodes: 1
          #    ... Node(s) placed on [CPUExecutionProvider]. Number of nodes: 2
    * `:intra_threads` (default `0`, onnxruntime's own) and `:intra_op_spinning`
      (default `false`) -
      onnxruntime thread-pool shape. The defaults stop its workers from spin-waiting
      through an inference that the NPU is doing; see `qnn_opts/1`.

  ## Performance

  yolo11s QDQ at 640x640 on this board. Ranges are across repeated runs - inference
  varies 31-44 ms run to run, so a single figure would overstate the precision:

  | stage | cost |
  |---|---|
  | JPEG decode (`StbImage.read_file`) | 80 ms (810x1080), 44 ms (1280x720) |
  | `prepare/2` - resize + letterbox + planar f32 | 52-73 ms |
  | inference on the HTP | 32-37 ms mean -> **27-31 fps** |
  | inference on the ARM cores | ~865 ms |

  So ~28 fps of model throughput, but only ~5-9 fps end-to-end if every frame is a
  fresh JPEG - decode and resize cost more than the inference does. `bench/2`
  reports both as `fps` and `pipeline_fps`. For a camera pipeline, feed frames that
  are already 640x640 and reuse one prepared buffer.

  Two once-only costs, both discarded by `bench/2`: the first `prepare/2` in a
  process pays 0.5-1.5 s of XLA kernel compilation, and the first inference on a
  session pays HTP graph compilation.

  ## Which models work

  Expects the Ultralytics detection head: input `images` f32 NCHW
  `[1, 3, S, S]`, output `[1, 4 + nc, A]`. Verified with the Qualcomm AI Hub QDQ
  exports of yolo11s at 640x640.

  A **QDQ-quantized** export is required for the NPU to take the graph. A float32
  model loads and runs fine but the HTP claims no nodes, so it lands on the ARM
  cores - about 20x slower - without reporting any error.

  ## Pose models

  `detect/2` is a detection-head decoder, so a `-pose` export (output
  `[1, 56, A]`) will not decode correctly through it. Use `run/2` for the raw
  output tensor of any model, and see `Example.NPU` for the NPU-level checks.
  """

  import Nx.Defn

  @default_model "/root/det/model.onnx"

  # Ultralytics' letterbox fill value.
  @pad_value 114

  @coco ~w(person bicycle car motorcycle airplane bus train truck boat traffic_light
           fire_hydrant stop_sign parking_meter bench bird cat dog horse sheep cow
           elephant bear zebra giraffe backpack umbrella handbag tie suitcase frisbee
           skis snowboard sports_ball kite baseball_bat baseball_glove skateboard
           surfboard tennis_racket bottle wine_glass cup fork knife spoon bowl banana
           apple sandwich orange broccoli carrot hot_dog pizza donut cake chair couch
           potted_plant bed dining_table toilet tv laptop mouse remote keyboard
           cell_phone microwave oven toaster sink refrigerator book clock vase scissors
           teddy_bear hair_drier toothbrush)

  @doc "The 80 COCO class names, in model order."
  def coco_classes, do: @coco

  @doc """
  Load a model once and keep the session, for repeated `detect/2` calls.

      {:ok, s} = Example.Yolo.load()
      Example.Yolo.detect("/root/bus.jpg", session: s)

  Worth doing for anything beyond a one-off: a fresh session re-compiles the
  graph for the HTP.
  """
  def load(opts \\ []) do
    with {:ok, model_path} <- resolve_model(opts),
         {:ok, ortex, side} <- build_session(model_path, opts) do
      {:ok, %{ortex: ortex, side: side, model: model_path, ep: Keyword.get(opts, :ep, :qnn)}}
    end
  end

  @doc """
  Decode, resize and letterbox an image once, ready to be run repeatedly.

  This is the expensive half of a single-image pipeline - JPEG decode and resize
  are C, but they still cost more than the inference does - so for benchmarking
  or for running several models over the same frame, do it once:

      {:ok, s} = Example.Yolo.load()
      {:ok, frame} = Example.Yolo.prepare("/root/bus.jpg")
      Example.Yolo.detect(frame, session: s)

  Returns `{:ok, prepared}`, which `detect/2` and `run/2` accept in place of a
  path. `:input_size` must match the session it will be fed to (both default to
  640).
  """
  def prepare(path, opts \\ []) do
    side = Keyword.get(opts, :input_size, 640)

    with {:ok, image} <- read_image(path) do
      {us, {input, geom}} = :timer.tc(fn -> preprocess(image, side) end)

      {:ok,
       %{
         input: input,
         geom: geom,
         side: side,
         source: path,
         preprocess_us: us,
         image_size: (fn {h, w, _} -> {w, h} end).(image.shape)
       }}
    end
  rescue
    e -> {:error, Exception.message(e)}
  end

  @doc """
  Detect objects in the image at `path`.

  Returns `{:ok, result}` or `{:error, reason}`. See the moduledoc for options.
  Pass `session: handle` from `load/1` to avoid re-compiling the model.
  """
  def detect(source, opts \\ []) do
    with {:ok, %{ortex: session, side: side, model: model_path}} <- reuse_or_load(opts),
         {:ok, frame} <- as_prepared(source, side, opts) do
      %{input: input, geom: geom, preprocess_us: pre_us} = frame
      {inf_us, out} = :timer.tc(fn -> Ortex.run(session, {input}) end)

      {out} = out
      # backend_transfer/1 defaults to Nx.BinaryBackend - NOT Nx.default_backend().
      # Getting that wrong made every decode run element-by-element even with EXLA
      # installed: transpose 246 ms, reduce_max 265 ms, argmax 289 ms on the
      # 8400x84 head, i.e. ~800 ms of decode against 36 ms of inference. On EXLA
      # the same three ops are 2.9/0.8/1.7 ms, and fused into one defn, 2.8 ms.
      raw = Nx.backend_transfer(out, Nx.default_backend())

      classes = Keyword.get(opts, :classes, @coco)

      detections =
        raw
        |> decode(Keyword.get(opts, :conf, 0.25))
        |> nms(Keyword.get(opts, :iou, 0.45))
        |> Enum.take(Keyword.get(opts, :max_detections, 100))
        |> Enum.map(&to_original_coords(&1, geom, classes))

      {:ok,
       %{
         detections: detections,
         count: length(detections),
         inference_us: inf_us,
         preprocess_us: pre_us,
         model: model_path,
         ep: Keyword.get(opts, :ep, :qnn),
         input_shape: Nx.shape(input),
         output_shape: Nx.shape(raw),
         image_size: frame.image_size
       }}
    end
  rescue
    e -> {:error, Exception.message(e)}
  end

  @doc """
  Run the model on an image and return the raw output tensor, undecoded.

  For models whose head `detect/2` does not understand (pose, segment), or when
  you want to do your own post-processing.
  """
  def run(source, opts \\ []) do
    with {:ok, %{ortex: session, side: side}} <- reuse_or_load(opts),
         {:ok, frame} <- as_prepared(source, side, opts) do
      {us, {out}} = :timer.tc(fn -> Ortex.run(session, {frame.input}) end)
      {:ok, Nx.backend_transfer(out), %{inference_us: us, letterbox: frame.geom}}
    end
  rescue
    e -> {:error, Exception.message(e)}
  end

  @doc """
  Measure inference throughput: decode and letterbox the image once, then run the
  model `n` times and report per-iteration cost and fps.

      iex> Example.Yolo.bench("/root/bus.jpg", iterations: 30)
      %{ep: :qnn, iterations: 30, mean_us: 36_615, fps: 27.3, pipeline_fps: 9.1, ...}

  Only `Ortex.run/2` is inside the timed loop - no decode, no resize, no
  letterbox, no NMS - so `fps` is the model's throughput on the chosen execution
  provider, not the pipeline's. `preprocess_us` reports what a frame costs to get
  ready, once, for comparison; `pipeline_fps` is the honest end-to-end figure if
  every frame is a fresh JPEG.

  Measures only the execution provider you ask for. It deliberately does *not*
  run a CPU arm for comparison, because a trustworthy CPU baseline is not
  obtainable from a long-lived BEAM:

    * Asking for `:cpu` is not enough. Once any session has registered the QNN
      plugin EP, ONNX Runtime auto-selects it for later sessions that request no
      EP at all, so a nominal CPU session still lands on the NPU.
    * Hiding the Hexagon skel does force the ARM cores, but only if it is done
      for the *first* QNN session in the OS process - the backend and skel are
      resolved once and cached for the process lifetime, so a later change is
      ignored.
    * Going the other way, a poisoned DSP configuration followed by a working one
      **takes down the VM** (observed: the node rebooted mid-benchmark).

  So: for a CPU baseline, reboot and make `ep: :cpu_forced` the first inference
  the node performs, or use the standalone `qnn-probe` binary with
  `ADSP_LIBRARY_PATH=/nonexistent`.
  """
  def bench(path, opts \\ []) do
    n = Keyword.get(opts, :iterations, 30)

    with {:ok, handle} <- load(opts),
         {:ok, frame} <- prepare(path, Keyword.put(opts, :input_size, handle.side)),
         # Discarded: the first run carries HTP graph compilation.
         {_us, _} <- {0, Ortex.run(handle.ortex, {frame.input})} do
      timings =
        for _ <- 1..n do
          {us, _} = :timer.tc(fn -> Ortex.run(handle.ortex, {frame.input}) end)
          us
        end

      sorted = Enum.sort(timings)
      mean = div(Enum.sum(timings), length(timings))

      %{
        ep: Keyword.get(opts, :ep, :qnn),
        model: handle.model,
        image: {path, frame.image_size},
        iterations: n,
        mean_us: mean,
        p50_us: Enum.at(sorted, div(n, 2)),
        min_us: List.first(sorted),
        max_us: List.last(sorted),
        fps: Float.round(1_000_000 / mean, 1),
        preprocess_us: frame.preprocess_us,
        pipeline_fps: Float.round(1_000_000 / (mean + frame.preprocess_us), 1),
        backend: Nx.default_backend()
      }
    end
  end

  ## Model / session

  defp resolve_model(opts) do
    path =
      Keyword.get(opts, :model) ||
        Application.get_env(:example, :yolo_model, @default_model)

    if File.exists?(path), do: {:ok, path}, else: {:error, {:model_not_found, path}}
  end

  # A path is decoded here; an already-prepared frame passes straight through, so
  # a benchmark loop pays for the decode and resize exactly once.
  defp as_prepared(%{input: _, geom: _} = frame, side, _opts) do
    if frame.side == side do
      {:ok, frame}
    else
      {:error, {:input_size_mismatch, prepared: frame.side, session: side}}
    end
  end

  defp as_prepared(path, side, opts) when is_binary(path) do
    prepare(path, Keyword.put(opts, :input_size, side))
  end

  defp reuse_or_load(opts) do
    case Keyword.get(opts, :session) do
      %{ortex: _, side: _} = handle -> {:ok, handle}
      nil -> load(Keyword.delete(opts, :session))
      other -> {:error, {:not_a_session, other}}
    end
  end

  defp build_session(model_path, opts) do
    {ep, qnn_opts} =
      case Keyword.get(opts, :ep, :qnn) do
        :qnn -> {:qnn, qnn_opts(opts)}
        # See bench/2: a genuine CPU baseline needs the DSP unreachable, not
        # merely an unrequested EP.
        :cpu_forced -> {:qnn, hide_dsp(qnn_opts(opts))}
        other -> {other, []}
      end

    {:ok, Ortex.load(model_path, [ep], 3, qnn_opts), input_side(model_path, opts)}
  rescue
    e -> {:error, {:load_failed, Exception.message(e)}}
  end

  defp hide_dsp(qnn_opts) do
    Keyword.merge(qnn_opts,
      "env.DSP_LIBRARY_PATH": "/nonexistent",
      "env.ADSP_LIBRARY_PATH": "/nonexistent"
    )
  end

  @doc """
  The QNN configuration handed to `Ortex.load/4`, as it will be passed.

  Everything here goes through `Ortex.load/4` as an *argument* rather than an
  environment variable, because `System.put_env/2` cannot configure this stack:
  since OTP 21, `os:putenv` writes Erlang's own environment table and leaves the
  OS `environ` alone, so neither the NIF nor - decisively - the QNN libraries'
  own `getenv("DSP_LIBRARY_PATH")` ever observe it. Keys prefixed `env.` are set
  in the real process environment by the NIF for that reason.

  The three settings that are each individually load-bearing:

    * `backend_path` - ONNX Runtime's QNN plugin EP and the QNN backend it loads
      must come from the same QNN release. The QAIRT 2.42 runtime at
      `/usr/lib/libQnnHtp.so` serves `qnn-platform-validator` but not this EP
      ("Unable to find a valid interface for ..."), so this points at the
      matching set instead.
    * `env.DSP_LIBRARY_PATH` / `env.ADSP_LIBRARY_PATH` - `;`-separated and
      order-sensitive. The matching Hexagon V68 skel must be found before the
      QAIRT one or the session fails with `QNN_DEVICE_ERROR_INVALID_CONFIG`.
    * `htp_arch` - without it the EP logs "Unable to get platform info: Failed to
      get HTP arch", claims no nodes, and the graph runs on the ARM cores at
      about 1/35th the speed, reporting no error at all.
  """
  def qnn_opts(opts \\ []) do
    base = [
      htp_arch: Keyword.get(opts, :htp_arch, 68),
      htp_performance_mode: Keyword.get(opts, :htp_performance_mode, "burst"),
      # Do not let onnxruntime's intra-op pool spin-wait while the HTP works. Its
      # workers spin before parking because that is right for CPU graphs of many
      # tiny kernels; with the whole graph on one ~33 ms accelerator node they spin
      # through the entire inference. Measured: ~6 ARM cores pinned (539% of wall),
      # cpu0 89 degC, cpufreq cooling state at 9/9, throughput decaying 24 -> 20.6
      # fps as the package throttled - and the NPU throttling along with it.
      #
      # IMPORTANT: this only pays off with the cpufreq governor set to
      # `performance`. The spinning was doubling as an accidental governor - it
      # kept the cores loaded so schedutil clocked them up. Remove it under
      # schedutil and they idle at 691 MHz, which HALVES throughput (29.2 -> 20.6
      # fps). Measured on bus.jpg, 30 iterations each:
      #
      #   spin=ON  schedutil     27.9 fps   539% cpu   1958/1900/806 MHz
      #   spin=OFF schedutil     20.6 fps    52% cpu    691/691/806 MHz
      #   spin=OFF performance   29.2 fps    27% cpu   1958/2400/2707 MHz  <-- this
      #
      # Same throughput for a twentieth of the CPU. Example.Soak sets the governor;
      # if you use this module directly under a sustained load, set it too.
      # intra_threads is left at onnxruntime's default: under `performance` it is
      # noise (0/2/4/8 all land within 27-30 fps).
      intra_threads: Keyword.get(opts, :intra_threads, 0),
      intra_op_spinning: Keyword.get(opts, :intra_op_spinning, false)
    ]

    base = if path = Keyword.get(opts, :trace_path), do: [{:trace_path, path} | base], else: base

    # Forward any env.* keys straight through: the NIF pushes them into the real
    # process environment, which is the only place onnxruntime and the QNN
    # libraries look. `env.RUST_LOG: "trace"` is the one you will actually want -
    # see :trace_path in the moduledoc.
    base = base ++ Enum.filter(opts, fn {k, _} -> String.starts_with?(to_string(k), "env.") end)

    case Enum.find(qnn_lib_dirs(), &File.exists?(Path.join(&1, "libQnnHtp.so"))) do
      nil ->
        base

      dir ->
        dsp = if File.dir?(Path.join(dir, "dsp")), do: Path.join(dir, "dsp"), else: dir

        base ++
          [
            backend_path: Path.join(dir, "libQnnHtp.so"),
            "env.DSP_LIBRARY_PATH": "#{dsp};/usr/lib/dsp",
            "env.ADSP_LIBRARY_PATH": "#{dsp};/usr/lib/dsp"
          ]
    end
  end

  defp qnn_lib_dirs do
    case Application.fetch_env(:example, :qnn_lib_dir) do
      {:ok, dir} -> [dir]
      :error -> ["/usr/lib/onnxruntime-qnn", "/root/qnnlibs"]
    end
  end

  # AI Hub exports at resolutions other than 640 too, and ortex has no public
  # accessor for a session's input shape (Inspect.Ortex.Model crashes on Elixir
  # 1.19), so this is an option rather than something read from the model. If a
  # model disagrees, ONNX Runtime rejects the run with a shape mismatch naming
  # the size it wanted.
  defp input_side(_model_path, opts), do: Keyword.get(opts, :input_size, 640)

  ## Preprocessing

  defp read_image(path) do
    case StbImage.read_file(path, channels: 3) do
      {:ok, img} -> {:ok, img}
      {:error, reason} -> {:error, {:decode_failed, path, reason}}
    end
  end

  # Letterbox to side x side, preserving aspect ratio, centred, padded with 114 -
  # matching what Ultralytics does at training time. Returns the NCHW f32 tensor
  # scaled to 0..1 plus the geometry needed to map boxes back.
  #
  # Two implementations, picked by which Nx backend is actually installed.
  # BinaryBackend evaluates transpose element-by-element with full index
  # arithmetic, so the Nx pipeline below costs 9.0 s per frame on it - 200x the
  # inference it feeds. The binary fallback exists for that case; with EXLA the
  # Nx version is both faster and clearer.
  defp preprocess(%StbImage{} = image, side) do
    {h0, w0, _} = image.shape

    scale = min(side / w0, side / h0)
    nw = max(round(w0 * scale), 1)
    nh = max(round(h0 * scale), 1)

    pad_x = div(side - nw, 2)
    pad_y = div(side - nh, 2)

    resized = StbImage.resize(image, nh, nw)
    geom = %{scale: scale, pad_x: pad_x, pad_y: pad_y, w0: w0, h0: h0}

    input =
      if accelerated_nx?() do
        to_input_nx(resized, side, nh, nw, pad_x, pad_y)
      else
        to_input_binary(resized, side, nh, nw, pad_x, pad_y)
      end

    {input, geom}
  end

  defp accelerated_nx?, do: Nx.default_backend() != {Nx.BinaryBackend, []}

  defp to_input_nx(resized, side, nh, nw, pad_x, pad_y) do
    resized.data
    |> Nx.from_binary(:u8)
    |> Nx.reshape({nh, nw, 3})
    |> letterbox(
      pad_top: pad_y,
      pad_bottom: side - nh - pad_y,
      pad_left: pad_x,
      pad_right: side - nw - pad_x
    )
    # Copy - not transfer - the result out of the accelerator and into a plain
    # binary. ortex pulls its inputs across with Nx.backend_transfer, which
    # *deletes* the source buffer, so a prepared frame held in an XLA buffer
    # works exactly once and then raises "ToLiteral() called on deleted or
    # donated buffer" on reuse. Copying also removes a per-inference device
    # round-trip: with an EXLA-resident input, Ortex.run measured 77 ms against
    # 43 ms for a binary one.
    |> Nx.backend_copy(Nx.BinaryBackend)
  end

  # Pad, planarize and scale as ONE compiled kernel.
  #
  # It matters that this is a `defn` and not plain Nx calls: EXLA.Backend
  # executes each operation as its own XLA computation with a host round-trip.
  # Measured, median of 7, whole `preprocess` including the 15 ms StbImage
  # resize: 70 ms for the pure-binary fallback, 65 ms with op-by-op EXLA, 52 ms
  # fused here. What remains is dominated by moving the frame across the host
  # boundary (~1 MB u8 in, 4.9 MB f32 out), not by the arithmetic.
  #
  # The padding sizes are `defn` options, so XLA compiles one kernel per distinct
  # image aspect ratio and reuses it; a camera feed at a fixed resolution
  # compiles once. That first call costs 0.5-1.5 s.
  #
  # This path and the binary fallback agree to 1 ULP (max abs diff 5.96e-8): the
  # fallback divides in double precision and narrows to f32, XLA divides in f32.
  # Detections are identical.
  defnp letterbox(image, opts \\ []) do
    opts = keyword!(opts, [:pad_top, :pad_bottom, :pad_left, :pad_right])

    image
    |> Nx.pad(@pad_value, [
      {opts[:pad_top], opts[:pad_bottom], 0},
      {opts[:pad_left], opts[:pad_right], 0},
      {0, 0, 0}
    ])
    |> Nx.transpose(axes: [2, 0, 1])
    |> Nx.divide(255.0)
    |> Nx.as_type(:f32)
    |> Nx.new_axis(0)
  end

  # One linear pass per channel over the interleaved RGB bytes, emitting the
  # letterbox padding directly as f32 rather than building a padded u8 image
  # first. Used only when Nx has no accelerated backend.
  defp to_input_binary(resized, side, nh, nw, pad_x, pad_y) do
    pad = <<@pad_value / 255 :: float-32-native>>
    left = :binary.copy(pad, pad_x)
    right = :binary.copy(pad, side - nw - pad_x)
    top = :binary.copy(pad, pad_y * side)
    bottom = :binary.copy(pad, (side - nh - pad_y) * side)
    row_bytes = nw * 4

    for channel <- 0..2 do
      plane = channel_to_f32(resized.data, channel)
      rows = for y <- 0..(nh - 1), do: [left, :binary.part(plane, y * row_bytes, row_bytes), right]
      [top, rows, bottom]
    end
    |> IO.iodata_to_binary()
    |> Nx.from_binary(:f32)
    |> Nx.reshape({1, 3, side, side})
  end

  # Pull one channel out of an interleaved RGB u8 binary and scale it to f32
  # 0..1 in the same pass. Native endianness because that is what
  # Nx.from_binary/2 expects.
  defp channel_to_f32(bin, 0),
    do: for(<<v, _, _ <- bin>>, into: <<>>, do: <<v / 255 :: float-32-native>>)

  defp channel_to_f32(bin, 1),
    do: for(<<_, v, _ <- bin>>, into: <<>>, do: <<v / 255 :: float-32-native>>)

  defp channel_to_f32(bin, 2),
    do: for(<<_, _, v <- bin>>, into: <<>>, do: <<v / 255 :: float-32-native>>)

  ## Post-processing

  # Output is [1, 4 + nc, anchors]: rows 0..3 are cx, cy, w, h in input-space
  # pixels, the rest are per-class scores (already sigmoid'd by the export).
  # Boxes, best-class score and class id for every anchor, as ONE compiled kernel.
  # `nc` is a defn option so XLA compiles one kernel per class count and reuses it.
  defnp head(raw, opts \\ []) do
    opts = keyword!(opts, [:nc])
    t = raw |> Nx.squeeze(axes: [0]) |> Nx.transpose(axes: [1, 0])
    cls = Nx.slice_along_axis(t, 4, opts[:nc], axis: 1)

    {
      Nx.slice_along_axis(t, 0, 4, axis: 1),
      Nx.reduce_max(cls, axes: [1]),
      Nx.argmax(cls, axis: 1)
    }
  end

  defp decode(raw, conf) do
    {_batch, attrs, _anchors} = Nx.shape(raw)
    {boxes_t, scores_t, ids_t} = head(raw, nc: attrs - 4)

    # Threshold on the BEAM, but only over the 8400 per-anchor scores - the one
    # small vector in the whole head. Everything wide stays in the kernel above.
    kept =
      scores_t
      |> Nx.to_flat_list()
      |> Enum.with_index()
      |> Enum.filter(fn {score, _anchor} -> score >= conf end)

    if kept == [] do
      []
    else
      idx = Nx.tensor(Enum.map(kept, fn {_score, anchor} -> anchor end))

      boxes =
        boxes_t
        |> Nx.take(idx, axis: 0)
        |> Nx.to_flat_list()
        |> Enum.chunk_every(4)

      ids = ids_t |> Nx.take(idx) |> Nx.to_flat_list()

      [boxes, ids, Enum.map(kept, fn {score, _anchor} -> score end)]
      |> Enum.zip_with(fn [[cx, cy, w, h], id, score] ->
        %{
          class_id: id,
          score: score,
          x1: cx - w / 2,
          y1: cy - h / 2,
          x2: cx + w / 2,
          y2: cy + h / 2
        }
      end)
      |> Enum.sort_by(& &1.score, :desc)
    end
  end

  # Greedy per-class NMS. The candidate list is post-threshold, so it is small;
  # doing this in Elixir avoids another pass through Nx.
  defp nms(candidates, iou_threshold) do
    candidates
    |> Enum.group_by(& &1.class_id)
    |> Enum.flat_map(fn {_id, group} -> suppress(group, iou_threshold, []) end)
    |> Enum.sort_by(& &1.score, :desc)
  end

  defp suppress([], _iou, acc), do: Enum.reverse(acc)

  defp suppress([best | rest], iou, acc) do
    kept = Enum.reject(rest, fn other -> iou(best, other) > iou end)
    suppress(kept, iou, [best | acc])
  end

  defp iou(a, b) do
    ix1 = max(a.x1, b.x1)
    iy1 = max(a.y1, b.y1)
    ix2 = min(a.x2, b.x2)
    iy2 = min(a.y2, b.y2)

    inter = max(ix2 - ix1, 0) * max(iy2 - iy1, 0)
    area_a = max(a.x2 - a.x1, 0) * max(a.y2 - a.y1, 0)
    area_b = max(b.x2 - b.x1, 0) * max(b.y2 - b.y1, 0)
    union = area_a + area_b - inter

    if union > 0, do: inter / union, else: 0.0
  end

  # Undo the letterbox: remove padding, divide by the scale, clamp to the image.
  defp to_original_coords(det, geom, classes) do
    %{scale: scale, pad_x: pad_x, pad_y: pad_y, w0: w0, h0: h0} = geom

    x1 = clamp((det.x1 - pad_x) / scale, 0, w0)
    y1 = clamp((det.y1 - pad_y) / scale, 0, h0)
    x2 = clamp((det.x2 - pad_x) / scale, 0, w0)
    y2 = clamp((det.y2 - pad_y) / scale, 0, h0)

    %{
      class_id: det.class_id,
      class: Enum.at(classes, det.class_id, "class_#{det.class_id}"),
      score: Float.round(det.score * 1.0, 3),
      box: {round(x1), round(y1), round(x2), round(y2)}
    }
  end

  defp clamp(v, lo, hi), do: v |> max(lo) |> min(hi)
end
