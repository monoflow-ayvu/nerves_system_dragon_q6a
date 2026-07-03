defmodule Example.Application do
  @moduledoc false
  use Application
  require Logger

  @impl true
  def start(_type, _args) do
    # Banner the QEMU smoke test greps for to confirm the BEAM booted.
    IO.puts("\n=== EXAMPLE APP UP: Dragon Q6A Nerves runtime is alive ===\n")
    Logger.info("Example.Application started on #{target()}")

    children = []
    opts = [strategy: :one_for_one, name: Example.Supervisor]
    Supervisor.start_link(children, opts)
  end

  defp target do
    Application.get_env(:example, :target, "host")
  end
end
