[CmdletBinding()]
param(
  [string]$WorkDir = "",
  [string]$SourceDir = "",
  [string]$TarPath = "",
  [string]$InstallerExe = "",
  [string]$InstallDir = "",
  [switch]$RebuildInstaller
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function Ensure-SourceDir {
  param(
    [string]$DirPath,
    [string]$TarFile
  )
  if (Test-Path (Join-Path $DirPath "bin\\riscv32-unknown-elf-gcc.exe")) {
    return
  }

  if (-not (Test-Path $TarFile)) {
    throw "Missing source directory and tar archive. Need one of: $DirPath or $TarFile"
  }

  Write-Host "==> Source directory missing, extracting from tar..."
  if (Test-Path $DirPath) {
    Remove-Item -Recurse -Force $DirPath
  }
  New-Item -ItemType Directory -Force -Path (Split-Path -Parent $DirPath) | Out-Null

  $parent = Split-Path -Parent $DirPath
  & tar -xf $TarFile -C $parent
  if ($LASTEXITCODE -ne 0) {
    throw "tar extract failed for $TarFile"
  }
}

if ([string]::IsNullOrWhiteSpace($WorkDir)) {
  $WorkDir = Split-Path -Parent $MyInvocation.MyCommand.Path
}
$WorkDir = (Resolve-Path $WorkDir).Path

if ([string]::IsNullOrWhiteSpace($SourceDir)) {
  $SourceDir = Join-Path $WorkDir "out\\riscv"
}
if ([string]::IsNullOrWhiteSpace($TarPath)) {
  $TarPath = Join-Path $WorkDir "out\\riscv-rv32-win.tar"
}
if ([string]::IsNullOrWhiteSpace($InstallerExe)) {
  $InstallerExe = Join-Path $WorkDir "out\\installer\\riscv-toolchain-installer.exe"
}
if ([string]::IsNullOrWhiteSpace($InstallDir)) {
  $InstallDir = Join-Path $WorkDir "out\\install-test"
}

$SourceDir = [System.IO.Path]::GetFullPath($SourceDir)
$TarPath = [System.IO.Path]::GetFullPath($TarPath)
$InstallerExe = [System.IO.Path]::GetFullPath($InstallerExe)
$InstallDir = [System.IO.Path]::GetFullPath($InstallDir)

Ensure-SourceDir -DirPath $SourceDir -TarFile $TarPath

if ($RebuildInstaller -or -not (Test-Path $InstallerExe)) {
  Write-Host "==> Building installer..."
  & powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $WorkDir "build-installer.ps1")
  if ($LASTEXITCODE -ne 0) {
    throw "build-installer.ps1 failed with exit code $LASTEXITCODE"
  }
}

if (-not (Test-Path $InstallerExe)) {
  throw "Installer exe not found: $InstallerExe"
}

if (Test-Path $InstallDir) {
  Remove-Item -Recurse -Force $InstallDir
}

Write-Host "==> Running installer smoke test..."
& $InstallerExe --silent --source $SourceDir --target $InstallDir --no-path
if ($LASTEXITCODE -ne 0) {
  throw "Installer execution failed with exit code $LASTEXITCODE"
}

$required = @(
  (Join-Path $InstallDir "bin\\riscv32-unknown-elf-gcc.exe"),
  (Join-Path $InstallDir "bin\\riscv32-unknown-elf-g++.exe"),
  (Join-Path $InstallDir "bin\\riscv32-unknown-elf-gdb.exe"),
  (Join-Path $InstallDir "bin\\riscv32-unknown-elf-readelf.exe"),
  (Join-Path $InstallDir "bin\\libstdc++-6.dll"),
  (Join-Path $InstallDir "bin\\libgcc_s_seh-1.dll"),
  (Join-Path $InstallDir "libexec\\gcc\\riscv32-unknown-elf\\15.2.0\\cc1.exe"),
  (Join-Path $InstallDir "libexec\\gcc\\riscv32-unknown-elf\\15.2.0\\cc1plus.exe"),
  (Join-Path $InstallDir "riscv32-unknown-elf\\include\\stdio.h"),
  (Join-Path $InstallDir "riscv32-unknown-elf\\lib\\libstdc++.a"),
  (Join-Path $InstallDir "riscv32-unknown-elf\\lib\\libc_nano.a"),
  (Join-Path $InstallDir "riscv32-unknown-elf\\lib\\libm_nano.a"),
  (Join-Path $InstallDir "riscv32-unknown-elf\\lib\\libgloss_nano.a"),
  (Join-Path $InstallDir "riscv32-unknown-elf\\lib\\rv32imafc_zicsr_zaamo_zalrsc\\ilp32f\\libc_nano.a"),
  (Join-Path $InstallDir "riscv32-unknown-elf\\lib\\rv32imafc_zicsr_zaamo_zalrsc\\ilp32f\\libm_nano.a"),
  (Join-Path $InstallDir "riscv32-unknown-elf\\lib\\rv32imafc_zicsr_zaamo_zalrsc\\ilp32f\\libgloss_nano.a")
)

