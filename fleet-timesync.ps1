<#
.SYNOPSIS
  ตรวจสถานะกล้องทั้ง fleet แล้วอัปเดต "เฉพาะไฟล์ที่เกี่ยวกับการตั้งนาฬิกา"

.DESCRIPTION
  กล้องแต่ละตัวมีคอนฟิกและหน้าเว็บที่แก้ไว้ไม่เหมือนกัน สคริปต์นี้จึงไม่ทำ
  git pull ทั้งก้อน แต่ดึงมาเฉพาะ 3 ไฟล์ที่ต้องใช้จริง:

      src/utils/timeSync.js               (ไฟล์ใหม่)
      src/utils/centralReporter.js        (แก้ไข)
      tools/install-timesync-sudoers.sh   (ไฟล์ใหม่)

  ไฟล์อื่นทั้งหมดคงเดิม - config.json (git ไม่ track อยู่แล้ว), src/index.html,
  src/login.html, public/, python/ ไม่ถูกแตะ

  ใช้ -Status ดูก่อนเสมอ: จะบอกว่ากล้องแต่ละตัวอยู่คอมมิตไหน มีไฟล์ไหนที่แก้ไว้เอง
  (ซึ่งการอัปเดตอาจทับ) เวลาและ timezone ปัจจุบัน และติดตั้งสิทธิ์ตั้งเวลาแล้วหรือยัง

.EXAMPLE
  .\fleet-timesync.ps1 -Status     # ดูอย่างเดียว ไม่แก้อะไร
  .\fleet-timesync.ps1 -Apply      # อัปเดตเฉพาะ 3 ไฟล์ + ตั้งสิทธิ์ + restart
  .\fleet-timesync.ps1 -Apply -Hosts 10.11.181.47,10.11.181.49
#>
[CmdletBinding(DefaultParameterSetName = 'Status')]
param(
    [switch]   $Status,
    [switch]   $Apply,
    [string[]] $Hosts,
    [string]   $HostFile,
    [string]   $User = 'pi',
    [string]   $Password = 'raspberry',
    [string]   $AppDir = '~/Desktop/OCR-V8.1',
    [string]   $Pm2Name = 'ocr',
    [int]      $TimeoutSec = 60
)

$ErrorActionPreference = 'Continue'
try { [Console]::OutputEncoding = [Text.Encoding]::UTF8 } catch { }

# the only paths this tool is allowed to touch
$FILES = @(
    'src/utils/timeSync.js'
    'src/utils/centralReporter.js'
    'tools/install-timesync-sudoers.sh'
)

if (-not $Hosts -or $Hosts.Count -eq 0) {
    if ($HostFile -and (Test-Path $HostFile)) {
        $Hosts = Get-Content $HostFile | ForEach-Object { ($_ -split '#')[0].Trim() } | Where-Object { $_ }
    } else {
        $Hosts = @(
            '10.41.182.15', '10.41.182.17'
            '10.31.182.15', '10.31.182.16', '10.31.182.17'
            '10.31.181.27', '10.31.181.28'
            '10.32.181.15', '10.32.181.16'
            '10.36.181.35', '10.36.181.36', '10.36.181.37'
            '10.11.181.43', '10.11.181.45', '10.11.181.47', '10.11.181.49'
        )
    }
}
$Hosts = $Hosts | Select-Object -Unique

$keyPath = Join-Path $env:USERPROFILE '.ssh\ocr_fleet_ed25519'
if (-not (Test-Path $keyPath)) {
    Write-Host "ไม่พบ ssh key ที่ $keyPath - รัน .\clean-my-cameras.ps1 -SetTimeOnly ครั้งหนึ่งก่อนเพื่อสร้างและติดตั้ง key" -ForegroundColor Red
    exit 1
}

