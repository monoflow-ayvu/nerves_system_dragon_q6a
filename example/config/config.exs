import Config

# Shoehorn starts the app after nerves_runtime.
config :shoehorn, init: [:nerves_runtime]

config :logger, backends: [RingLogger]

config :example, target: Mix.target()

# Bring in target-specific config (only :dragon_q6a here).
if Mix.target() != :host do
  import_config "target.exs"
end
