<#
.SYNOPSIS
  Free disk space on many OCR cameras at once, from Windows.

.DESCRIPTION
  Same job as clean-fleet.sh, for machines with no working bash/WSL. Uses the
  ssh client that ships with Windows 10/11.

  Windows ssh cannot take a password on the command line, so either:
    -SetupKeys   installs your ssh key on every camera (type the password once
                 per camera, then every later run needs no password at all)
    -Plink       uses PuTTY's plink.exe with -pw, if you have it

  Cleans pm2 logs, python/log.txt, npm/pip caches, stale temp files and - with
  -SudoPass - the apt cache and systemd journal. Installs pm2-logrotate where
  it is missing, and calls "pm2 reloadLogs" so space held by already-deleted
  log files comes back. Program files, config.json and saved images are left
  alone unless -ImagesDays says otherwise.

.EXAMPLE
  .\clean-fleet.ps1 -SetupKeys -Hosts 10.41.182.15,10.41.182.17
  .\clean-fleet.ps1 -Report -Hosts 10.41.182.15,10.41.182.17
  .\clean-fleet.ps1 -SudoPass raspberry -Hosts 10.41.182.15,10.41.182.17
  .\clean-fleet.ps1 -HostFile cameras.txt -SudoPass raspberry -ImagesDays 30
#>
[CmdletBinding()]
param(
    [string[]] $Hosts = @(),
    [string]   $HostFile,
    [string]   $User = 'pi',
    [string]   $SudoPass = '',
    [string]   $AppDir = '~/Desktop/OCR-V8.1',
    [string]   $Pm2Name = 'ocr',
    [int]      $Jobs = 4,
    [int]      $ImagesDays = 0,
    [switch]   $Report,
    [switch]   $DryRun,
    [switch]   $Restart,
    [switch]   $SetupKeys,
    [string]   $IdentityFile,
    [string]   $Plink,
    [string]   $Password = 'raspberry'
)

$ErrorActionPreference = 'Stop'

if ($HostFile) {
    $Hosts += Get-Content $HostFile | ForEach-Object { ($_ -split '#')[0].Trim() } | Where-Object { $_ }
}
if (-not $Hosts -or $Hosts.Count -eq 0) {
    Write-Host 'ไม่ได้ระบุกล้อง - ดูตัวอย่าง: Get-Help .\clean-fleet.ps1 -Examples' -ForegroundColor Yellow
    exit 1
}

$mode = if ($Report) { 'report' } elseif ($DryRun) { 'dry' } else { 'clean' }