function Invoke-SshTimed {
    param([string] $RemoteHost, [string] $Command, [int] $Sec = 60)
    $job = Start-Job -ScriptBlock {
        param($k, $u, $h, $c)
        & ssh -i $k -o BatchMode=yes -o StrictHostKeyChecking=no -o UserKnownHostsFile=NUL `
              -o ConnectTimeout=8 -o ServerAliveInterval=5 -o ServerAliveCountMax=3 `
              -o LogLevel=ERROR "$u@$h" $c 2>&1
    } -ArgumentList $keyPath, $User, $RemoteHost, $Command
    if (Wait-Job $job -Timeout $Sec) {
        $o = Receive-Job $job -ErrorAction SilentlyContinue
        Remove-Job $job -Force -ErrorAction SilentlyContinue
        return @($o | ForEach-Object { "$_" })
    }
    Stop-Job $job -ErrorAction SilentlyContinue
    Remove-Job $job -Force -ErrorAction SilentlyContinue
    return @("TIMEOUT ไม่ตอบใน $Sec วินาที")
}

# ---------------------------------------------------------------- status ----
# Everything here only reads: git state, what the site has modified locally,
# the clock, and whether the sudo rule is in place.
$statusCmd = @"
cd $AppDir 2>/dev/null || { echo 'ERR ไม่พบโฟลเดอร์ $AppDir'; exit 1; }
echo "COMMIT `$(git log --oneline -1 2>/dev/null || echo 'ไม่ใช่ git repo')"
echo "BRANCH `$(git rev-parse --abbrev-ref HEAD 2>/dev/null)"
echo "DIRTY `$(git status --porcelain 2>/dev/null | grep -v '^??' | wc -l)"
git status --porcelain 2>/dev/null | grep -v '^??' | head -5 | sed 's/^/DIRTYFILE /'
echo "TIME `$(date '+%Y-%m-%d %H:%M:%S %Z')"
echo "SUDOERS `$([ -f /etc/sudoers.d/ocr-settime ] && echo yes || echo no)"
echo "TIMESYNC `$([ -f src/utils/timeSync.js ] && echo yes || echo no)"
echo "PM2 `$(pm2 list 2>/dev/null | grep -c online)"
echo "CENTRAL `$(grep -o '\"url\":\"[^\"]*\"' config.json 2>/dev/null | head -1)"
"@

# ----------------------------------------------------------------- apply ----
# Fetch, then check out ONLY the listed paths. Nothing else in the working tree
# is touched - not config.json (git does not track it), not the web pages.
$applyCmd = @"
cd $AppDir 2>/dev/null || { echo 'ERR ไม่พบโฟลเดอร์ $AppDir'; exit 1; }
[ -d .git ] || { echo 'ERR ไม่ใช่ git repo - ต้องต่อ git ก่อน'; exit 1; }
git config --global http.sslCAInfo /etc/ssl/certs/ca-certificates.crt 2>/dev/null || true
if ! git fetch origin main >/tmp/ts-fetch.log 2>&1; then
    git -c http.sslVerify=false fetch origin main >/tmp/ts-fetch.log 2>&1 || { echo 'ERR fetch ไม่สำเร็จ'; tail -2 /tmp/ts-fetch.log; exit 1; }
fi
BEFORE=`$(git rev-parse --short HEAD)
git checkout origin/main -- $($FILES -join ' ') || { echo 'ERR checkout ไม่สำเร็จ'; exit 1; }
echo "FILES `$(git diff --cached --name-only | tr '\n' ' ')"
echo '$Password' | sudo -S bash tools/install-timesync-sudoers.sh $User >/tmp/ts-sudo.log 2>&1
echo "SUDOERS `$([ -f /etc/sudoers.d/ocr-settime ] && echo yes || echo no)"
pm2 restart $Pm2Name >/dev/null 2>&1
echo "RESTARTED `$(pm2 list 2>/dev/null | grep -c online)"
echo "HEAD `$BEFORE (ไฟล์อื่นไม่ถูกแตะ)"
echo "TIME `$(date '+%Y-%m-%d %H:%M:%S %Z')"
"@

