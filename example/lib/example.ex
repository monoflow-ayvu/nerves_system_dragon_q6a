defmodule Example do
  @moduledoc """
  Minimal smoke-test payload for the Dragon Q6A Nerves system.

  Its only job is to prove the boot chain reaches a live BEAM: it prints a
  banner the QEMU harness greps for, then leaves you at an IEx prompt.
  """

  @doc "Report the Hexagon NPU device nodes and DSP file map, if present."
  def npu_status do
    IO.puts("== FastRPC device nodes ==")
    case Path.wildcard("/dev/fastrpc-*") do
      [] -> IO.puts("  (none — expected under QEMU; real on hardware)")
      nodes -> Enum.each(nodes, &IO.puts("  #{&1}"))
    end

    IO.puts("== DSP library path (/usr/lib/dsp) ==")
    case File.ls("/usr/lib/dsp") do
      {:ok, files} -> files |> Enum.sort() |> Enum.each(&IO.puts("  #{&1}"))
      _ -> IO.puts("  (missing)")
    end

    :ok
  end
end
