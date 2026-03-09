# RISC-V Windows Toolchain Autobuild

This directory now contains a one-command flow for:

1. building the Docker image,
2. cloning/pulling `riscv-gnu-toolchain`,
3. building full Windows-hosted toolchain (`gcc/g++/binutils/gdb`),
4. exporting install directory,
5. building installer exe,
6. running local installer smoke test.

## Files

- `Dockerfile.builder`: build environment image (Ubuntu + mingw + wine)
- `build.sh`: full in-container build script (clone + compile + package)
- `run-full-build.ps1`: one-click Windows host build script (outputs `out/riscv`)
- `build-installer.ps1`: compile installer exe from `installer/ToolchainInstaller.cs`
- `test-installer.ps1`: run local installer test
- `run-local-release.ps1`: end-to-end local workflow (`build -> installer -> test`)

## Quick Start (PowerShell)

```powershell
cd C:\Users\a2592\tmp\riscv-gcc-win
powershell -ExecutionPolicy Bypass -File .\run-local-release.ps1
```

Output artifacts:

- install tree: `C:\Users\a2592\tmp\riscv-gcc-win\out\riscv`
- installer exe: `C:\Users\a2592\tmp\riscv-gcc-win\out\installer\riscv-toolchain-installer.exe`
- optional tar: `C:\Users\a2592\tmp\riscv-gcc-win\out\riscv-rv32-win.tar`

## Common Options

```powershell
# Force rebuild image from scratch
powershell -ExecutionPolicy Bypass -File .\run-local-release.ps1 -NoCache

# Skip image build, reuse existing image
powershell -ExecutionPolicy Bypass -File .\run-local-release.ps1 -SkipImageBuild

# Custom parallelism
powershell -ExecutionPolicy Bypass -File .\run-local-release.ps1 -JobsStage1 32 -JobsFinal 32

# Build toolchain output directory only (no installer stage)
powershell -ExecutionPolicy Bypass -File .\run-full-build.ps1

# Optional tar export in addition to output directory
powershell -ExecutionPolicy Bypass -File .\run-full-build.ps1 -CreateTar

# With proxy
powershell -ExecutionPolicy Bypass -File .\run-local-release.ps1 `
  -HttpProxy "http://172.27.64.1:7897" `
  -HttpsProxy "http://172.27.64.1:7897"
```

## Notes

- Build logs are written in this directory as `build-run-YYYYMMDD-HHMMSS.log`.
- `run-full-build.ps1` validates key files in `out/riscv` and fails fast if any are missing.
- The configured baseline target is `rv32imac/ilp32`, with an additional `rv32imafc/ilp32f` multilib.
- Installer smoke tests cover `rv32imac/ilp32` soft-float helper linking to catch missing `__mulsf3`/`__divsf3`-class regressions.
