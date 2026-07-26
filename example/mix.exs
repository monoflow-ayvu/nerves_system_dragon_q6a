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

      # Networking + remote access. nerves_pack pulls in vintage_net,
      # vintage_net_ethernet, vintage_net_wifi, nerves_ssh, mdns_lite and
      # nerves_time, which is the whole "get on the network and let me in" set.
      # SSH is what makes OTA (`mix upload`) and remote debugging possible, so
      # this is a prerequisite for bench work beyond the HDMI console.
      {:nerves_pack, "~> 0.7"},
      {:nerves_motd, "~> 0.1"},

      # ONNX inference on the Hexagon NPU. Local fork of elixir-nx/ortex that
      # adds the :qnn execution provider and switches `ort` to load-dynamic so
      # it uses the system libonnxruntime instead of downloading a host-arch one.
      {:ortex, path: "../../ortex", override: true},
      {:nx, "~> 0.6"},

      # JPEG/PNG decoding and resizing for Example.Yolo. A C NIF (stb_image.h),
      # no libjpeg/libpng needed on the target. cc_precompiler picks the
      # aarch64-linux-gnu artifact for this target, which needs only GLIBC_2.17
      # and links nothing but libc - so it drops straight into the firmware and
      # no source cross-compile is required.
      {:stb_image, "~> 0.6"},

      # Allow Nerves.Runtime on host for dev/test.
      {:nerves_runtime, "~> 0.13"},

      # The system under test.
      {:nerves_system_dragon_q6a,
       path: "../", runtime: false, targets: @all_targets, nerves: [compile: true]}
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
