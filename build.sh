set -euxo pipefail

# Prepare wine wrappers so Canadian-cross binaries can run under wine.
mkdir -p /opt/wine-wrappers
cat > /opt/wine-wrappers/riscv32-unknown-elf-wrapper <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

# Skip GCC selftests that use /dev/null; they fail under Wine with Windows paths.
for arg in "$@"; do
  case "$arg" in
    -fself-test=*) exit 0 ;;
  esac
 done

WINE_BIN=${WINE_BIN:-/usr/lib/wine/wine64}
if [ ! -x "$WINE_BIN" ]; then
  if command -v wine64 >/dev/null 2>&1; then
    WINE_BIN=$(command -v wine64)
  elif command -v wine >/dev/null 2>&1; then
    WINE_BIN=$(command -v wine)
  else
    echo "wrapper: wine binary not found at $WINE_BIN" >&2
    exit 127
  fi
fi

to_win_path() {
  local p="$1"
  echo "Z:${p//\//\\}"
}

tool=$(basename "$0")
prefix=/opt/riscv
build_root=/src
gcc_dirs=(
  "$build_root/build-gcc-newlib-stage2/gcc"
  "$build_root/build-gcc-newlib/gcc"
  "$build_root/build-gcc-newlib-stage1/gcc"
)
binutils_root="$build_root/build-binutils-newlib"

run_wine_with_retries() {
  local max_retries delay rc attempt tmp_out tmp_err
  max_retries=${WINE_CMD_RETRIES:-4}
  delay=${WINE_CMD_RETRY_DELAY:-1}
  rc=0
  for attempt in $(seq 1 "$max_retries"); do
    tmp_out=$(mktemp)
    tmp_err=$(mktemp)
    rc=0
    "$WINE_BIN" "$@" >"$tmp_out" 2>"$tmp_err" || rc=$?
    if [ "$rc" -eq 0 ]; then
      cat "$tmp_out"
      cat "$tmp_err" >&2
      rm -f "$tmp_out" "$tmp_err"
      return 0
    fi

    # Only retry on transient Wine process-launch failures.
    if grep -Eiq 'CreateProcess|cannot execute' "$tmp_out" "$tmp_err"; then
      if [ "$attempt" -lt "$max_retries" ]; then
        rm -f "$tmp_out" "$tmp_err"
        sleep "$delay"
        continue
      fi
    fi

    cat "$tmp_out" >&2
    cat "$tmp_err" >&2
    rm -f "$tmp_out" "$tmp_err"
    return "$rc"
  done
  return "$rc"
}

extract_depfile_from_args() {
  local expect_mf=0 arg
  for arg in "$@"; do
    if [ "$expect_mf" -eq 1 ]; then
      echo "$arg"
      return 0
    fi
    case "$arg" in
      -MF)
        expect_mf=1
        ;;
      -MF?*)
        echo "${arg#-MF}"
        return 0
        ;;
    esac
  done
  return 1
}

sanitize_depfile_for_make() {
  local dep="$1"
  [ -n "$dep" ] || return 0
  # Under Wine-hosted target gcc, generated .dep files can intermittently be
  # malformed for GNU make. Dependency tracking is optional here, so drop them.
  rm -f "$dep" 2>/dev/null || true
}

