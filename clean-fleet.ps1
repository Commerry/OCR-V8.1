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
    [int]      $HostTimeoutSec = 420,
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
# The steps that run on each camera live in tools/clean-remote.sh, shared with
# the bash version so both stay in step.
# ---------------------------------------------------------------------------
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
$remoteFile = Join-Path $here 'tools\clean-remote.sh'
if (-not (Test-Path $remoteFile)) {
    Write-Host "ไม่พบ $remoteFile (git pull ใหม่อีกครั้ง)" -ForegroundColor Red
    exit 1
}
# LF endings: bash chokes on a script full of CR characters
$remote = ([IO.File]::ReadAllText($remoteFile)) -replace "`r`n", "`n"

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
$ok = 0
$failed = 0
$finished = 0
$total = $Hosts.Count

# Results are printed the moment a camera finishes, not at the very end: a
# fleet of sixteen used to look frozen for minutes with nothing on screen.
$show = {
    param($r, $n, $total)
    $status = if ($r.Ok) { 'OK' } else { 'FAIL' }
    $color = if ($r.Ok) { 'Green' } else { 'Red' }
    Write-Host "===== [$n/$total] $($r.Host) [$status] =====" -ForegroundColor $color
    ($r.Output -split "`n") | ForEach-Object { Write-Host "  $_" }
    Write-Host ''
}

while ($queue.Count -gt 0 -or $running.Count -gt 0) {
    while ($queue.Count -gt 0 -and $running.Count -lt $Jobs) {
        $h = $queue.Dequeue()
        $job = Start-Job -ScriptBlock $script -ArgumentList $h, $User, $remote, $envPrefix, $Plink, $Password, $IdentityFile
        $running += [pscustomobject]@{ Job = $job; Host = $h; Started = Get-Date }
    }

    foreach ($entry in @($running)) {
        $j = $entry.Job
        # a camera that never answers must not hold up the rest
        if ($j.State -eq 'Running' -and ((Get-Date) - $entry.Started).TotalSeconds -gt $HostTimeoutSec) {
            Stop-Job $j -ErrorAction SilentlyContinue
            $finished++; $failed++
            & $show ([pscustomobject]@{ Host = $entry.Host; Ok = $false; Output = "ไม่ตอบใน $HostTimeoutSec วินาที - ข้ามไปก่อน" }) $finished $total
            Remove-Job $j -Force -ErrorAction SilentlyContinue
            $running = @($running | Where-Object { $_.Job.Id -ne $j.Id })
            continue
        }
        if ($j.State -ne 'Running') {
            $r = Receive-Job $j -ErrorAction SilentlyContinue
            Remove-Job $j -Force -ErrorAction SilentlyContinue
            $running = @($running | Where-Object { $_.Job.Id -ne $j.Id })
            $finished++
            if ($r) {
                if ($r.Ok) { $ok++ } else { $failed++ }
                & $show $r $finished $total
            } else {
                $failed++
                & $show ([pscustomobject]@{ Host = $entry.Host; Ok = $false; Output = 'ไม่มีผลลัพธ์กลับมา' }) $finished $total
            }
        }
    }
    Start-Sleep -Milliseconds 400
}

Write-Host "done: $ok ok, $failed failed (from $total cameras)"
if ($failed -gt 0) {
    Write-Host 'กล้องที่ FAIL เพราะยังไม่มี ssh key: รันครั้งเดียวด้วย -SetupKeys' -ForegroundColor Yellow
}
