with import <nixpkgs> { };
let
  # The target is pinned to OTP 28 (BR2_PACKAGE_ERLANG_28=y in
  # nerves_defconfig); the host OTP major must match when building Nerves
  # applications against this system.
  otp = beam28Packages;
  elixir = if builtins.hasAttr "elixir_1_19" otp then otp.elixir_1_19 else otp.elixir;

  basePackages = [
    elixir
    otp.erlang
    otp.elixir-ls

    # build deps for nerves
    pkg-config
    fwup
    squashfsTools
    gnumake
    gcc

    # image tooling: install-to-disk.sh (sgdisk), ESP inspection (mtools)
    gptfdisk
    mtools

    # QEMU smoke test (test/qemu-smoke.sh): qemu-system-aarch64 + EDK2
    # aarch64 firmware ship together in the qemu package.
    qemu
  ];
  PROJECT_ROOT = builtins.toString ./.;

  hooks = ''
    mkdir -p .nix-mix .nix-hex
    export MIX_HOME=${PROJECT_ROOT}/.nix-mix
    export HEX_HOME=${PROJECT_ROOT}/.nix-hex
    export PATH=$MIX_HOME/bin:$HEX_HOME/bin:$PATH
    export LANG=en_US.UTF-8
    export ERL_AFLAGS="-kernel shell_history enabled"

    mix local.hex --force --if-missing
    mix local.rebar --force --if-missing
    # Install nerves_bootstrap only if it's not already present, so repeated
    # shell/direnv loads stay fast.
    mix archive | grep -q nerves_bootstrap || mix archive.install hex nerves_bootstrap --force
  '';

in mkShell {
  buildInputs = basePackages;
  shellHook = hooks;
}
