# Loaded for every IEx session on the target (rel/vm.args.eex passes
# --dot-iex /etc/iex.exs).
Application.put_env(:elixir, :ansi_enabled, true)

# Nerves MOTD: firmware version, active A/B slot, uptime, network addresses.
# The active-slot line is the quick way to confirm which slot booted after an
# OTA or an auto-rollback.
NervesMOTD.print()

# Toolshed gives cmd/1, ifconfig/0, dmesg/0, lsmod/0, top/0, reboot/0 and
# friends. Without this import you have to spell out Toolshed.cmd("...").
import Toolshed