run_gcc_tool() {
  local exe="$1"
  shift
  local dir win_dir win_gas win_ld sysroot sysinc_win
  local need_cc1 dep_file rc
  local -a extra_args
  for dir in "${gcc_dirs[@]}"; do
    if [ -f "${dir}/${exe}" ]; then
      # xgcc/xg++ can exist before cc1 is built in a stage dir; skip that dir.
      case "$exe" in
        xgcc.exe|xg++.exe|cpp.exe)
          need_cc1=1
          # GCC stage1 runs metadata queries such as "-dumpspecs" before cc1.exe
          # is available. Those invocations are valid and should not be skipped.
          for a in "$@"; do
            case "$a" in
              -dumpspecs|-dumpmachine|-dumpversion|-dumpfullversion|-print-multi-lib|-print-search-dirs|-print-sysroot|-print-libgcc-file-name|-print-file-name=*|-print-prog-name=*)
                need_cc1=0
                break
                ;;
            esac
          done
          if [ "$need_cc1" -eq 1 ] && [ ! -f "${dir}/cc1.exe" ]; then
            continue
          fi
          ;;
      esac
      win_dir=$(to_win_path "$dir")
      win_gas=$(to_win_path "$binutils_root/gas")
      win_ld=$(to_win_path "$binutils_root/ld")
      local tmp_root win_tmp
      tmp_root=${WINE_TMP_ROOT:-/tmp/wine-tmp}
      mkdir -p "$tmp_root"
      win_tmp=$(to_win_path "$tmp_root")
      export TMP="$win_tmp"
      export TEMP="$win_tmp"
      export TMPDIR="$tmp_root"
      export GCC_EXEC_PREFIX="${win_dir}\\"
      # Prefer binutils build dirs for as/ld/nm so xgcc doesn't pick broken stage1 helpers.
      export COMPILER_PATH="${win_gas};${win_ld};${win_dir}"
      export PATH="${binutils_root}/gas:${binutils_root}/ld:${dir}:${PATH}"
      extra_args=()
      case "$exe" in
        xgcc.exe|xg++.exe|cpp.exe)
          # Stage1 GCC does not discover newlib headers automatically.
          # Pin target sysroot include to avoid stdio.h-not-found in libgcc.
          sysroot="${prefix}/riscv32-unknown-elf"
          sysinc_win=$(to_win_path "${sysroot}/include")
          extra_args=(--sysroot="${sysroot}" -isystem "${sysinc_win}")
          ;;
      esac
      dep_file=""
      if dep_file=$(extract_depfile_from_args "$@"); then
        :
      fi
      run_wine_with_retries "${dir}/${exe}" "${extra_args[@]}" "$@"
      rc=$?
      if [ "$rc" -eq 0 ] && [ -n "$dep_file" ]; then
        sanitize_depfile_for_make "$dep_file"
      fi
      return "$rc"
    fi
  done
  return 1
}

run_binutils_tool() {
  local -a candidates=("$@")
  local exe
  unset GCC_EXEC_PREFIX COMPILER_PATH
  for exe in "${candidates[@]}"; do
    if [ -f "$exe" ]; then
      local tmp_root win_tmp
      tmp_root=${WINE_TMP_ROOT:-/tmp/wine-tmp}
      mkdir -p "$tmp_root"
      win_tmp=$(to_win_path "$tmp_root")
      export TMP="$win_tmp"
      export TEMP="$win_tmp"
      export TMPDIR="$tmp_root"
      run_wine_with_retries "$exe" "${tool_args[@]}"
      return $?
    fi
  done
  return 1
}

tool_args=()
for arg in "$@"; do
  tool_args+=("${arg//$'\r'/}")
