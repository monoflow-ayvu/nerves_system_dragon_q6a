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

    # Rust, for cross-compiling rustler NIFs (ortex) to the board. nixpkgs'
    # `rustc` ships only the host std, so we need rustup to get the
    # aarch64-unknown-linux-gnu target:
    #     rustup toolchain install stable --profile minimal
    #     rustup target add aarch64-unknown-linux-gnu
    rustup

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

    # Put the Nerves cross toolchain on PATH. rustler's cargo invocation needs
    # to find aarch64-nerves-linux-gnu-gcc by bare name as the linker, and the
    # rustler :target/:env config in example/config/target.exs is evaluated
    # before nerves_bootstrap exports CC/CROSSCOMPILE - so PATH is the only
    # thing we can rely on there.
    for _tc in $HOME/.local/share/nerves/artifacts/nerves_toolchain_aarch64_nerves_linux_gnu-*/bin; do
      [ -d "$_tc" ] && export PATH="$_tc:$PATH"
    done

    # nix's rustup wrapper does NOT create ~/.cargo/bin shims, so put the
    # installed toolchain's real bin dir on PATH for rustler/cargo to find.
    export RUSTUP_HOME=$HOME/.rustup
    export CARGO_HOME=$HOME/.cargo
    if [ -d "$RUSTUP_HOME/toolchains/stable-x86_64-unknown-linux-gnu/bin" ]; then
      export PATH="$RUSTUP_HOME/toolchains/stable-x86_64-unknown-linux-gnu/bin:$PATH"
    fi

    # Default to the board target, like ../nerves_system_sg2002/shell.nix does.
    # Without this, `cd example && mix firmware` inherits MIX_TARGET=host and
    # tries to build target-only NIFs (nerves_uevent) for the host. The system
    # project itself is unaffected: its mix.exs calls set_target() which forces
    # MIX_TARGET=target regardless of this value.
    export MIX_TARGET=dragon_q6a

    # Pin cargo's default target to the board.
    #
    # `config :ortex, Ortex.Native, target: ...` in example/config/target.exs is
    # honoured by `mix deps.compile ortex --force` but NOT by a plain
    # `mix compile` that happens to recompile ortex's .ex files - that path built
    # an x86-64 NIF and only surfaced later as
    # "scrub-otp-release.sh: ERROR: Unexpected executable format". Setting the
    # target in cargo's own environment makes both Mix paths agree; cargo still
    # builds build scripts and proc macros for the host by itself.
    export CARGO_BUILD_TARGET=aarch64-unknown-linux-gnu
    export CARGO_TARGET_AARCH64_UNKNOWN_LINUX_GNU_LINKER=aarch64-nerves-linux-gnu-gcc
    export CC_aarch64_unknown_linux_gnu=aarch64-nerves-linux-gnu-gcc
    export AR_aarch64_unknown_linux_gnu=aarch64-nerves-linux-gnu-ar
    # Host-side C in build scripts must use host tools; Nerves exports CC/CFLAGS
    # for aarch64, which otherwise feeds flags like -m64 to the cross gcc.
    export CC_x86_64_unknown_linux_gnu=cc
    export CXX_x86_64_unknown_linux_gnu=c++
    export CFLAGS_x86_64_unknown_linux_gnu=""
    export HOST_CC=cc
  '';

in mkShell {
  buildInputs = basePackages;
  shellHook = hooks;
}
