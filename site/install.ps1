# night-shift for Windows — the engine behind Bulava, run inside WSL2.
#
#   irm https://bulava.app/install.ps1 | iex
#
# What this does, in full:
#
#   1. checks that WSL2 is there and picks a distribution (NIGHT_SHIFT_WSL_DISTRO, else the default);
#   2. offers to install the Linux packages the engine needs (git, tmux, jq, python3…) through the
#      distribution's apt, as root inside WSL — only after you say yes;
#   3. runs the ordinary Linux installer (https://bulava.app/install.sh) inside that distribution;
#   4. puts `night-shift`, `night-queue` and `deep-audit` commands for cmd, PowerShell and Windows
#      Terminal into %LOCALAPPDATA%\night-shift\bin and adds that folder to your user PATH.
#
# Claude Code and Codex have to be installed and signed in INSIDE the distribution, because that is
# where the engine runs them. `night-shift doctor` says what is missing.
#
# To take it back out:   & ([scriptblock]::Create((irm https://bulava.app/install.ps1))) -Uninstall

param(
  [switch]$Uninstall,
  [switch]$Yes,
  [string]$Distro = $env:NIGHT_SHIFT_WSL_DISTRO,
  [string]$InstallUrl = $(if ($env:NIGHT_SHIFT_INSTALL_URL) { $env:NIGHT_SHIFT_INSTALL_URL } else { 'https://bulava.app/install.sh' })
)

$ErrorActionPreference = 'Stop'
try { [Console]::OutputEncoding = [System.Text.Encoding]::UTF8 } catch { }
# wsl.exe prints its own messages in UTF-16 unless told otherwise.
$env:WSL_UTF8 = '1'

$BinDir = Join-Path $env:LOCALAPPDATA 'night-shift\bin'

function Say([string]$m)  { Write-Host ''; Write-Host $m -ForegroundColor Cyan }
function Note([string]$m) { Write-Host "  $m" }
function Die([string]$m)  { Write-Host ''; Write-Host "❌ $m" -ForegroundColor Red; exit 1 }