$mode = if ($Apply) { 'apply' } else { 'status' }
Write-Host ''
Write-Host "=== fleet-timesync ($mode) - กล้อง $($Hosts.Count) ตัว ===" -ForegroundColor Cyan
if ($Apply) {
    Write-Host 'จะดึงมาเฉพาะไฟล์เหล่านี้ ไฟล์อื่นคงเดิมทั้งหมด:' -ForegroundColor Yellow
    $FILES | ForEach-Object { Write-Host "   $_" -ForegroundColor Yellow }
}
Write-Host ''

$n = 0
$problems = @()
foreach ($h in $Hosts) {
    $n++
    $lines = Invoke-SshTimed -RemoteHost $h -Command $(if ($Apply) { $applyCmd } else { $statusCmd }) -Sec $TimeoutSec
    $get = { param($key) ($lines | Where-Object { $_ -like "$key *" } | Select-Object -First 1) -replace "^$key ", '' }

    if (($lines -join ' ') -match 'TIMEOUT|^ERR |ERR ไม่') {
        Write-Host ("[{0,2}/{1}] {2,-16} ปัญหา: {3}" -f $n, $Hosts.Count, $h, (($lines | Select-Object -First 2) -join ' ')) -ForegroundColor Red
        $problems += $h
        continue
    }

    if ($Apply) {
        $files = (& $get 'FILES').Trim()
        $sudoers = & $get 'SUDOERS'
        $time = & $get 'TIME'
        $okColor = if ($sudoers -eq 'yes') { 'Green' } else { 'Yellow' }
        Write-Host ("[{0,2}/{1}] {2,-16} อัปเดต: {3}" -f $n, $Hosts.Count, $h, ($(if ($files) { $files } else { '(ไม่มีไฟล์เปลี่ยน)' }))) -ForegroundColor $okColor
        Write-Host ("                  สิทธิ์ตั้งเวลา: {0}   เวลาเครื่อง: {1}" -f $sudoers, $time)
        if ($sudoers -ne 'yes') { $problems += $h }
    } else {
        $commit = & $get 'COMMIT'
        $dirty = [int](& $get 'DIRTY')
        $time = & $get 'TIME'
        $sudoers = & $get 'SUDOERS'
        $hasSync = & $get 'TIMESYNC'
        $central = & $get 'CENTRAL'
        $color = if ($dirty -gt 0) { 'Yellow' } else { 'Green' }
        Write-Host ("[{0,2}/{1}] {2,-16} {3}" -f $n, $Hosts.Count, $h, $commit) -ForegroundColor $color
        Write-Host ("                  เวลา: {0}   timeSync: {1}   สิทธิ์: {2}" -f $time, $hasSync, $sudoers)
        if ($central) { Write-Host ("                  central: {0}" -f $central) -ForegroundColor DarkGray }
        if ($dirty -gt 0) {
            Write-Host ("                  มีไฟล์ที่แก้ไว้เอง {0} ไฟล์:" -f $dirty) -ForegroundColor Yellow
            $lines | Where-Object { $_ -like 'DIRTYFILE *' } | ForEach-Object {
                Write-Host ("                     {0}" -f ($_ -replace '^DIRTYFILE ', '')) -ForegroundColor Yellow
            }
            $problems += $h
        }
    }
}

Write-Host ''
if ($problems.Count -gt 0) {
    Write-Host "ต้องดูเพิ่ม $($problems.Count) ตัว: $(($problems | Select-Object -Unique) -join ', ')" -ForegroundColor Yellow
    if (-not $Apply) {
        Write-Host 'ไฟล์ที่แก้ไว้เองจะไม่ถูกแตะ ยกเว้นเป็นหนึ่งใน 3 ไฟล์ข้างบน - ตรวจก่อนสั่ง -Apply' -ForegroundColor Yellow
    }
} else {
    Write-Host 'ทุกตัวเรียบร้อย' -ForegroundColor Green
}
if (-not $Apply) {
    Write-Host ''
    Write-Host 'พอใจแล้วสั่ง: .\fleet-timesync.ps1 -Apply' -ForegroundColor Cyan
}