Write-Host "==> Verifying installed files..."
foreach ($file in $required) {
  if (-not (Test-Path $file)) {
    throw "Missing installed file: $file"
  }
  Write-Host "    OK  $file"
}

Write-Host "==> Running command checks..."
& (Join-Path $InstallDir "bin\\riscv32-unknown-elf-gcc.exe") --version | Select-Object -First 1
if ($LASTEXITCODE -ne 0) {
  throw "gcc --version failed"
}
& (Join-Path $InstallDir "bin\\riscv32-unknown-elf-gdb.exe") --version | Select-Object -First 1
if ($LASTEXITCODE -ne 0) {
  throw "gdb --version failed"
}

$helloC = Join-Path $InstallDir "hello.c"
$helloElf = Join-Path $InstallDir "hello.elf"
Set-Content -Path $helloC -Value "int main(void){return 0;}" -NoNewline

& (Join-Path $InstallDir "bin\\riscv32-unknown-elf-gcc.exe") -march=rv32imac -mabi=ilp32 -Os $helloC -o $helloElf
if ($LASTEXITCODE -ne 0) {
  throw "gcc hello build failed"
}

$helloCpp = Join-Path $InstallDir "hello.cpp"
$helloCppElf = Join-Path $InstallDir "hello-cpp.elf"
Set-Content -Path $helloCpp -Value "int main(){return 0;}" -NoNewline -Encoding Ascii

& (Join-Path $InstallDir "bin\\riscv32-unknown-elf-g++.exe") -march=rv32imac -mabi=ilp32 -Os $helloCpp -o $helloCppElf
if ($LASTEXITCODE -ne 0) {
  throw "g++ hello build failed"
}

$softFloatC = Join-Path $InstallDir "softfloat.c"
$softFloatElf = Join-Path $InstallDir "softfloat-imac.elf"
$softFloatSource = @'
volatile float a = 3.5f;
volatile float b = 1.25f;
volatile int si = -7;
volatile unsigned int ui = 9u;

float fm(void) { return a * b; }
float fd(void) { return a / b; }
float fi(void) { return (float)si; }
float fu(void) { return (float)ui; }

int main(void) { return (int)(fm() + fd() + fi() + fu()); }
'@
Set-Content -Path $softFloatC -Value $softFloatSource -Encoding Ascii

& (Join-Path $InstallDir "bin\\riscv32-unknown-elf-gcc.exe") -march=rv32imac -mabi=ilp32 -Os $softFloatC -o $softFloatElf
if ($LASTEXITCODE -ne 0) {
  throw "gcc soft-float helper build failed for rv32imac/ilp32"
}

$helloNanoImacElf = Join-Path $InstallDir "hello-nano-imac.elf"
& (Join-Path $InstallDir "bin\\riscv32-unknown-elf-gcc.exe") -march=rv32imac -mabi=ilp32 --specs=nano.specs -Os $helloC -o $helloNanoImacElf
if ($LASTEXITCODE -ne 0) {
  throw "gcc nano hello build failed for rv32imac/ilp32"
}

$helloNanoImafcElf = Join-Path $InstallDir "hello-nano-imafc.elf"
& (Join-Path $InstallDir "bin\\riscv32-unknown-elf-gcc.exe") -march=rv32imafc -mabi=ilp32f --specs=nano.specs -Os $helloC -o $helloNanoImafcElf
if ($LASTEXITCODE -ne 0) {
  throw "gcc nano hello build failed for rv32imafc/ilp32f"
}

$helloCppNanoElf = Join-Path $InstallDir "hello-cpp-nano.elf"
& (Join-Path $InstallDir "bin\\riscv32-unknown-elf-g++.exe") -march=rv32imac -mabi=ilp32 --specs=nano.specs -Os $helloCpp -o $helloCppNanoElf
if ($LASTEXITCODE -ne 0) {
  throw "g++ nano hello build failed"
}

$elfHeader = & (Join-Path $InstallDir "bin\\riscv32-unknown-elf-readelf.exe") -h $helloElf
if ($LASTEXITCODE -ne 0) {
  throw "readelf failed"
}
$classLine = $elfHeader | Select-String -SimpleMatch "Class:"
$machineLine = $elfHeader | Select-String -SimpleMatch "Machine:"

Write-Host "    $($classLine.Line)"
Write-Host "    $($machineLine.Line)"

Write-Host "==> Installer test passed"
Write-Host "    InstallDir: $InstallDir"
