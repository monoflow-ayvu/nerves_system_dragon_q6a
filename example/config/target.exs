import Config

# Console tty: ttyMSM0 on real hardware (GENI UART), ttyAMA0 under QEMU
# (-M virt PL011). The QEMU smoke test exports NERVES_CONSOLE=ttyAMA0 before
# `mix firmware` so a single code path serves both.
ctty = System.get_env("NERVES_CONSOLE", "ttyMSM0")
config :nerves, :erlinit, ctty: ctty

config :logger, backends: [RingLogger]

# XLA-backed Nx. BinaryBackend evaluates elementwise and transpose operations
# one element at a time, which is unusable on image-sized tensors here - the
# Example.Yolo preprocessing measured 9.0 s per 640x640 frame through it.
# The client is lazy: nothing loads libxla_extension.so until Nx runs an op.
config :nx, default_backend: EXLA.Backend
config :exla, clients: [host: [platform: :host]], default_client: :host

# Compile `defn` with EXLA rather than running it through Nx's interpreter. This
# is what fuses a pipeline into one XLA kernel; without it, EXLA.Backend still
# executes op-by-op with a host round-trip per operation.
config :nx, default_defn_options: [compiler: EXLA]

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

# ---------------------------------------------------------------------------
# ortex / ONNX Runtime on the Hexagon NPU
# ---------------------------------------------------------------------------
# Cross-compile the rustler NIF for the board. Rust's triple is
# aarch64-unknown-linux-gnu while the Nerves toolchain is
# aarch64-nerves-linux-gnu -- different vendor, same ABI, so linking works.
# CROSSCOMPILE is exported by Nerves during `mix firmware` and is the tool
# prefix, e.g. /path/to/bin/aarch64-nerves-linux-gnu.
#
# Requires the Rust target once per machine:
#     rustup target add aarch64-unknown-linux-gnu
# This file is only imported when Mix.target() != :host (see config.exs), so the
# board target is unconditional here. Do NOT try to detect the toolchain from
# CC/CROSSCOMPILE: Mix evaluates config before nerves_bootstrap exports those,
# so the check silently fails and rustler builds a HOST .so, which Nerves then
# rejects with "scrub-otp-release.sh: ERROR: Unexpected executable format".
#
# The tool names are therefore bare, and shell.nix puts the Nerves toolchain's
# bin/ on PATH. Rust's triple is aarch64-unknown-linux-gnu while the toolchain
# is aarch64-nerves-linux-gnu: different vendor, same ABI, so linking is fine.
config :ortex, Ortex.Native,
  target: "aarch64-unknown-linux-gnu",
  env: [
    {"CARGO_TARGET_AARCH64_UNKNOWN_LINUX_GNU_LINKER", "aarch64-nerves-linux-gnu-gcc"},
    {"CC_aarch64_unknown_linux_gnu", "aarch64-nerves-linux-gnu-gcc"},
    {"AR_aarch64_unknown_linux_gnu", "aarch64-nerves-linux-gnu-ar"},
    # Cargo build scripts and proc macros are compiled and RUN on the build
    # machine. Nerves exports CC/CFLAGS pointing at the aarch64 toolchain, so
    # without pinning host tools a host-side C build gets x86 flags like `-m64`
    # fed to the cross gcc and dies. (Dropping ortex's unused `rustls` removed
    # the main offender, `ring`, but keep these so the next such dep is safe.)
    {"CC_x86_64_unknown_linux_gnu", "cc"},
    {"CXX_x86_64_unknown_linux_gnu", "c++"},
    {"HOST_CC", "cc"},
    {"CFLAGS_x86_64_unknown_linux_gnu", ""}
  ]
