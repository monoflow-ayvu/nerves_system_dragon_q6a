# The `xla` package resolves which precompiled XLA archive to fetch at *its*
# compile time, from the environment. Mix evaluates this file before compiling
# any dependency, so this is the place to redirect it at the target's platform -
# otherwise a target build links EXLA against a host-arch libxla_extension.so.
if System.get_env("MIX_TARGET") not in [nil, "", "host"] do
  System.put_env("XLA_TARGET_PLATFORM", "aarch64-linux-gnu")
  System.put_env("XLA_TARGET", "cpu")
end

defmodule Example.MixProject do
  use Mix.Project

  @app :example
  @version "0.1.0"
  @all_targets [:dragon_q6a]

  # github.com/monoflow-ayvu/ortex main @ 2026-07-27
  @ortex_ref "313c46777fc4656942fe94e0e57d7be08b7af738"

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

      # ONNX inference on the Hexagon NPU. Our fork of elixir-nx/ortex: adds the
      # :qnn execution provider, thread-pool/tracing controls, and switches `ort`
      # to load-dynamic so it uses the system libonnxruntime instead of
      # downloading a host-arch one.
      #
      # Pinned to an explicit ref rather than a branch so a build is reproducible,
      # and fetched from git rather than a relative path so this project can be
      # cloned anywhere without a required sibling checkout.
      #
      # The SSH URL is deliberate: monoflow-ayvu/ortex is currently PRIVATE (the
      # GitHub API 404s unauthenticated), so the https form would prompt for
      # credentials. If the repo is made public, this becomes
      #     {:ortex, github: "monoflow-ayvu/ortex", ref: @ortex_ref, override: true}
      {:ortex,
       git: "git@github.com:monoflow-ayvu/ortex.git",
       ref: @ortex_ref,
       override: true},
      {:nx, "~> 0.6"},

      # XLA-backed Nx. Needed because BinaryBackend evaluates elementwise and
      # transpose operations one element at a time: the image preprocessing this
      # replaces took 9.0 s per frame through it.
      {:exla, "~> 0.13"},

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

  # Apps we depend on that ship a NIF. A missing .so does not fail the build - it
  # fails at BOOT, with on_load_function_failed taking the whole VM down before
  # anything can report it. That happened: the ortex NIF was gitignored, its
  # priv/native was removed, `mix compile` did not notice the deleted artifact
  # (Mix's staleness check only looks at sources), and the resulting firmware
  # bricked the slot on boot. Only the A/B rollback saved the board. Cheap to
  # check here, expensive to debug there.
  @nif_apps [:ortex, :stb_image, :exla]

  defp verify_nifs(release) do
    missing =
      for app <- @nif_apps,
          path = Map.get(release.applications, app) |> then(&(&1 && &1[:path])),
          path != nil,
          Path.wildcard(Path.join([path, "priv", "**", "*.so"])) == [] do
        app
      end

    if missing != [] do
      Mix.raise("""
      Release is missing NIF shared objects for: #{inspect(missing)}

      This firmware would fail at boot with on_load_function_failed and roll back.
      Rebuild the NIF(s) with, e.g.:

          mix deps.compile #{Enum.join(missing, " ")} --force
      """)
    end

    release
  end

  defp release do
    [
      overwrite: true,
      cookie: "#{@app}_cookie",
      include_erts: &Nerves.Release.erts/0,
      steps: [&Nerves.Release.init/1, :assemble, &verify_nifs/1],
      strip_beams: Mix.env() == :prod or [keep: ["Docs"]]
    ]
  end
end
