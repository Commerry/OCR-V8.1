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

# The script is piped in on stdin rather than passed as an argument: Windows
# ssh rewrites arguments, and a command carrying quotes came out mangled on the
# far side (an earlier version failed with "ambiguous redirect" and this one
# came back empty).
function Invoke-SshScript {
    param([string] $RemoteHost, [string] $Script, [int] $Sec = 60)
    $body = $Script -replace "`r", ''
    $job = Start-Job -ScriptBlock {
        param($k, $u, $h, $b)
        $ErrorActionPreference = 'Continue'
        $b | & ssh -i $k -o BatchMode=yes -o StrictHostKeyChecking=no -o UserKnownHostsFile=NUL `
                   -o ConnectTimeout=8 -o ServerAliveInterval=5 -o ServerAliveCountMax=3 `
                   -o LogLevel=ERROR "$u@$h" 'bash -s' 2>&1
    } -ArgumentList $keyPath, $User, $RemoteHost, $body

    if (Wait-Job $job -Timeout $Sec) {
        $o = Receive-Job $job -ErrorAction SilentlyContinue
        Remove-Job $job -Force -ErrorAction SilentlyContinue
        return @($o | ForEach-Object { "$_" })
    }
    Stop-Job $job -ErrorAction SilentlyContinue
    Remove-Job $job -Force -ErrorAction SilentlyContinue
    return @("TIMEOUT ไม่ตอบใน $Sec วินาที")
}

# a path starting with ~ has to become $HOME: it is expanded by the remote
# shell, not by us
$remoteDir = $AppDir -replace '^~', '$HOME'

# ---------------------------------------------------------------- status ----
# Reads only: git state, what this site has modified, the clock, the sudo rule.
$statusScript = @"
# Find the program even when it is not where we expect - several cameras were
# installed to a different path.
DIR=$remoteDir
[ -d "`$DIR" ] || DIR=`$(pm2 describe $Pm2Name 2>/dev/null | grep -m1 'exec cwd' | sed 's/.*│ *//;s/ *│.*//')
[ -d "`$DIR" ] || DIR=`$(ls -d `$HOME/Desktop/OCR* `$HOME/OCR* 2>/dev/null | head -1)
[ -d "`$DIR" ] || { echo ERRDIR; exit 1; }
cd "`$DIR" || { echo ERRDIR; exit 1; }
echo DIR `$DIR

echo COMMIT `$(git log --oneline -1 2>/dev/null | cut -c1-60 || echo not-a-git-repo)
echo TIME `$(date '+%Y-%m-%d %H:%M:%S %Z')
echo SUDOERS `$([ -f /etc/sudoers.d/ocr-settime ] && echo yes || echo no)
echo TIMESYNC `$([ -f src/utils/timeSync.js ] && echo yes || echo no)

# What the new centralReporter.js needs to exist already. The commit label
# cannot answer this: some cameras were updated by copying files over an old
# checkout, so the working tree is newer than the commit says.
echo HASHEALTH `$([ -f src/utils/systemHealth.js ] && echo yes || echo no)
echo HASRUNNER `$(grep -c 'getRecentReads' src/ocrRunner.js 2>/dev/null || echo 0)
echo HASWIRE `$(grep -c 'centralReporter' src/server.js 2>/dev/null || echo 0)

