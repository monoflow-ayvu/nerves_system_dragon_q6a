import Config

# Console tty: ttyMSM0 on real hardware (GENI UART), ttyAMA0 under QEMU
# (-M virt PL011). The QEMU smoke test exports NERVES_CONSOLE=ttyAMA0 before
# `mix firmware` so a single code path serves both.
ctty = System.get_env("NERVES_CONSOLE", "ttyMSM0")
config :nerves, :erlinit, ctty: ctty

config :logger, backends: [RingLogger]
