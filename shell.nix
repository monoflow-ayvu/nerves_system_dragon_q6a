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

    # for QEMU smoke tests (see README) run: nix-shell -p qemu
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
    mix archive.install hex nerves_bootstrap --force
  '';

in mkShell {
  buildInputs = basePackages;
  shellHook = hooks;
}
