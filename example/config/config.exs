import Config

# Enable the Nerves integration with Mix (must run before any nerves_package
# dependency is compiled).
Application.start(:nerves_bootstrap)

# Shoehorn starts the app after nerves_runtime and nerves_pack, so networking
# and sshd are up before Example.Application runs.
config :shoehorn, init: [:nerves_runtime, :nerves_pack]

config :logger, backends: [RingLogger]

config :example, target: Mix.target()

# Bring in target-specific config (only :dragon_q6a here).
if Mix.target() != :host do
  import_config "target.exs"
end
