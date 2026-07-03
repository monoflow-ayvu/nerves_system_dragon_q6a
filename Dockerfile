FROM ubuntu:22.04

# Host OTP major version MUST match the target OTP built by nerves_system_br.
# We pin the target to OTP 28 via BR2_PACKAGE_ERLANG_28=y in nerves_defconfig
# (28.5.0.2), so the container uses OTP 28 as well.
ARG OTP_VERSION=28.5.0.2
ARG ELIXIR_VERSION=1.19.5
ARG FWUP_VERSION=1.13.1

ENV DEBIAN_FRONTEND=noninteractive
ENV USER=root
ENV LANG=en_US.UTF-8

# Buildroot host dependencies + grub-common (grub-editenv used by
# post-build.sh to generate the A/B grubenv blocks).
RUN apt-get update && \
    apt-get install -y \
        build-essential bc bison flex gawk texinfo \
        libssl-dev libncurses-dev \
        cpio unzip zip rsync file wget curl git \
        squashfs-tools dosfstools mtools \
        python3 python3-dev \
        grub-common \
        fakeroot patch perl gzip bzip2 xz-utils zstd \
        locales ca-certificates openssh-client && \
    locale-gen en_US.UTF-8 && \
    apt-get clean && \
    rm -rf /var/lib/apt/lists/*

# Erlang/OTP (built from source to match the target OTP major exactly)
RUN wget -q https://github.com/erlang/otp/releases/download/OTP-${OTP_VERSION}/otp_src_${OTP_VERSION}.tar.gz && \
    tar xzf otp_src_${OTP_VERSION}.tar.gz && \
    cd otp_src_${OTP_VERSION} && \
    ./configure --without-javac --without-wx --without-odbc --without-observer --without-debugger --without-et && \
    make -j$(nproc) && \
    make install && \
    cd .. && rm -rf otp_src_${OTP_VERSION} otp_src_${OTP_VERSION}.tar.gz

# Elixir (precompiled for OTP 28)
RUN wget -q https://github.com/elixir-lang/elixir/releases/download/v${ELIXIR_VERSION}/elixir-otp-28.zip && \
    unzip -q -d /usr/local elixir-otp-28.zip && \
    rm elixir-otp-28.zip

# fwup (used on the host side of the build; Buildroot builds its own host-fwup
# too, but having it in PATH helps debugging)
RUN wget -q https://github.com/fwup-home/fwup/releases/download/v${FWUP_VERSION}/fwup_${FWUP_VERSION}_amd64.deb && \
    apt-get update && apt-get install -y ./fwup_${FWUP_VERSION}_amd64.deb && \
    rm fwup_${FWUP_VERSION}_amd64.deb && \
    apt-get clean && rm -rf /var/lib/apt/lists/*

# Hex/rebar for any mix invocations inside the container
RUN mix local.hex --force && mix local.rebar --force

# Buildroot refuses some operations as root without this
ENV FORCE_UNSAFE_CONFIGURE=1
