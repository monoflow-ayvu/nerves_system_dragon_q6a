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

    # nerves_uevent's NIF #includes <libmnl/libmnl.h>. The target gets this
    # from BR2_PACKAGE_LIBMNL (already enabled), but a HOST build — which is
    # what `mix` does when MIX_TARGET is unset — needs it here or it dies with
    # "fatal error: libmnl/libmnl.h: No such file or directory".
    libmnl

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

    # Send all mix chatter to stderr. Under `direnv use nix`, stdout is captured
    # to extract the environment and is closed once the env dump is read; a late
    # write from mix (e.g. "Archives installed at: ...") would otherwise hit a
    # closed pipe and crash with :epipe / :terminated.
    mix local.hex --force --if-missing 1>&2
    mix local.rebar --force --if-missing 1>&2
    # Install nerves_bootstrap only if it's not already present, so repeated
    # shell/direnv loads stay fast.
    mix archive | grep -q nerves_bootstrap || mix archive.install hex nerves_bootstrap --force 1>&2

    # Default to the board target, like ../nerves_system_sg2002/shell.nix does.
    # Without this, `cd example && mix firmware` inherits MIX_TARGET=host and
    # tries to build target-only NIFs (nerves_uevent) for the host. The system
    # project itself is unaffected: its mix.exs calls set_target() which forces
    # MIX_TARGET=target regardless of this value.
    export MIX_TARGET=dragon_q6a
  '';

in mkShell {
  buildInputs = basePackages;
  shellHook = hooks;
}
