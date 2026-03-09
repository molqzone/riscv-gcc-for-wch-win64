FROM ubuntu:22.04

# Proxy support for build-time network access (set via --build-arg).
ARG HTTP_PROXY
ARG HTTPS_PROXY
ARG http_proxy
ARG https_proxy
ENV HTTP_PROXY=${HTTP_PROXY} \
    HTTPS_PROXY=${HTTPS_PROXY} \
    http_proxy=${http_proxy} \
    https_proxy=${https_proxy}

RUN apt-get update && apt-get install -y --no-install-recommends \
  autoconf automake autotools-dev curl python3 python3-pip python3-tomli \
  libmpc-dev libmpfr-dev libgmp-dev gawk build-essential bison flex texinfo \
  gperf libtool patchutils bc zlib1g-dev libexpat-dev ninja-build git cmake \
  libglib2.0-dev libslirp-dev libncurses-dev \
  gcc-mingw-w64-x86-64 g++-mingw-w64-x86-64 binutils-mingw-w64-x86-64 \
  && rm -rf /var/lib/apt/lists/*

ARG PREFIX=/opt/riscv
ARG ARCH=rv32imac
ARG ABI=ilp32
ARG MULTILIB="rv32imac-ilp32--zicsr*zifencei*zaamo*zalrsc;rv32imafc-ilp32f--zicsr*zifencei*zaamo*zalrsc"

RUN git clone --recursive https://github.com/riscv-collab/riscv-gnu-toolchain /src
WORKDIR /src
RUN git submodule update --init --recursive

ENV CC=x86_64-w64-mingw32-gcc \
    CXX=x86_64-w64-mingw32-g++ \
    AR=x86_64-w64-mingw32-ar \
    RANLIB=x86_64-w64-mingw32-ranlib \
    NM=x86_64-w64-mingw32-nm \
    STRIP=x86_64-w64-mingw32-strip

RUN ./configure --prefix=${PREFIX} \
    --with-arch=${ARCH} --with-abi=${ABI} \
    --with-multilib-generator="${MULTILIB}" \
    --host=x86_64-w64-mingw32

RUN make -j$(nproc)
RUN make install
