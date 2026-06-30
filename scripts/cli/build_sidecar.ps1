# Build the standalone `grid.exe` CLI sidecar (Nuitka onefile) for Windows x64.
#
# Windows counterpart of scripts/cli/build_sidecar.sh. It compiles the grid CLI
# *source* (cloned separately) into one self-contained .exe so the app can ship `grid`
# without the user installing Python. Living here — not in the CLI repo — is the whole
# point: we own the Windows build without touching the CLI repo.
#
# Nuitka CANNOT cross-compile: run on Windows. Uses the MSVC toolchain present on the
# GitHub windows-latest runner (falls back to an auto-downloaded MinGW otherwise).
# Output: <cli-src>\dist\grid.exe — where package_windows.ps1 / release.yml inject from.
#
# Usage:
#   powershell -ExecutionPolicy Bypass -File scripts\cli\build_sidecar.ps1 -CliSrc ..\autonomous-grid
param(
    [string]$CliSrc = ""
)
$ErrorActionPreference = "Stop"

$Here    = $PSScriptRoot                                   # scripts\cli
$AppRoot = Split-Path -Parent (Split-Path -Parent $Here)  # grid-app repo root
$Entry   = Join-Path $Here "grid_entry.py"

# CLI source: -CliSrc wins; else the first sibling that looks like the CLI repo.
if (-not $CliSrc) {
    $siblings = Split-Path -Parent $AppRoot
    foreach ($name in @("autonomous-grid", "autonomous-grid-cli")) {
        $candidate = Join-Path $siblings $name
        if (Test-Path $candidate) { $CliSrc = $candidate; break }
    }
}
if (-not $CliSrc -or -not (Test-Path $CliSrc)) { throw "CLI source not found (pass -CliSrc <path>)" }
$CliSrc = (Resolve-Path $CliSrc).Path
if (-not (Test-Path (Join-Path $CliSrc "pyproject.toml"))) { throw "$CliSrc has no pyproject.toml - not the grid CLI source?" }

function Resolve-BuildPython {
    if ($env:GRID_BUILD_PYTHON) {
        $cmd = Get-Command $env:GRID_BUILD_PYTHON -ErrorAction SilentlyContinue
        if ($cmd) { return $cmd.Source }
        throw "GRID_BUILD_PYTHON set but not runnable: $($env:GRID_BUILD_PYTHON)"
    }
    # Prefer the `py` launcher (picks an exact version), then versioned names on PATH.
    foreach ($v in "3.11", "3.12", "3.13") {
        $out = & py "-$v" -c "import sys; print(sys.executable)" 2>$null
        if ($LASTEXITCODE -eq 0 -and $out) { return $out.Trim() }
    }
    foreach ($name in "python3.11", "python3.12", "python3.13", "python") {
        $cmd = Get-Command $name -ErrorAction SilentlyContinue
        if ($cmd) {
            $ver = & $cmd.Source -c "import sys; print('%d.%d' % sys.version_info[:2])" 2>$null
            if ($ver -match '^3\.(11|12|13)$') { return $cmd.Source }
        }
    }
    throw "Need Python 3.11/3.12/3.13 (install it, or use the 'py' launcher / GRID_BUILD_PYTHON)."
}

$BuildPy = Resolve-BuildPython
Write-Host ">>> Build Python: $BuildPy"

# Isolated build venv beside the CLI source. Rebuilt if its Python drifts off 3.11-3.13.
$BuildVenv = Join-Path $CliSrc ".venv-build"
$VenvPy    = Join-Path $BuildVenv "Scripts\python.exe"
if (Test-Path $VenvPy) {
    $vv = & $VenvPy -c "import sys; print('%d.%d' % sys.version_info[:2])" 2>$null
    if ($vv -notmatch '^3\.(11|12|13)$') { Write-Host ">>> Removing stale $BuildVenv"; Remove-Item -Recurse -Force $BuildVenv }
}
if (-not (Test-Path $VenvPy)) { Write-Host ">>> Creating build venv ($BuildPy)"; & $BuildPy -m venv $BuildVenv }

Write-Host ">>> Installing CLI source + Nuitka toolchain"
& $VenvPy -m pip install --upgrade pip | Out-Null
& $VenvPy -m pip install "$CliSrc" nuitka ordered-set zstandard
if ($LASTEXITCODE -ne 0) { throw "pip install failed" }

# Discover first-party packages from the CLI source (top-level dirs with __init__.py)
# so an upstream-added package is followed automatically; uvicorn is lazily imported.
$includes = @()
Get-ChildItem -Directory $CliSrc | ForEach-Object {
    if (Test-Path (Join-Path $_.FullName "__init__.py")) { $includes += "--include-package=$($_.Name)" }
}
if ($includes.Count -eq 0) { throw "no first-party packages found in $CliSrc" }
$includes += "--include-package=uvicorn"

$nuitkaArgs = @(
    "-m", "nuitka",
    "--standalone",
    "--onefile",
    "--deployment",
    "--output-dir=$CliSrc\dist",
    "--output-filename=grid",
    "--remove-output",
    "--assume-yes-for-downloads",
    "--company-name=LocalAGI",
    "--product-name=Grid CLI",
    "--product-version=0.1.0"
) + $includes + @(
    "--include-package-data=shared",
    "--include-package-data=certifi",
    "--onefile-tempdir-spec={CACHE_DIR}/localagi-grid/{VERSION}-windows",
    "$Entry"
)

Write-Host ">>> Compiling with Nuitka (standalone onefile, windows): $($includes -join ' ')"
Push-Location $CliSrc
try {
    & $VenvPy @nuitkaArgs
    if ($LASTEXITCODE -ne 0) { throw "Nuitka build failed (exit $LASTEXITCODE)" }
}
finally { Pop-Location }

Write-Host ""
Write-Host "Built: $CliSrc\dist\grid.exe"