function Set-UserPath([string]$dir, [bool]$add) {
  $cur = [Environment]::GetEnvironmentVariable('Path', 'User')
  $parts = @()
  if ($cur) { $parts = $cur -split ';' | Where-Object { $_ -and ($_.TrimEnd('\') -ne $dir.TrimEnd('\')) } }
  if ($add) { $parts += $dir }
  [Environment]::SetEnvironmentVariable('Path', ($parts -join ';'), 'User')
}

if ($Uninstall) {
  Say 'прибираю night-shift з Windows'
  if (Test-Path -LiteralPath $BinDir) { Remove-Item -LiteralPath (Split-Path $BinDir) -Recurse -Force }
  Set-UserPath $BinDir $false
  Note 'команди й запис у PATH прибрано.'
  Note 'Сам движок лишився у WSL — прибрати його: wsl night-shift uninstall  (стан прогонів не чіпається)'
  exit 0
}

if ($env:OS -ne 'Windows_NT') { Die 'це інсталятор для Windows. На macOS і Linux: curl -fsSL https://bulava.app/install.sh | bash' }

# ---------------------------------------------------------------- WSL itself
Say 'дивлюсь на WSL'
if (-not (Get-Command wsl.exe -ErrorAction SilentlyContinue)) {
  Die "WSL не встановлено. У PowerShell від імені адміністратора:`n     wsl --install -d Ubuntu`n   перезавантаж комп'ютер, відкрий Ubuntu один раз (вона попросить ім'я й пароль), тоді запусти цей інсталятор знову."
}

# Older WSL builds ignore WSL_UTF8 and answer in UTF-16, which arrives here with a NUL between letters.
$list = ((& wsl.exe -l -v 2>$null) -join "`n") -replace "`0", ''

if ($LASTEXITCODE -ne 0 -or -not ($list -match '\S')) {
  Die "у WSL ще немає жодного Linux. Постав:  wsl --install -d Ubuntu  — відкрий його один раз, тоді повтори."
}

# `wsl -l -v`: NAME STATE VERSION, the default marked with *.
$rows = @()
foreach ($line in ($list -split "`n" | Select-Object -Skip 1)) {
  $l = $line.Trim()
  if (-not $l) { continue }
  $isDefault = $l.StartsWith('*')
  $cols = ($l.TrimStart('*').Trim()) -split '\s+'
  if ($cols.Count -ge 3) { $rows += [pscustomobject]@{ Name = $cols[0]; Version = $cols[-1]; Default = $isDefault } }
}
# Docker Desktop's own distributions are not a place to work.
$usable = $rows | Where-Object { $_.Name -notmatch '^docker-desktop' }
if (-not $Distro) {
  $d = $usable | Where-Object Default | Select-Object -First 1
  if (-not $d) { $d = $usable | Select-Object -First 1 }
  if (-not $d) { Die "у WSL немає Linux-дистрибутива, придатного для роботи. Постав:  wsl --install -d Ubuntu" }
  $Distro = $d.Name
}
$chosen = $rows | Where-Object { $_.Name -eq $Distro } | Select-Object -First 1
if (-not $chosen) { Die "дистрибутива '$Distro' немає. Є: $(($rows | ForEach-Object Name) -join ', ')" }
if ($chosen.Version -ne '2') {
  Die "'$Distro' працює як WSL1 — tmux і git там ненадійні. Онови:  wsl --set-version $Distro 2"
}
Note "дистрибутив: $Distro (WSL2)"
$pick = @('-d', $Distro)

# ---------------------------------------------------------------- Linux packages
Say 'дивлюсь, чого бракує в Linux'
$missing = (& wsl.exe @pick -e sh -c 'for t in curl tar git python3 jq tmux file; do command -v $t >/dev/null 2>&1 || printf "%s " $t; done' 2>$null)
$missing = "$missing".Trim()
if ($missing) {
  Note "бракує: $missing"
  $hasApt = (& wsl.exe @pick -e sh -c 'command -v apt-get >/dev/null 2>&1 && echo yes' 2>$null) -eq 'yes'
  if ($hasApt) {
    $answer = if ($Yes) { 'y' } else { Read-Host "  Поставити через apt-get (від root усередині WSL)? [Y/n]" }
    if ($answer -eq '' -or $answer -match '^[YyТт]') {
      & wsl.exe @pick -u root -e sh -c "apt-get update -qq && DEBIAN_FRONTEND=noninteractive apt-get install -y -qq $missing procps ca-certificates"
      if ($LASTEXITCODE -ne 0) { Die "apt-get не впорався — подивись вивід вище." }
    } else {
      Die "без цього движок не встановиться. Постав у WSL:  sudo apt-get install -y $missing"
    }
  } else {
    Die "постав у '$Distro' через його пакетний менеджер: $missing — і повтори."
  }
} else {
  Note 'curl, tar, git, python3, jq, tmux — на місці'
}

# ---------------------------------------------------------------- the engine, inside WSL
Say 'встановлюю движок у WSL'
& wsl.exe @pick -e bash -lc "curl -fsSL '$InstallUrl' | bash"
if ($LASTEXITCODE -ne 0) { Die 'установник усередині WSL не завершився — дивись, що він сказав вище.' }

# Where the engine landed, from its own command link — the Windows commands are copied from it, so
# they always match the engine they talk to.
$root = (& wsl.exe @pick -e sh -c 'd=$(readlink -f "$HOME/.local/bin/night-shift") && cd "$(dirname "$d")/.." && pwd' 2>$null)
$root = "$root".Trim()
if (-not $root) { Die 'не знайшов встановлений движок у WSL (~/.local/bin/night-shift).' }

# ---------------------------------------------------------------- Windows commands
Say 'додаю команди для Windows'
New-Item -ItemType Directory -Force -Path $BinDir | Out-Null
foreach ($f in @('night-shift-wsl.ps1', 'night-shift.cmd', 'night-queue.cmd', 'deep-audit.cmd')) {
  $text = (& wsl.exe @pick -e cat "$root/windows/$f") -join "`r`n"
  if ($LASTEXITCODE -ne 0 -or -not $text) { Die "у движку немає windows/$f — схоже, версія застара." }
  # PowerShell 5.1 reads a script without a byte-order mark as the ANSI code page, which would turn
  # the Ukrainian messages into mojibake.
  $enc = if ($f -like '*.ps1') { New-Object System.Text.UTF8Encoding($true) } else { New-Object System.Text.UTF8Encoding($false) }
  [System.IO.File]::WriteAllText((Join-Path $BinDir $f), $text + "`r`n", $enc)
}
[System.IO.File]::WriteAllText((Join-Path $BinDir 'distro.txt'), $Distro, (New-Object System.Text.UTF8Encoding($false)))
[System.IO.File]::WriteAllText((Join-Path $BinDir 'entry.txt'), "$root/windows/wsl-entry.sh", (New-Object System.Text.UTF8Encoding($false)))
Set-UserPath $BinDir $true
$env:Path = "$BinDir;$env:Path"
Note "команди: $BinDir"

Say 'готово'
Write-Host @"
  Відкрий новий термінал (щоб підхопився PATH), тоді:
    night-shift doctor                       — що ще треба (claude і codex мають бути в WSL і з входом)
    night-shift start C:\code\app --model opus
    night-shift config keys

  Проєкти краще тримати у файловій системі Linux (\\wsl$\$Distro\home\…): на диску C: git і збірка
  у рази повільніші. Знімки екрана як доказ роботи є лише в застосунку Bulava для macOS.
"@
