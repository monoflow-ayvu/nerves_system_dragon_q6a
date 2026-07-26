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

# Ship /etc/iex.exs (Nerves MOTD + Toolshed helpers). rel/vm.args.eex passes
# --dot-iex /etc/iex.exs, so this is the file that gets loaded per IEx session.
config :nerves, :firmware, rootfs_overlay: "rootfs_overlay"

# ---------------------------------------------------------------------------
# Networking
# ---------------------------------------------------------------------------
# WiFi credentials live in config/secrets.exs, which is gitignored. Copy
# config/secrets.exs.example over it and edit. That file is a plain map, not a
# Config script, so every structural decision below stays in git and only the
# secret values sit outside it. Env vars win, which is convenient for CI:
#
#     WIFI_SSID=guest WIFI_PSK=hunter2 mix firmware
secrets_path = Path.join(__DIR__, "secrets.exs")

secrets =
  if File.exists?(secrets_path) do
    {value, _bindings} = Code.eval_file(secrets_path)
    value
  else
    %{}
  end

wifi_ssid = System.get_env("WIFI_SSID") || secrets[:ssid]
wifi_psk = System.get_env("WIFI_PSK") || secrets[:psk]

# Treat the shipped placeholder as "unconfigured" so a fresh clone builds and
# boots without either failing or silently trying to join a bogus SSID.
configured? = is_binary(wifi_ssid) and wifi_ssid not in ["", "YOUR_WIFI_SSID"]
psk? = is_binary(wifi_psk) and wifi_psk not in ["", "YOUR_WIFI_PASSPHRASE"]

wifi_networks =
  cond do
    configured? and psk? -> [%{key_mgmt: :wpa_psk, ssid: wifi_ssid, psk: wifi_psk}]
    configured? -> [%{key_mgmt: :none, ssid: wifi_ssid}]
    true -> []
  end

if wifi_networks == [] do
  IO.warn("""
  No WiFi credentials configured — wlan0 will come up but not associate.
  Set them in example/config/secrets.exs (see secrets.exs.example) or pass
  WIFI_SSID / WIFI_PSK in the environment. eth0/DHCP is unaffected.
  """)
end

config :vintage_net,
  regulatory_domain:
    System.get_env("WIFI_REGULATORY_DOMAIN") || secrets[:regulatory_domain] || "00",
  config: [
    {"eth0", %{type: VintageNetEthernet, ipv4: %{method: :dhcp}}},
    {"wlan0",
     %{
       type: VintageNetWiFi,
       vintage_net_wifi: %{networks: wifi_networks},
       ipv4: %{method: :dhcp}
     }}
  ]

# Advertise <hostname>.local and nerves.local so `ssh nerves.local` works
# without hunting for a DHCP lease.
config :mdns_lite,
  hosts: [:hostname, "nerves"],
  ttl: 120

# ---------------------------------------------------------------------------
# SSH — required for OTA (`mix upload`) and remote IEx
# ---------------------------------------------------------------------------
# Public keys are read from the BUILD HOST at build time. No key means no way
# in, so fail loudly rather than shipping an unreachable board.
authorized_keys =
  [
    "id_ed25519.pub",
    "id_rsa.pub",
    "id_ecdsa.pub"
  ]
  |> Enum.map(&Path.join([System.user_home!(), ".ssh", &1]))
  |> Enum.filter(&File.exists?/1)
  |> Enum.map(&File.read!/1)

if authorized_keys == [] do
  IO.warn("""
  No SSH public key found in ~/.ssh (looked for id_ed25519.pub, id_rsa.pub,
  id_ecdsa.pub). SSH will start but reject every login, so `mix upload` and
  remote IEx will not work. Generate one with `ssh-keygen -t ed25519`.
  """)
end

config :nerves_ssh, authorized_keys: authorized_keys