# Has this site edited any of the files we would overwrite?
echo TARGETDIRTY `$(git status --porcelain -- $($FILES -join ' ') 2>/dev/null | grep -v '^??' | wc -l)
git status --porcelain -- $($FILES -join ' ') 2>/dev/null | grep -v '^??' | sed 's/^/TARGETFILE /'
echo OTHERDIRTY `$(git status --porcelain 2>/dev/null | grep -v '^??' | wc -l)
echo PM2 `$(pm2 list 2>/dev/null | grep -c online)
"@

# ----------------------------------------------------------------- apply ----
# Checks out the listed paths and nothing else - config.json and the web pages
# are never in that list.
$applyScript = @"
DIR=$remoteDir
[ -d "`$DIR" ] || DIR=`$(pm2 describe $Pm2Name 2>/dev/null | grep -m1 'exec cwd' | sed 's/.*│ *//;s/ *│.*//')
[ -d "`$DIR" ] || DIR=`$(ls -d `$HOME/Desktop/OCR* `$HOME/OCR* 2>/dev/null | head -1)
[ -d "`$DIR" ] || { echo ERRDIR; exit 1; }
cd "`$DIR" || { echo ERRDIR; exit 1; }
echo DIR `$DIR
[ -d .git ] || { echo ERRNOGIT; exit 1; }

# the new centralReporter leans on these; without them the program would not
# start after the swap
[ -f src/utils/systemHealth.js ] || { echo ERRDEPS systemHealth; exit 1; }
grep -q 'getRecentReads' src/ocrRunner.js 2>/dev/null || { echo ERRDEPS ocrRunner; exit 1; }

cp -a src/utils/centralReporter.js /tmp/centralReporter.bak.js 2>/dev/null
git config --global http.sslCAInfo /etc/ssl/certs/ca-certificates.crt 2>/dev/null || true
if ! git fetch origin main >/tmp/ts-fetch.log 2>&1; then
    git -c http.sslVerify=false fetch origin main >/tmp/ts-fetch.log 2>&1 || { echo ERRFETCH; tail -2 /tmp/ts-fetch.log; exit 1; }
fi
git checkout origin/main -- $($FILES -join ' ') || { echo ERRCHECKOUT; exit 1; }
echo FILES `$(git diff --cached --name-only | tr '
' ' ')

echo '$Password' | sudo -S bash tools/install-timesync-sudoers.sh $User >/tmp/ts-sudo.log 2>&1
echo SUDOERS `$([ -f /etc/sudoers.d/ocr-settime ] && echo yes || echo no)

pm2 restart $Pm2Name >/dev/null 2>&1
sleep 4
ONLINE=`$(pm2 list 2>/dev/null | grep -c online)
echo PM2 `$ONLINE
# a program that will not come back up gets its old file returned
if [ "`$ONLINE" = "0" ]; then
    cp -a /tmp/centralReporter.bak.js src/utils/centralReporter.js 2>/dev/null
    pm2 restart $Pm2Name >/dev/null 2>&1
    echo ROLLEDBACK yes
fi
echo TIME `$(date '+%Y-%m-%d %H:%M:%S %Z')
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
    $lines = Invoke-SshScript -RemoteHost $h -Script $(if ($Apply) { $applyScript } else { $statusScript }) -Sec $TimeoutSec
    $get = { param($key) ($lines | Where-Object { $_ -like "$key *" } | Select-Object -First 1) -replace "^$key ", '' }

    $joined = ($lines -join ' ')
    if ($joined -match 'TIMEOUT|ERRDIR|ERRNOGIT|ERRFETCH|ERRCHECKOUT' -or -not ($joined -match 'TIME ')) {
        Write-Host ("[{0,2}/{1}] {2,-16} ปัญหา: {3}" -f $n, $Hosts.Count, $h, (($lines | Select-Object -First 2) -join ' ')) -ForegroundColor Red
        $problems += $h
        continue
    }

    if ($Apply) {
        $files = (& $get 'FILES').Trim()
        $sudoers = & $get 'SUDOERS'
        $online = [int](& $get 'PM2')
        $rolled = & $get 'ROLLEDBACK'
        $time = & $get 'TIME'
        if ($rolled -eq 'yes') {
            Write-Host ("[{0,2}/{1}] {2,-16} โปรแกรมไม่ขึ้นหลังเปลี่ยนไฟล์ - คืนไฟล์เดิมให้แล้ว" -f $n, $Hosts.Count, $h) -ForegroundColor Red
            $problems += $h
        } elseif ($sudoers -eq 'yes' -and $online -gt 0) {
            Write-Host ("[{0,2}/{1}] {2,-16} อัปเดตแล้ว: {3}" -f $n, $Hosts.Count, $h, $files) -ForegroundColor Green
            Write-Host ("                  สิทธิ์ตั้งเวลา: yes   pm2 online: {0}   เวลา: {1}" -f $online, $time)
        } else {
            Write-Host ("[{0,2}/{1}] {2,-16} อัปไฟล์แล้วแต่ยังไม่ครบ (สิทธิ์={3} online={4})" -f $n, $Hosts.Count, $h, $sudoers, $online) -ForegroundColor Yellow
            $problems += $h
        }
    } else {
        $commit = (& $get 'COMMIT')
        $dir = & $get 'DIR'
        $time = & $get 'TIME'
        $sudoers = & $get 'SUDOERS'
        $hasSync = & $get 'TIMESYNC'
        $hasHealth = & $get 'HASHEALTH'
        $hasRunner = [int](& $get 'HASRUNNER')
        $hasWire = [int](& $get 'HASWIRE')
        $targetDirty = [int](& $get 'TARGETDIRTY')
        $otherDirty = [int](& $get 'OTHERDIRTY')

        # Can this camera take the three-file update as it stands?
        $ready = ($hasHealth -eq 'yes') -and ($hasRunner -gt 0)
        if ($hasSync -eq 'yes' -and $sudoers -eq 'yes') {
            $verdict = 'อัปแล้ว'; $color = 'Green'
        } elseif (-not $ready) {
            $verdict = 'ยังอัปไม่ได้ - ขาดไฟล์ที่ต้องใช้'; $color = 'Red'
            $problems += $h
        } elseif ($targetDirty -gt 0) {
            $verdict = 'ไซต์แก้ไฟล์ที่จะทับไว้เอง - ต้องดูก่อน'; $color = 'Yellow'
            $problems += $h
        } else {
            $verdict = 'พร้อมอัป'; $color = 'Cyan'
        }

        Write-Host ("[{0,2}/{1}] {2,-16} {3}" -f $n, $Hosts.Count, $h, $verdict) -ForegroundColor $color
        Write-Host ("                  {0}" -f $commit) -ForegroundColor DarkGray
        Write-Host ("                  เวลา: {0}   timeSync: {1}   สิทธิ์: {2}" -f $time, $hasSync, $sudoers)
        Write-Host ("                  systemHealth: {0}   ocrRunner API: {1}   central ใน server.js: {2}" -f
            $hasHealth, $(if ($hasRunner -gt 0) { 'yes' } else { 'no' }), $(if ($hasWire -gt 0) { 'yes' } else { 'no' }))
        if ($dir -and $dir -ne ($AppDir -replace '^~', "/home/$User")) {
            Write-Host ("                  โฟลเดอร์: {0}" -f $dir) -ForegroundColor DarkGray
        }
        if ($targetDirty -gt 0) {
            Write-Host "                  ไฟล์ที่จะทับ แต่ไซต์แก้ไว้เอง:" -ForegroundColor Yellow
            $lines | Where-Object { $_ -like 'TARGETFILE *' } | ForEach-Object {
                Write-Host ("                     {0}" -f ($_ -replace '^TARGETFILE ', '')) -ForegroundColor Yellow
            }
        } elseif ($otherDirty -gt 0) {
            Write-Host ("                  มีไฟล์อื่นที่แก้ไว้เอง {0} ไฟล์ - ไม่ถูกแตะ" -f $otherDirty) -ForegroundColor DarkGray
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