# ---------------------------------------------------------------------------
# One-time: put our public key on every camera so later runs need no password
# ---------------------------------------------------------------------------
if ($SetupKeys) {
    $keyPath = Join-Path $env:USERPROFILE '.ssh\id_ed25519'
    if (-not (Test-Path "$keyPath.pub")) {
        Write-Host "สร้าง ssh key ใหม่ที่ $keyPath" -ForegroundColor Cyan
        & ssh-keygen -t ed25519 -N '""' -f $keyPath | Out-Null
    }
    # first line only, printable characters only: anything else in the argument
    # makes Windows refuse to start ssh with "filename or extension is too long"
    $pub = ((Get-Content "$keyPath.pub" -TotalCount 1) -join '').Trim()
    $pub = ($pub -replace '[^ -~]', '')
    if ($pub -notmatch '^ssh-') {
        Write-Host "อ่าน public key ไม่ได้จาก $keyPath.pub" -ForegroundColor Red
        exit 1
    }
    # the key appears once in the command, and duplicates are removed on the
    # camera instead, to keep this command line short
    $cmd = "mkdir -p ~/.ssh; chmod 700 ~/.ssh; echo '$pub' >> ~/.ssh/authorized_keys; sort -u -o ~/.ssh/authorized_keys ~/.ssh/authorized_keys; chmod 600 ~/.ssh/authorized_keys; echo KEY_OK"
    foreach ($h in $Hosts) {
        Write-Host "ติดตั้ง key บน $h (ใส่รหัส $User ครั้งเดียว)" -ForegroundColor Cyan
        $keyArgs = @('-o', 'StrictHostKeyChecking=no', '-o', 'UserKnownHostsFile=NUL', '-o', 'ConnectTimeout=10')
        if ($IdentityFile) { $keyArgs += @('-o', 'IdentitiesOnly=no') }
        & ssh @keyArgs "$User@$h" $cmd
        if ($LASTEXITCODE -ne 0) {
            Write-Host "  ไม่สำเร็จ - ทำมือได้ด้วย:  type `$env:USERPROFILE\.ssh\id_ed25519.pub | ssh $User@$h `"cat >> ~/.ssh/authorized_keys`"" -ForegroundColor Yellow
        }
    }
    Write-Host 'เสร็จ - คราวหน้าไม่ต้องใส่รหัส ssh อีก' -ForegroundColor Green
    if (-not $Report -and -not $DryRun -and $mode -eq 'clean' -and -not $PSBoundParameters.ContainsKey('SudoPass')) { exit 0 }
}

# ---------------------------------------------------------------------------
# What runs on each camera (same steps as clean-fleet.sh)
# ---------------------------------------------------------------------------
$remote = @'
set -u
cd "$APP_DIR" 2>/dev/null || true
human() { numfmt --to=iec --suffix=B "${1:-0}" 2>/dev/null || echo "${1:-0}B"; }
free_kb() { df -Pk / | awk 'NR==2 {print $4}'; }
size_kb() { du -sk "$@" 2>/dev/null | awk '{s+=$1} END {print s+0}'; }
export PATH="$PATH:/usr/local/bin:/usr/bin:$HOME/.npm-global/bin"
for d in "$HOME"/.nvm/versions/node/*/bin; do [ -d "$d" ] && PATH="$PATH:$d"; done

BEFORE=$(free_kb)
echo "ดิสก์: $(df -Ph / | awk 'NR==2 {print "ใช้ "$3" / "$2" ("$5")  เหลือ "$4}')"
echo "-- พื้นที่ที่ถูกใช้มากที่สุด --"
{
  [ -d "$APP_DIR/logs" ]   && echo "$(size_kb "$APP_DIR/logs") pm2 logs ในโปรแกรม"
  [ -d "$HOME/.pm2/logs" ] && echo "$(size_kb "$HOME/.pm2/logs") pm2 logs ส่วนกลาง"
  [ -d "$APP_DIR/Img" ]    && echo "$(size_kb "$APP_DIR/Img") รูปที่กล้องเซฟไว้"
  [ -d /var/log/journal ]  && echo "$(size_kb /var/log/journal) systemd journal"
  [ -d /var/cache/apt ]    && echo "$(size_kb /var/cache/apt) apt cache"
  [ -d "$HOME/.npm" ]      && echo "$(size_kb "$HOME/.npm") npm cache"
  [ -d "$HOME/.cache" ]    && echo "$(size_kb "$HOME/.cache") ~/.cache"
  [ -f "$APP_DIR/python/log.txt" ] && echo "$(size_kb "$APP_DIR/python/log.txt") python/log.txt"
} | sort -rn | head -6 | while read -r kb rest; do printf '   %8s  %s\n' "$(human $((kb * 1024)))" "$rest"; done

HELD=$(sudo -n lsof -nP +L1 2>/dev/null | awk '$0 !~ /^COMMAND/ {s+=$8} END {print s+0}')
[ "${HELD:-0}" -gt 10000000 ] 2>/dev/null && echo "   $(human "$HELD")  ไฟล์ที่ลบแล้วแต่ pm2 ยังถือไว้ (จะปล่อยด้วย pm2 reloadLogs)"

if [ "$MODE" = "report" ]; then echo "(โหมดดูอย่างเดียว)"; exit 0; fi
DRY=0; [ "$MODE" = "dry" ] && DRY=1
say() { if [ "$DRY" = "1" ]; then echo "   [จะลบ] $*"; else echo "   [ลบ] $*"; fi; }
do_rm() { [ "$DRY" = "1" ] || eval "$@" >/dev/null 2>&1; }
echo "-- ทำความสะอาด --"

PM2_KB=$(( $(size_kb "$HOME/.pm2/logs") + $(size_kb "$APP_DIR/logs") ))
if [ "$PM2_KB" -gt 1024 ]; then
  say "pm2 logs $(human $((PM2_KB * 1024)))"
  command -v pm2 >/dev/null 2>&1 && do_rm "pm2 flush"
  do_rm "find '$APP_DIR/logs' '$HOME/.pm2/logs' -name '*.log*' -exec truncate -s 0 {} +"
fi
# releases space held by log files deleted earlier - restarting the app does
# not do this, the pm2 daemon owns those handles
command -v pm2 >/dev/null 2>&1 && do_rm "pm2 reloadLogs"

if command -v pm2 >/dev/null 2>&1 && ! pm2 list 2>/dev/null | grep -q pm2-logrotate; then
  say "ติดตั้ง pm2-logrotate (20MB x 5 ไฟล์)"
  if [ "$DRY" != "1" ]; then
    pm2 install pm2-logrotate >/dev/null 2>&1 \
      && pm2 set pm2-logrotate:max_size 20M >/dev/null 2>&1 \
      && pm2 set pm2-logrotate:retain 5 >/dev/null 2>&1 \
      && pm2 set pm2-logrotate:compress true >/dev/null 2>&1
  fi
fi

if [ -f "$APP_DIR/python/log.txt" ]; then
  KB=$(size_kb "$APP_DIR/python/log.txt")
  [ "$KB" -gt 1024 ] && { say "python/log.txt $(human $((KB * 1024)))"; do_rm "truncate -s 0 '$APP_DIR/python/log.txt'"; }
fi

for dir in "$HOME/.npm/_cacache" "$HOME/.cache/pip" "$HOME/.cache/thumbnails"; do
  KB=$(size_kb "$dir")
  [ "$KB" -gt 1024 ] && { say "$dir $(human $((KB * 1024)))"; do_rm "rm -rf '$dir'"; }
done

KB=$(size_kb /tmp)
if [ "$KB" -gt 10240 ]; then
  say "ไฟล์ชั่วคราวเก่าใน /tmp $(human $((KB * 1024)))"
  do_rm "find /tmp -maxdepth 1 -mtime +1 -type f \( -name 'ocr-*' -o -name 'tmp*' -o -name 'npm-*' -o -name '*.log' -o -name 'core.*' -o -name '*.jpg' -o -name '*.png' \) -delete"
fi

if [ -n "${SUDO_PASS:-}" ]; then
  KB=$(size_kb /var/cache/apt/archives)
  [ "$KB" -gt 1024 ] && { say "apt cache $(human $((KB * 1024)))"; do_rm "echo '$SUDO_PASS' | sudo -S apt-get clean"; }
  KB=$(size_kb /var/log/journal)
  [ "$KB" -gt 102400 ] && { say "systemd journal $(human $((KB * 1024))) -> 100MB"; do_rm "echo '$SUDO_PASS' | sudo -S journalctl --vacuum-size=100M"; }
else
  echo "   (ข้าม apt cache และ journal - ไม่ได้ใส่ -SudoPass)"
fi

if [ "${IMAGES_DAYS:-0}" -gt 0 ] && [ -d "$APP_DIR/Img" ]; then
  N=$(find "$APP_DIR/Img" -type f -mtime +"$IMAGES_DAYS" 2>/dev/null | wc -l)
  [ "$N" -gt 0 ] && { say "รูปเก่ากว่า $IMAGES_DAYS วัน จำนวน $N ไฟล์"; do_rm "find '$APP_DIR/Img' -type f -mtime +$IMAGES_DAYS -delete"; }
fi

if [ "$DO_RESTART" = "1" ] && [ "$DRY" != "1" ] && command -v pm2 >/dev/null 2>&1; then
  echo "   [restart] pm2 update"
  pm2 update >/dev/null 2>&1 || pm2 restart "$PM2_NAME" >/dev/null 2>&1
  sleep 3
fi

AFTER=$(free_kb); GAIN=$(( AFTER - BEFORE )); [ "$GAIN" -lt 0 ] && GAIN=0
if [ "$DRY" = "1" ]; then echo "ผล: โหมดทดลอง ไม่ได้ลบจริง"
else echo "ผล: คืนพื้นที่ $(human $((GAIN * 1024)))  |  $(df -Ph / | awk 'NR==2 {print "เหลือ "$4" ("$5" ใช้ไป)"}')"; fi
'@ -replace "`r`n", "`n"

$envPrefix = "APP_DIR='$AppDir' PM2_NAME='$Pm2Name' MODE='$mode' IMAGES_DAYS='$ImagesDays' DO_RESTART='$(if ($Restart) {1} else {0})' SUDO_PASS='$SudoPass'"

Write-Host "cameras : $($Hosts.Count)"
Write-Host "user    : $User   folder: $AppDir   pm2: $Pm2Name"
Write-Host "mode    : $mode$(if ($ImagesDays -gt 0) { "   images older than ${ImagesDays}d" })$(if ($Restart) { '   +restart' })"
Write-Host ''

$script = {
    param($h, $user, $remote, $envPrefix, $plink, $password, $identity)
    # a broken connection writes to stderr; keep it as output instead of
    # turning it into a PowerShell error record
    $ErrorActionPreference = 'Continue'
    $tmp = [IO.Path]::GetTempFileName()
    try {
        [IO.File]::WriteAllText($tmp, $remote, (New-Object Text.UTF8Encoding $false))
        $body = [IO.File]::ReadAllText($tmp)
        try {
            if ($plink) {
                $out = $body | & $plink -ssh -batch -pw $password "$user@$h" "$envPrefix bash -s" 2>&1
            } else {
                $sshArgs = @('-o', 'StrictHostKeyChecking=no', '-o', 'UserKnownHostsFile=NUL',
                             '-o', 'ConnectTimeout=10', '-o', 'BatchMode=yes')
                if ($identity) { $sshArgs += @('-i', $identity) }
                $sshArgs += @("$user@$h", "$envPrefix bash -s")
                $out = $body | & ssh @sshArgs 2>&1
            }
            $code = $LASTEXITCODE
        } catch {
            $out = $_.Exception.Message
            $code = 1
        }
        [pscustomobject]@{
            Host   = $h
            Ok     = ($code -eq 0)
            Output = (($out | ForEach-Object { "$_" }) -join "`n")
        }
    } finally {
        Remove-Item $tmp -Force -ErrorAction SilentlyContinue
    }
}

$queue = [System.Collections.Queue]::new(@($Hosts))
$running = @()
$results = @()

while ($queue.Count -gt 0 -or $running.Count -gt 0) {
    while ($queue.Count -gt 0 -and $running.Count -lt $Jobs) {
        $h = $queue.Dequeue()
        $running += Start-Job -ScriptBlock $script -ArgumentList $h, $User, $remote, $envPrefix, $Plink, $Password, $IdentityFile
    }
    $done = $running | Where-Object { $_.State -ne 'Running' }
    foreach ($j in $done) {
        $results += Receive-Job $j -ErrorAction SilentlyContinue
        Remove-Job $j -Force
    }
    $running = @($running | Where-Object { $_.State -eq 'Running' })
    Start-Sleep -Milliseconds 400
}

$ok = 0
foreach ($r in $results) {
    $status = if ($r.Ok) { 'OK' } else { 'FAIL' }
    $color = if ($r.Ok) { 'Green' } else { 'Red' }
    Write-Host "===== $($r.Host) [$status] =====" -ForegroundColor $color
    ($r.Output -split "`n") | ForEach-Object { Write-Host "  $_" }
    Write-Host ''
    if ($r.Ok) { $ok++ }
}
Write-Host "done: $ok ok, $($results.Count - $ok) failed (from $($Hosts.Count) cameras)"
if ($ok -lt $results.Count) {
    Write-Host 'กล้องที่ FAIL เพราะยังไม่มี ssh key: รันครั้งเดียวด้วย -SetupKeys' -ForegroundColor Yellow
}