done
case "$tool" in
  riscv32-unknown-elf-gcc) run_gcc_tool xgcc.exe "${tool_args[@]}"; exit $? ;;
  riscv32-unknown-elf-g++) run_gcc_tool xg++.exe "${tool_args[@]}"; exit $? ;;
  riscv32-unknown-elf-cpp) run_gcc_tool cpp.exe "${tool_args[@]}"; exit $? ;;
  riscv32-unknown-elf-gcc-ar) run_gcc_tool gcc-ar.exe "${tool_args[@]}"; exit $? ;;
  riscv32-unknown-elf-gcc-nm) run_gcc_tool gcc-nm.exe "${tool_args[@]}"; exit $? ;;
  riscv32-unknown-elf-gcc-ranlib) run_gcc_tool gcc-ranlib.exe "${tool_args[@]}"; exit $? ;;
  riscv32-unknown-elf-as)
    run_binutils_tool \
      "$binutils_root/gas/as-new.exe" \
      "$binutils_root/gas/.libs/as-new.exe" \
      "$prefix/bin/riscv32-unknown-elf-as.exe"
    exit $?
    ;;
  riscv32-unknown-elf-ld)
    run_binutils_tool \
      "$binutils_root/ld/ld-new.exe" \
      "$binutils_root/ld/.libs/ld-new.exe" \
      "$prefix/bin/riscv32-unknown-elf-ld.exe"
    exit $?
    ;;
  riscv32-unknown-elf-ar)
    run_binutils_tool \
      "$binutils_root/binutils/ar.exe" \
      "$prefix/bin/riscv32-unknown-elf-ar.exe"
    exit $?
    ;;
  riscv32-unknown-elf-ranlib)
    run_binutils_tool \
      "$binutils_root/binutils/ranlib.exe" \
      "$prefix/bin/riscv32-unknown-elf-ranlib.exe"
    exit $?
    ;;
  riscv32-unknown-elf-nm)
    run_binutils_tool \
      "$binutils_root/binutils/nm-new.exe" \
      "$binutils_root/binutils/nm.exe" \
      "$prefix/bin/riscv32-unknown-elf-nm.exe"
    exit $?
    ;;
  riscv32-unknown-elf-objcopy)
    run_binutils_tool \
      "$binutils_root/binutils/objcopy.exe" \
      "$prefix/bin/riscv32-unknown-elf-objcopy.exe"
    exit $?
    ;;
  riscv32-unknown-elf-objdump)
    run_binutils_tool \
      "$binutils_root/binutils/objdump.exe" \
      "$prefix/bin/riscv32-unknown-elf-objdump.exe"
    exit $?
    ;;
  riscv32-unknown-elf-strip)
    run_binutils_tool \
      "$binutils_root/binutils/strip-new.exe" \
      "$binutils_root/binutils/strip.exe" \
      "$prefix/bin/riscv32-unknown-elf-strip.exe"
    exit $?
    ;;
  riscv32-unknown-elf-size)
    run_binutils_tool \
      "$binutils_root/binutils/size.exe" \
      "$prefix/bin/riscv32-unknown-elf-size.exe"
    exit $?
    ;;
  riscv32-unknown-elf-readelf)
    run_binutils_tool \
      "$binutils_root/binutils/readelf.exe" \
      "$prefix/bin/riscv32-unknown-elf-readelf.exe"
    exit $?
    ;;
  *)
    unset GCC_EXEC_PREFIX COMPILER_PATH
    if [ -f "${prefix}/bin/${tool}.exe" ]; then
      run_wine_with_retries "${prefix}/bin/${tool}.exe" "${tool_args[@]}"
      exit $?
    fi
    ;;
esac

if [ -x "${prefix}/bin/${tool}" ]; then
  exec "${prefix}/bin/${tool}" "${tool_args[@]}"
fi

echo "wrapper: missing tool for ${tool}" >&2
exit 127
EOF
chmod +x /opt/wine-wrappers/riscv32-unknown-elf-wrapper

for t in gcc g++ cpp gcc-ar gcc-nm gcc-ranlib ar ranlib nm as ld strip objcopy objdump size readelf; do
  ln -sf /opt/wine-wrappers/riscv32-unknown-elf-wrapper "/opt/wine-wrappers/riscv32-unknown-elf-${t}"
done

export PATH=/opt/wine-wrappers:$PATH
export WINE_BIN=/usr/lib/wine/wine64
export WINEDEBUG=-all
export WINEPREFIX=${WINEPREFIX:-/tmp/wineprefix}
export WINE_CMD_RETRIES=${WINE_CMD_RETRIES:-4}
export WINE_CMD_RETRY_DELAY=${WINE_CMD_RETRY_DELAY:-1}

# Stabilize Wine temporary directory under heavy parallel builds.
mkdir -p /tmp/wine-tmp
mkdir -p "$WINEPREFIX"
export TMP=/tmp/wine-tmp
export TEMP=/tmp/wine-tmp
export TMPDIR=/tmp/wine-tmp

