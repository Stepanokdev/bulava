# night-shift on Windows — the engine runs in WSL2; this hands each call to it.
#
# The engine is bash, tmux and git, and none of those exist natively on Windows, so it lives in a
# WSL2 distribution (install.ps1 put it there). What a person types in PowerShell, cmd or Windows
# Terminal reaches it through here: Windows paths become Linux ones, the current folder goes along,
# the exit code comes back. The `.cmd` files beside this are the entry points — a `.ps1` on PATH
# would be refused by the default execution policy, a `.cmd` never is.
#
#   NIGHT_SHIFT_WSL_DISTRO   which distribution (default: the one install.ps1 chose, else WSL's default)
#   NS_TOOL                  which engine command (set by the .cmd: night-shift, night-queue, …)

$ErrorActionPreference = 'Stop'
# The engine writes UTF-8 (Ukrainian, emoji); without this the console shows it as mojibake.
try { [Console]::OutputEncoding = [System.Text.Encoding]::UTF8 } catch { }
$env:WSL_UTF8 = '1'

$tool = if ($env:NS_TOOL) { $env:NS_TOOL } else { 'night-shift' }
if ($tool -notmatch '^[a-z][a-z-]*$') { Write-Error "night-shift: bad tool name '$tool'"; exit 2 }

$distro = $env:NIGHT_SHIFT_WSL_DISTRO
if (-not $distro) {
  $saved = Join-Path $PSScriptRoot 'distro.txt'
  if (Test-Path -LiteralPath $saved) { $distro = (Get-Content -LiteralPath $saved -Raw).Trim() }
}
$pick = @()
if ($distro) { $pick = @('-d', $distro) }

if (-not (Get-Command wsl.exe -ErrorAction SilentlyContinue)) {
  [Console]::Error.WriteLine('❌ WSL не знайдено. Постав його: irm https://bulava.app/install.ps1 | iex')
  exit 1
}

# A Windows path — C:\code\app, C:/code/app, \\server\share — becomes the path WSL sees it at.
# Both a bare argument and the value of a --flag=C:\path are converted; everything else is left
# exactly as typed.
function ConvertTo-WslPath([string]$p) {
  $out = & wsl.exe @pick -e wslpath -a -u $p 2>$null
  if ($LASTEXITCODE -eq 0 -and $out) { return ($out | Select-Object -First 1).Trim() }
  return $p
}
$winPath = '^(?:[A-Za-z]:[\\/]|\\\\)'
$converted = foreach ($a in $args) {
  $s = [string]$a
  if ($s -match $winPath) { ConvertTo-WslPath $s }
  elseif ($s -match '^(--[A-Za-z-]+=)(.+)$' -and $Matches[2] -match $winPath) { $Matches[1] + (ConvertTo-WslPath $Matches[2]) }
  else { $s }
}

# The folder this was typed in, so `night-shift start` with no folder means this one — as it does
# on macOS and Linux. A location that is not a folder on disk (a registry drive) starts at home.
$loc = Get-Location
$cd = if ($loc.Provider.Name -eq 'FileSystem') { $loc.ProviderPath } else { '~' }

# The entry script inside the distribution (wsl-entry.sh); install.ps1 wrote down where it is.
# Passed as a file to `bash -l`, never as `bash -c '…'`: see that script for why.
$entryFile = Join-Path $PSScriptRoot 'entry.txt'
if (-not (Test-Path -LiteralPath $entryFile)) {
  [Console]::Error.WriteLine('❌ night-shift встановлено не до кінця — запусти install.ps1 ще раз.')
  exit 1
}
$entry = (Get-Content -LiteralPath $entryFile -Raw).Trim()
& wsl.exe @pick --cd $cd -e bash -l $entry $tool @converted
exit $LASTEXITCODE
