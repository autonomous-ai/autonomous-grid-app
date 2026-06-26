# Package the built Windows app into a distributable .zip, with the `grid.exe`
# sidecar injected next to grid_app.exe - exactly where GridResolver looks
# (`<exeDir>/grid.exe`, see lib/infrastructure/cli/grid_resolver.dart).
#
# Run AFTER `flutter build windows --release` (produces the Release folder) and
# after the CLI repo's build_windows.ps1 (produces grid.exe).
#
#   powershell -ExecutionPolicy Bypass -File scripts\package_windows.ps1 `
#       -Sidecar ..\autonomous-grid-cli\dist\grid.exe `
#       -OutZip  dist\Grid-0.1.2-Windows-x64.zip
param(
    [Parameter(Mandatory = $true)][string]$Sidecar,
    [Parameter(Mandatory = $true)][string]$OutZip
)
$ErrorActionPreference = "Stop"

$RepoRoot   = Split-Path -Parent $PSScriptRoot
$ReleaseDir = Join-Path $RepoRoot "build\windows\x64\runner\Release"

if (-not (Test-Path $ReleaseDir)) {
    throw "Windows Release build not found at $ReleaseDir - run 'flutter build windows --release' first."
}
if (-not (Test-Path $Sidecar)) {
    throw "Sidecar not found: $Sidecar - build it with the CLI repo's build_windows.ps1 first."
}

Write-Host ">>> Injecting grid.exe sidecar into $ReleaseDir"
Copy-Item $Sidecar (Join-Path $ReleaseDir "grid.exe") -Force

# Ship the whole Release folder (the .exe needs its sibling DLLs + data/ to run).
$OutDir = Split-Path -Parent $OutZip
if ($OutDir -and -not (Test-Path $OutDir)) { New-Item -ItemType Directory -Force -Path $OutDir | Out-Null }
if (Test-Path $OutZip) { Remove-Item $OutZip -Force }

Write-Host ">>> Zipping Release folder -> $OutZip"
Compress-Archive -Path (Join-Path $ReleaseDir "*") -DestinationPath $OutZip

Write-Host "Built: $OutZip"