# Conservative defaults: keep stage1 fast, make final Wine-heavy phases stable.
JOBS_STAGE1=${JOBS_STAGE1:-$(nproc)}
JOBS_FINAL=${JOBS_FINAL:-8}
MAKE_RETRIES=${MAKE_RETRIES:-6}
MAKE_RETRY_DELAY=${MAKE_RETRY_DELAY:-8}
OUTPUT_TAR=${OUTPUT_TAR:-0}
# Pass through to riscv-gnu-toolchain Makefile newlib configure invocations.
NEWLIB_TARGET_FLAGS_EXTRA=${NEWLIB_TARGET_FLAGS_EXTRA:---disable-dependency-tracking}
export NEWLIB_TARGET_FLAGS_EXTRA
# Help gdb configure find host GMP/MPFR/MPC when cross-building for mingw host.
GDB_TARGET_FLAGS_EXTRA=${GDB_TARGET_FLAGS_EXTRA:---with-gmp-include=/src/build-gcc-newlib-stage2/gmp --with-gmp-lib=/src/build-gcc-newlib-stage2/gmp/.libs --with-mpfr-include=/src/gcc/mpfr/src --with-mpfr-lib=/src/build-gcc-newlib-stage2/mpfr/src/.libs --with-mpc-include=/src/gcc/mpc/src --with-mpc-lib=/src/build-gcc-newlib-stage2/mpc/src/.libs}
export GDB_TARGET_FLAGS_EXTRA

# Pre-initialize Wine once to avoid concurrent first-run initialization races.
if command -v wineboot >/dev/null 2>&1; then
  wineboot -u || true
fi

run_make_with_retries() {
  local jobs="$1"
  shift
  local rc=0
  local current_jobs="$jobs"
  local attempt
  for attempt in $(seq 1 "$MAKE_RETRIES"); do
    # Retry in the same tree can pick up stale malformed dep files from a prior
    # failed Wine run. Remove them before each attempt.
    find /src/build-gcc-newlib-stage2 -type f -name '*.dep' -delete 2>/dev/null || true
    if make -j"$current_jobs" CONFIGURE_HOST=--host=x86_64-w64-mingw32 "$@"; then
      return 0
    else
      rc=$?
    fi
    if [ "$attempt" -ge "$MAKE_RETRIES" ]; then
      return "$rc"
    fi
    if [ "$current_jobs" -gt 2 ]; then
      current_jobs=$(( (current_jobs + 1) / 2 ))
    fi
    echo "make failed (attempt ${attempt}/${MAKE_RETRIES}, rc=${rc}); retrying with -j${current_jobs} in ${MAKE_RETRY_DELAY}s..." >&2
    sleep "$MAKE_RETRY_DELAY"
  done
  return "$rc"
}

ensure_nano_libs_in_dir() {
  local dir="$1"

  [ -d "$dir" ] || return 0
  [ -f "$dir/nano.specs" ] || return 0

  if [ ! -f "$dir/libc_nano.a" ] && [ -f "$dir/libc.a" ]; then
    cp -f "$dir/libc.a" "$dir/libc_nano.a"
  fi
  if [ ! -f "$dir/libm_nano.a" ] && [ -f "$dir/libm.a" ]; then
    cp -f "$dir/libm.a" "$dir/libm_nano.a"
  fi
  if [ ! -f "$dir/libg_nano.a" ] && [ -f "$dir/libg.a" ]; then
    cp -f "$dir/libg.a" "$dir/libg_nano.a"
  fi
  if [ ! -f "$dir/libgloss_nano.a" ] && [ -f "$dir/libgloss.a" ]; then
    cp -f "$dir/libgloss.a" "$dir/libgloss_nano.a"
  fi

  if [ ! -f "$dir/libc_nano.a" ] || [ ! -f "$dir/libm_nano.a" ]; then
    echo "missing nano libs under $dir (need libc_nano.a and libm_nano.a)" >&2
    return 1
  fi
  if [ -f "$dir/libgloss.a" ] && [ ! -f "$dir/libgloss_nano.a" ]; then
    echo "missing libgloss_nano.a under $dir" >&2
    return 1
  fi
  return 0
}

ensure_nano_multilib_libs() {
  local libroot="/opt/riscv/riscv32-unknown-elf/lib"
  local ml mld dir rc=0

  ensure_nano_libs_in_dir "$libroot" || rc=1

  while IFS= read -r ml; do
    case "$ml" in
      *" "*) continue ;;
      "") continue ;;
    esac
    mld=${ml%%;*}
    if [ "$mld" = "." ]; then
      dir="$libroot"
    else
      dir="$libroot/$mld"
    fi
    ensure_nano_libs_in_dir "$dir" || rc=1
  done < <(riscv32-unknown-elf-gcc --print-multi-lib)

  return "$rc"
}

