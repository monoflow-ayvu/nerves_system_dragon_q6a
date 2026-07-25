import Config

# Console tty: ttyMSM0 on real hardware (GENI UART), ttyAMA0 under QEMU
# (-M virt PL011). The QEMU smoke test exports NERVES_CONSOLE=ttyAMA0 before
# `mix firmware` so a single code path serves both.
ctty = System.get_env("NERVES_CONSOLE", "ttyMSM0")
config :nerves, :erlinit, ctty: ctty

config :logger, backends: [RingLogger]

# A/B rollback: validate firmware only once the application is actually up.
#
# The system ships with nerves_fw_autovalidate=0, so a freshly written slot
# stays unvalidated and GRUB gives it exactly one boot (see grub.cfg). What
# clears that trial state is StartupGuard: it waits for every expected OTP
# application to start, then calls Nerves.Runtime.validate_firmware/0. If the
# release crash-loops or an application never starts, the firmware is never
# validated and the next reboot falls back to the previous slot.
#
# Without this, validation happened before the BEAM even started, so a
# crash-looping release was marked good and could never be rolled back.
# Requires -env HEART_INIT_TIMEOUT in rel/vm.args.eex.
config :nerves_runtime, startup_guard_enabled: true
