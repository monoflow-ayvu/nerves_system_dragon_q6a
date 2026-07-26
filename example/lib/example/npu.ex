defmodule Example.NPU do
  @moduledoc """
  ONNX inference on the Hexagon NPU (HTP) via `ortex`.

  The QNN execution provider is a *shared provider*: ONNX Runtime `dlopen()`s
  `libonnxruntime_providers_qnn.so` when a session appends `"QNN"` by name, and
  that in turn loads the QNN backend from `ORTEX_QNN_BACKEND_PATH`
  (default `/usr/lib/libQnnHtp.so`, installed by the qairt-runtime package).

  ## Bench usage

      Example.NPU.info()          # what's installed / reachable
      Example.NPU.run(:cpu)       # baseline, should always work
      Example.NPU.run(:qnn)       # on the NPU
      Example.NPU.compare()       # both, and assert they agree

  ## Caveats

  * The DSP has a warm-up race: the first FastRPC/QNN session right after boot
    can fail with `0x72` / `0xffffffff` while `cdsprpcd` is still establishing
    its CDSP session. Retry before believing a failure.
  * There is no on-device graph compilation (`libQnnHtpPrepare.so` is not
    vendored, it is 89 MB). Large models must be pre-compiled to a QNN context
    binary on a host; unsupported subgraphs fall back to CPU.
  * A model that QNN cannot handle does not error - it silently runs on CPU.
    `compare/0` exists because "it returned the right answer" does NOT prove the
    NPU did the work.
  """

  @model_path "addmul.onnx"

  @doc "Absolute path to the bundled test model (y = (a + b) * 2, shape {1, 4})."
  def model_path, do: Application.app_dir(:example, ["priv", @model_path])

  @doc """
  Report what the ONNX/QNN stack looks like on this device, without running
  anything. Useful first call when something fails.
  """
  def info do
    %{
      model: {model_path(), File.exists?(model_path())},
      ort_dylib: env_and_exists("ORT_DYLIB_PATH", "/usr/lib/libonnxruntime.so"),
      qnn_backend: env_and_exists("ORTEX_QNN_BACKEND_PATH", "/usr/lib/libQnnHtp.so"),
      qnn_provider: file_info("/usr/lib/libonnxruntime_providers_qnn.so"),
      dsp_library_path: System.get_env("DSP_LIBRARY_PATH"),
      remoteprocs: remoteproc_states(),
      fastrpc_nodes: Path.wildcard("/dev/fastrpc-*"),
      cdsprpcd_running?: match?({_, 0}, System.cmd("pidof", ["cdsprpcd"], stderr_to_stdout: true))
    }
  end

  @doc """
  Load the model on `ep` (`:cpu` or `:qnn`) and run one inference.

  Returns `{:ok, list, microseconds}` or `{:error, reason}`.
  """
  def run(ep \\ :qnn, a \\ [1.0, 2.0, 3.0, 4.0], b \\ [10.0, 20.0, 30.0, 40.0]) do
    ta = Nx.tensor([a], type: :f32)
    tb = Nx.tensor([b], type: :f32)

    try do
      model = Ortex.load(model_path(), [ep])
      # Warm the session once; the first QNN call also pays graph setup.
      _ = Ortex.run(model, {ta, tb})

      {us, {out}} = :timer.tc(fn -> Ortex.run(model, {ta, tb}) end)
      {:ok, out |> Nx.backend_transfer() |> Nx.to_flat_list(), us}
    rescue
      e -> {:error, Exception.message(e)}
    catch
      :error, e -> {:error, inspect(e)}
    end
  end

  @doc """
  Run the QDQ-quantized MatMul model, which is what the HTP can actually accept.

  A float32 graph (see `addmul.onnx`) is claimed by *no* QNN nodes, so ONNX
  Runtime silently assigns everything to CPU. QNN HTP works on quantized
  QuantizeLinear/DequantizeLinear node groups.
  """
  def run_qdq(ep \\ :qnn, x \\ [1.0, 2.0, 3.0, 4.0, 5.0, 6.0, 7.0, 8.0]) do
    tx = Nx.tensor([x], type: :f32)
    path = Application.app_dir(:example, ["priv", "qdqmatmul.onnx"])

    try do
      model = Ortex.load(path, [ep])
      _ = Ortex.run(model, {tx})
      {us, {out}} = :timer.tc(fn -> Ortex.run(model, {tx}) end)
      {:ok, out |> Nx.backend_transfer() |> Nx.to_flat_list(), us}
    rescue
      e -> {:error, Exception.message(e)}
    catch
      :error, e -> {:error, inspect(e)}
    end
  end

  @doc """
  Falsification test - the only trustworthy way to tell whether the NPU is
  really doing the work.

  Runs `fun` with a deliberately invalid QNN backend path. If the run still
  succeeds, the QNN EP is NOT engaged and ONNX Runtime is silently on CPU:
  matching output values prove nothing on their own. If it fails, QNN really is
  loading the backend.
  """
  def prove_qnn(fun \\ &run_qdq/0) do
    good = System.get_env("ORTEX_QNN_BACKEND_PATH") || "/usr/lib/libQnnHtp.so"
    System.put_env("ORTEX_QNN_BACKEND_PATH", "/nonexistent/libQnnHtp.so")
    bogus = fun.()
    System.put_env("ORTEX_QNN_BACKEND_PATH", good)
    real = fun.()

    verdict =
      case {bogus, real} do
        {{:error, _}, {:ok, _, _}} -> :qnn_genuinely_used
        {{:ok, _, _}, {:ok, _, _}} -> :silently_on_cpu
        _ -> :inconclusive
      end

    %{with_bogus_backend: bogus, with_real_backend: real, verdict: verdict}
  end

  @doc """
  Run on CPU and QNN and compare. Note that agreement alone does NOT prove the
  NPU ran - use `prove_qnn/1` for that.
  """
  def compare do
    cpu = run(:cpu)
    qnn = run(:qnn)

    agree? =
      case {cpu, qnn} do
        {{:ok, c, _}, {:ok, q, _}} -> Enum.zip(c, q) |> Enum.all?(fn {x, y} -> abs(x - y) < 1.0e-3 end)
        _ -> false
      end

    %{cpu: cpu, qnn: qnn, agree?: agree?, expected: [22.0, 44.0, 66.0, 88.0]}
  end

  defp env_and_exists(var, default) do
    path = System.get_env(var) || default
    {path, File.exists?(path)}
  end

  defp file_info(path) do
    case File.stat(path) do
      {:ok, %{size: s}} -> {path, s}
      _ -> {path, :missing}
    end
  end

  defp remoteproc_states do
    Path.wildcard("/sys/class/remoteproc/*/")
    |> Map.new(fn d ->
      {read_trim(Path.join(d, "name")), read_trim(Path.join(d, "state"))}
    end)
  end

  defp read_trim(p) do
    case File.read(p) do
      {:ok, s} -> String.trim(s)
      _ -> nil
    end
  end
end