# Clone and build riscv-gnu-toolchain (mainline) with mirrors for blocked submodules.
if [ ! -d /src/.git ]; then
  git clone --depth=1 https://github.com/riscv-collab/riscv-gnu-toolchain /src
fi
cd /src

git config -f .gitmodules submodule.binutils.url https://gnu.googlesource.com/binutils-gdb
git config -f .gitmodules submodule.gdb.url https://gnu.googlesource.com/binutils-gdb
git config -f .gitmodules submodule.newlib.url https://github.com/RTEMS/sourceware-mirror-newlib-cygwin

git submodule sync -- binutils gdb newlib
git submodule update --init --depth=1 --jobs "$(nproc)" binutils gcc newlib gdb

cd /src/gcc
./contrib/download_prerequisites

# GCC's RISC-V libgcc config omits t-softfp-sfdf in the RISC-V target stanzas,
# so rv32imac/ilp32 builds miss single-precision soft-float helpers like
# __mulsf3 and __divsf3.
if ! grep -q 't-softfp-sfdf riscv/t-softfp${host_address} t-softfp riscv/t-elf' /src/gcc/libgcc/config.host; then
  sed -i 's#riscv/t-softfp${host_address} t-softfp riscv/t-elf#t-softfp-sfdf riscv/t-softfp${host_address} t-softfp riscv/t-elf#g' /src/gcc/libgcc/config.host
fi
grep -n 'riscv/t-softfp' /src/gcc/libgcc/config.host

cd /src
# Ensure mingw-host expat exists so gdb can link with --with-expat=yes.
if [ ! -f /usr/x86_64-w64-mingw32/lib/libexpat.a ]; then
  cd /tmp
  rm -rf expat-2.6.3 expat-2.6.3.tar.xz
  curl -fL --retry 5 --retry-delay 2 \
    -o expat-2.6.3.tar.xz \
    https://github.com/libexpat/libexpat/releases/download/R_2_6_3/expat-2.6.3.tar.xz
  tar -xf expat-2.6.3.tar.xz
  cd expat-2.6.3
  ./configure \
    --host=x86_64-w64-mingw32 \
    --prefix=/usr/x86_64-w64-mingw32 \
    --enable-static \
    --disable-shared
  make -j"${JOBS_STAGE1}"
  make install
  cd /src
fi

./configure \
  --prefix=/opt/riscv \
  --with-arch=rv32imac \
  --with-abi=ilp32 \
  --with-multilib-generator="rv32imac-ilp32--zicsr*zifencei*zaamo*zalrsc;rv32imafc-ilp32f--zicsr*zifencei*zaamo*zalrsc" \
  --enable-languages=c,c++ \
  --without-system-zlib

# Wine emits CRLF in some tool banner output; ensure thread model parsing
# in libstdc++ configure strips '\r' so gthr header selection stays valid.
sed -i "s#sed -n 's/^Thread model: //p'#sed -n 's/^Thread model: //p' | tr -d '\\\\r'#g" /src/gcc/libstdc++-v3/configure

# Build binutils + GCC stage1 first so we can patch stage1 launch behavior for Wine.
make -j"${JOBS_STAGE1}" CONFIGURE_HOST=--host=x86_64-w64-mingw32 \
  stamps/build-binutils-newlib \
  stamps/build-gcc-newlib-stage1

# stage1 emits Unix shell launchers (as/collect-ld/nm) that Windows-hosted xgcc
# cannot execute under Wine. Keep originals as .sh and provide .bat launchers.
stage1=/src/build-gcc-newlib-stage1/gcc
for t in as collect-ld nm; do
  if [ -f "${stage1}/${t}" ] && head -n1 "${stage1}/${t}" | grep -q '/bin/sh'; then
    mv "${stage1}/${t}" "${stage1}/${t}.sh"
  fi
done

# Ensure plain tool names resolve in binutils build dirs.
cp -f /src/build-binutils-newlib/gas/as-new.exe /src/build-binutils-newlib/gas/as.exe
cp -f /src/build-binutils-newlib/ld/ld-new.exe /src/build-binutils-newlib/ld/ld.exe
cp -f /src/build-binutils-newlib/binutils/nm-new.exe /src/build-binutils-newlib/binutils/nm.exe

# Force xgcc to search "as" via COMPILER_PATH/PATH instead of stage1 as.exe.
rm -f "${stage1}/as.exe"

