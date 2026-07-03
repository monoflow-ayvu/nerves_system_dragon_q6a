defmodule Example.MixProject do
  use Mix.Project

  @app :example
  @version "0.1.0"
  @all_targets [:dragon_q6a]

  def project do
    [
      app: @app,
      version: @version,
      elixir: "~> 1.17",
      archives: [nerves_bootstrap: "~> 1.13"],
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      releases: [{@app, release()}],
      preferred_cli_target: [run: :host, test: :host]
    ]
  end

  def application do
    [
      extra_applications: [:logger, :runtime_tools],
      mod: {Example.Application, []}
    ]
  end

  defp deps do
    [
      # Core Nerves
      {:nerves, "~> 1.13", runtime: false},
      {:shoehorn, "~> 0.9"},
      {:ring_logger, "~> 0.11"},
      {:toolshed, "~> 0.4"},

      # Allow Nerves.Runtime on host for dev/test.
      {:nerves_runtime, "~> 0.13"},

      # The system under test.
      {:nerves_system_dragon_q6a,
       path: "../", runtime: false, targets: :dragon_q6a, nerves: [compile: true]}
    ]
  end

  defp release do
    [
      overwrite: true,
      cookie: "#{@app}_cookie",
      include_erts: &Nerves.Release.erts/0,
      steps: [&Nerves.Release.init/1, :assemble],
      strip_beams: Mix.env() == :prod or [keep: ["Docs"]]
    ]
  end
end
