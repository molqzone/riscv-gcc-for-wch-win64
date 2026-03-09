[CmdletBinding()]
param(
  [string]$WorkDir = "",
  [string]$SevenZipExe = "",
  [string]$SfxModule = "",
  [int]$CompressionLevel = 9,
  [switch]$ConfigAfterArchive
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function Resolve-FirstExistingPath {
  param(
    [string[]]$Candidates,
    [string]$What
  )

  foreach ($candidate in $Candidates) {
    if (-not [string]::IsNullOrWhiteSpace($candidate) -and (Test-Path $candidate)) {
      return (Resolve-Path $candidate).Path
    }
  }
  throw "Missing $What. Checked: $($Candidates -join ', ')"
}

if ([string]::IsNullOrWhiteSpace($WorkDir)) {
  $WorkDir = Split-Path -Parent $MyInvocation.MyCommand.Path
}
$WorkDir = (Resolve-Path $WorkDir).Path

$sevenZipCandidates = @(
  $SevenZipExe,
  (Join-Path $env:ProgramFiles "7-Zip\\7z.exe"),
  (Join-Path $WorkDir "tools\\7zip\\7z2600-x64\\7z.exe")
)
$sfxCandidates = @(
  $SfxModule,
  (Join-Path $env:ProgramFiles "7-Zip\\7z.sfx"),
  (Join-Path $WorkDir "tools\\7zip\\7z2600-x64\\7z.sfx")
)

$sevenZipExePath = Resolve-FirstExistingPath -Candidates $sevenZipCandidates -What "7z executable"
$sfxModulePath = Resolve-FirstExistingPath -Candidates $sfxCandidates -What "7z SFX module"

$sourceDir = Join-Path $WorkDir "out\\riscv"
$installerExe = Join-Path $WorkDir "out\\installer\\riscv-toolchain-installer.exe"
if (-not (Test-Path (Join-Path $sourceDir "bin\\riscv32-unknown-elf-gcc.exe"))) {
  throw "Missing toolchain source dir: $sourceDir"
}
if (-not (Test-Path $installerExe)) {
  throw "Missing installer exe: $installerExe"
}

$bundleDir = Join-Path $WorkDir "out\\bundle"
$releaseDir = Join-Path $WorkDir "out\\release"
$archivePath = Join-Path $bundleDir "payload.7z"
$fullExePath = Join-Path $releaseDir "riscv-toolchain-full-installer.exe"
$extractDir = Join-Path $WorkDir "out\\full-extract-test"
$installDir = Join-Path $WorkDir "out\\full-install-test"

New-Item -ItemType Directory -Force -Path $bundleDir | Out-Null
New-Item -ItemType Directory -Force -Path $releaseDir | Out-Null

$installCmd = Join-Path $bundleDir "install.cmd"
@'
@echo off
setlocal
for %%I in ("%~dp0..") do set "ROOT=%%~fI\"
"%ROOT%installer\riscv-toolchain-installer.exe" --source "%ROOT%riscv" %*
exit /b %ERRORLEVEL%
'@ | Set-Content -Path $installCmd -Encoding Ascii

$sfxConfigPath = Join-Path $bundleDir "sfx-config.txt"
$cfgLines = @(
  ';!@Install@!UTF-8!',
  'Title="RISC-V Toolchain Installer"',
  'GUIMode="2"',
  'RunProgram="cmd /c %%T\\bundle\\install.cmd"',
  ';!@InstallEnd@!'
)
Set-Content -Path $sfxConfigPath -Encoding Ascii -Value $cfgLines

if (Test-Path $archivePath) {
  Remove-Item -Force $archivePath
}

Write-Host "==> Building payload archive"
Push-Location (Join-Path $WorkDir "out")
& $sevenZipExePath a -t7z "-mx=$CompressionLevel" -ms=off -snh- $archivePath 'riscv\*' 'installer\riscv-toolchain-installer.exe' 'bundle\install.cmd'
$archiveRc = $LASTEXITCODE
Pop-Location
if ($archiveRc -ne 0) {
  throw "7z archive failed with exit code: $archiveRc"
}

if (Test-Path $fullExePath) {
  Remove-Item -Force $fullExePath
}

Write-Host "==> Building full SFX installer"
$parts = if ($ConfigAfterArchive) {
  @($sfxModulePath, $archivePath, $sfxConfigPath)
} else {
  @($sfxModulePath, $sfxConfigPath, $archivePath)
}
$outStream = [System.IO.File]::Open($fullExePath, [System.IO.FileMode]::CreateNew, [System.IO.FileAccess]::Write, [System.IO.FileShare]::None)
try {
  foreach ($part in $parts) {
    $inStream = [System.IO.File]::Open($part, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::Read)
    try {
      $inStream.CopyTo($outStream)
    } finally {
      $inStream.Dispose()
    }
  }
} finally {
  $outStream.Dispose()
}

if (-not (Test-Path $fullExePath)) {
  throw "Missing full installer output: $fullExePath"
}

if (Test-Path $installDir) {
  Remove-Item -Recurse -Force $installDir
}
if (Test-Path $extractDir) {
  Remove-Item -Recurse -Force $extractDir
}

Write-Host "==> Running full installer smoke test"
& $fullExePath -y "-o$extractDir"
if ($LASTEXITCODE -ne 0) {
  throw "Full installer extraction failed with exit code: $LASTEXITCODE"
}

$extractedInstaller = Join-Path $extractDir "installer\\riscv-toolchain-installer.exe"
$extractedSource = Join-Path $extractDir "riscv"
$requiredInExtract = @(
  (Join-Path $extractedSource "bin\\riscv32-unknown-elf-gcc.exe"),
  (Join-Path $extractedSource "bin\\riscv32-unknown-elf-g++.exe"),
  (Join-Path $extractedSource "bin\\riscv32-unknown-elf-gdb.exe"),
  (Join-Path $extractedSource "bin\\riscv32-unknown-elf-readelf.exe"),
  (Join-Path $extractedSource "bin\\libstdc++-6.dll"),
  (Join-Path $extractedSource "bin\\libgcc_s_seh-1.dll"),
  (Join-Path $extractedSource "libexec\\gcc\\riscv32-unknown-elf\\15.2.0\\cc1.exe"),
  (Join-Path $extractedSource "libexec\\gcc\\riscv32-unknown-elf\\15.2.0\\cc1plus.exe"),
  (Join-Path $extractedSource "riscv32-unknown-elf\\include\\stdio.h"),
  (Join-Path $extractedSource "riscv32-unknown-elf\\lib\\libstdc++.a"),
  (Join-Path $extractedSource "riscv32-unknown-elf\\lib\\libc_nano.a"),
  (Join-Path $extractedSource "riscv32-unknown-elf\\lib\\libm_nano.a"),
  (Join-Path $extractedSource "riscv32-unknown-elf\\lib\\libgloss_nano.a"),
  (Join-Path $extractedSource "riscv32-unknown-elf\\lib\\rv32imafc_zicsr_zaamo_zalrsc\\ilp32f\\libc_nano.a"),
  (Join-Path $extractedSource "riscv32-unknown-elf\\lib\\rv32imafc_zicsr_zaamo_zalrsc\\ilp32f\\libm_nano.a"),
  (Join-Path $extractedSource "riscv32-unknown-elf\\lib\\rv32imafc_zicsr_zaamo_zalrsc\\ilp32f\\libgloss_nano.a")
)
$waitSeconds = 300
for ($i = 0; $i -lt $waitSeconds; $i++) {
  $ready = (Test-Path $extractedInstaller)
  if ($ready) {
    foreach ($path in $requiredInExtract) {
      if (-not (Test-Path $path)) {
        $ready = $false
        break
      }
    }
  }
  if ($ready) {
    break
  }
  Start-Sleep -Seconds 1
}
if (-not (Test-Path $extractedInstaller)) {
  throw "Extracted installer missing: $extractedInstaller"
}
foreach ($path in $requiredInExtract) {
  if (-not (Test-Path $path)) {
    throw "Extracted toolchain missing file: $path"
  }
}

& $extractedInstaller --silent --source $extractedSource --target $installDir --no-path
if ($LASTEXITCODE -ne 0) {
  throw "Extracted installer execution failed with exit code: $LASTEXITCODE"
}

$gccInInstall = Join-Path $installDir "bin\\riscv32-unknown-elf-gcc.exe"
$waitSeconds = 180
for ($i = 0; $i -lt $waitSeconds; $i++) {
  if (Test-Path $gccInInstall) {
    break
  }
  Start-Sleep -Seconds 1
}

$required = @(
  $gccInInstall,
  (Join-Path $installDir "bin\\riscv32-unknown-elf-g++.exe"),
  (Join-Path $installDir "bin\\riscv32-unknown-elf-gdb.exe"),
  (Join-Path $installDir "bin\\riscv32-unknown-elf-readelf.exe"),
  (Join-Path $installDir "bin\\libstdc++-6.dll"),
  (Join-Path $installDir "bin\\libgcc_s_seh-1.dll"),
  (Join-Path $installDir "libexec\\gcc\\riscv32-unknown-elf\\15.2.0\\cc1.exe"),
  (Join-Path $installDir "libexec\\gcc\\riscv32-unknown-elf\\15.2.0\\cc1plus.exe"),
  (Join-Path $installDir "riscv32-unknown-elf\\include\\stdio.h"),
  (Join-Path $installDir "riscv32-unknown-elf\\lib\\libstdc++.a"),
  (Join-Path $installDir "riscv32-unknown-elf\\lib\\libc_nano.a"),
  (Join-Path $installDir "riscv32-unknown-elf\\lib\\libm_nano.a"),
  (Join-Path $installDir "riscv32-unknown-elf\\lib\\libgloss_nano.a"),
  (Join-Path $installDir "riscv32-unknown-elf\\lib\\rv32imafc_zicsr_zaamo_zalrsc\\ilp32f\\libc_nano.a"),
  (Join-Path $installDir "riscv32-unknown-elf\\lib\\rv32imafc_zicsr_zaamo_zalrsc\\ilp32f\\libm_nano.a"),
  (Join-Path $installDir "riscv32-unknown-elf\\lib\\rv32imafc_zicsr_zaamo_zalrsc\\ilp32f\\libgloss_nano.a")
)
foreach ($path in $required) {
  if (-not (Test-Path $path)) {
    throw "Missing installed file: $path"
  }
}

Write-Host "==> Running command checks"
& (Join-Path $installDir "bin\\riscv32-unknown-elf-gcc.exe") --version | Select-Object -First 1
if ($LASTEXITCODE -ne 0) {
  throw "gcc --version failed"
}
& (Join-Path $installDir "bin\\riscv32-unknown-elf-gdb.exe") --version | Select-Object -First 1
if ($LASTEXITCODE -ne 0) {
  throw "gdb --version failed"
}

$helloC = Join-Path $installDir "hello-full.c"
$helloElf = Join-Path $installDir "hello-full.elf"
Set-Content -Path $helloC -Value "int main(void){return 0;}" -NoNewline -Encoding Ascii

& (Join-Path $installDir "bin\\riscv32-unknown-elf-gcc.exe") -march=rv32imac -mabi=ilp32 -Os $helloC -o $helloElf
if ($LASTEXITCODE -ne 0) {
  throw "hello compile failed"
}

$helloCpp = Join-Path $installDir "hello-full.cpp"
$helloCppElf = Join-Path $installDir "hello-full-cpp.elf"
Set-Content -Path $helloCpp -Value "int main(){return 0;}" -NoNewline -Encoding Ascii

& (Join-Path $installDir "bin\\riscv32-unknown-elf-g++.exe") -march=rv32imac -mabi=ilp32 -Os $helloCpp -o $helloCppElf
if ($LASTEXITCODE -ne 0) {
  throw "hello c++ compile failed"
}

$softFloatC = Join-Path $installDir "softfloat-full.c"
$softFloatElf = Join-Path $installDir "softfloat-full-imac.elf"
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

& (Join-Path $installDir "bin\\riscv32-unknown-elf-gcc.exe") -march=rv32imac -mabi=ilp32 -Os $softFloatC -o $softFloatElf
if ($LASTEXITCODE -ne 0) {
  throw "soft-float helper compile failed for rv32imac/ilp32"
}

$helloNanoImacElf = Join-Path $installDir "hello-full-nano-imac.elf"
& (Join-Path $installDir "bin\\riscv32-unknown-elf-gcc.exe") -march=rv32imac -mabi=ilp32 --specs=nano.specs -Os $helloC -o $helloNanoImacElf
if ($LASTEXITCODE -ne 0) {
  throw "hello nano compile failed for rv32imac/ilp32"
}

$helloNanoImafcElf = Join-Path $installDir "hello-full-nano-imafc.elf"
& (Join-Path $installDir "bin\\riscv32-unknown-elf-gcc.exe") -march=rv32imafc -mabi=ilp32f --specs=nano.specs -Os $helloC -o $helloNanoImafcElf
if ($LASTEXITCODE -ne 0) {
  throw "hello nano compile failed for rv32imafc/ilp32f"
}

$helloCppNanoElf = Join-Path $installDir "hello-full-cpp-nano.elf"
& (Join-Path $installDir "bin\\riscv32-unknown-elf-g++.exe") -march=rv32imac -mabi=ilp32 --specs=nano.specs -Os $helloCpp -o $helloCppNanoElf
if ($LASTEXITCODE -ne 0) {
  throw "hello c++ nano compile failed"
}

$elfHeader = & (Join-Path $installDir "bin\\riscv32-unknown-elf-readelf.exe") -h $helloElf
if ($LASTEXITCODE -ne 0) {
  throw "readelf failed"
}

$classLine = $elfHeader | Select-String -SimpleMatch "Class:"
$machineLine = $elfHeader | Select-String -SimpleMatch "Machine:"
if (-not $classLine) {
  throw "readelf output missing Class line"
}
if (-not $machineLine) {
  throw "readelf output missing Machine line"
}

$fullInfo = Get-Item $fullExePath
Write-Host "==> Full installer smoke test passed"
Write-Host "    FullExe: $($fullInfo.FullName)"
Write-Host "    FullExeSize: $($fullInfo.Length)"
Write-Host "    InstallDir: $installDir"
Write-Host "    $($classLine.Line)"
Write-Host "    $($machineLine.Line)"