cat > "${stage1}/as.bat" <<'EOF'
@echo off
Z:\src\build-binutils-newlib\gas\as.exe %*
EOF
cat > "${stage1}/collect-ld.bat" <<'EOF'
@echo off
Z:\src\build-binutils-newlib\ld\ld.exe %*
EOF
cat > "${stage1}/nm.bat" <<'EOF'
@echo off
Z:\src\build-binutils-newlib\binutils\nm.exe %*
EOF

# Force invoke_as to call the real binutils assembler path directly.
sed -i \
  's# as %(asm_options) %m.s %A # Z:/src/build-binutils-newlib/gas/as.exe %(asm_options) %m.s %A #' \
  "${stage1}/specs"

# Container restarts lose /opt contents while /src stamps persist. If sysroot
# headers vanished, libstdc++ configure later fails with "computing EOF failed".
# Try to restore newlib install from cached build dirs; if that fails, force
# a fresh newlib rebuild by invalidating stamps.
if [ ! -f /opt/riscv/riscv32-unknown-elf/include/newlib.h ]; then
  echo "sysroot headers missing under /opt; restoring newlib install..." >&2
  if [ -f /src/build-newlib/Makefile ]; then
    make -C /src/build-newlib install || true
  fi
  if [ -f /src/build-newlib-nano/Makefile ]; then
    make -C /src/build-newlib-nano install || true
  fi
  if [ -f /src/stamps/build-newlib ] && [ -f /src/stamps/build-newlib-nano ]; then
    make -C /src stamps/merge-newlib-nano || true
  fi
fi
if [ ! -f /opt/riscv/riscv32-unknown-elf/include/newlib.h ]; then
  echo "newlib headers still missing; forcing newlib rebuild..." >&2
  rm -f /src/stamps/build-newlib /src/stamps/build-newlib-nano /src/stamps/merge-newlib-nano
  rm -rf /src/build-newlib /src/build-newlib-nano
fi

# Ensure target lib directories expected by merge-newlib-nano exist.
mkdir -p /opt/riscv/riscv32-unknown-elf/lib
while IFS= read -r ml; do
  # Ignore noisy informational lines from Wine; multilib entries contain no spaces.
  case "$ml" in
    *" "*) continue ;;
    "") continue ;;
  esac
  mld=${ml%%;*}
  mkdir -p "/opt/riscv/riscv32-unknown-elf/lib/${mld}"
done < <(riscv32-unknown-elf-gcc --print-multi-lib)

# Some retries/restarts have observed missing gthr-default.h during stage2 libgcc.
# For bare-metal newlib targets the expected thread model is "single".
if [ ! -f /src/gcc/libgcc/gthr-default.h ]; then
  cp -f /src/gcc/libgcc/gthr-single.h /src/gcc/libgcc/gthr-default.h
fi

# Continue full build and install (retry for transient Wine/CreateProcess failures).
run_make_with_retries "${JOBS_FINAL}"

# Ensure toolchain components are installed into /opt before packaging.
make -C /src/build-gcc-newlib-stage2 install
make -C /src/build-binutils-newlib install
if [ -d /src/build-gdb-newlib ]; then
  make -C /src/build-gdb-newlib install
fi
# Keep top-level install as best-effort only; key pieces are already installed above.
make CONFIGURE_HOST=--host=x86_64-w64-mingw32 install || true

# Guarantee --specs=nano.specs can always resolve libc_nano/libm_nano for all
# installed multilib variants before packaging.
ensure_nano_multilib_libs

# Bundle mingw runtime DLLs required by gdb.exe on clean Windows hosts.
cp -f /usr/lib/gcc/x86_64-w64-mingw32/10-win32/libstdc++-6.dll /opt/riscv/bin/
cp -f /usr/lib/gcc/x86_64-w64-mingw32/10-win32/libgcc_s_seh-1.dll /opt/riscv/bin/

# Export install tree directly; tar is optional.
rm -rf /out/riscv
mkdir -p /out
cp -a /opt/riscv /out/riscv

if [ "${OUTPUT_TAR}" = "1" ]; then
  tar -C /opt -cf /out/riscv-rv32-win.tar riscv
fi
