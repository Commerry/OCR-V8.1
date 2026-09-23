<#
.SYNOPSIS
  เคลียร์พื้นที่กล้อง OCR ทุกตัวในโรงงาน - รันไฟล์เดียวจบ

.DESCRIPTION
  ทำให้ครบทุกขั้นเอง:
    1. ตรวจว่ามี ssh ของ Windows
    2. สร้าง ssh key ถ้ายังไม่มี
    3. ติดตั้ง key บนกล้องที่ยังเข้าไม่ได้ (ถามรหัสเฉพาะตัวที่ยังไม่มี key)
    4. เคลียร์พื้นที่ทุกตัวพร้อมกัน
    5. สรุปว่าแต่ละตัวคืนพื้นที่เท่าไหร่

  สิ่งที่เคลียร์: pm2 log, python/log.txt, npm/pip cache, ~/.cache,
  ไฟล์ชั่วคราวเก่าใน /tmp, systemd journal, apt cache
  พร้อมสั่ง pm2 reloadLogs (คืนพื้นที่ของ log ที่ลบไปแล้วแต่ยังถูกถือไว้)
  และติดตั้ง pm2-logrotate ให้ตัวที่ยังไม่มี เพื่อไม่ให้กลับมาเต็มอีก

  ไม่แตะ: ไฟล์โปรแกรม, config.json, บัญชีผู้ใช้เว็บ, รูปที่กล้องเซฟไว้
  (จะลบรูปเก่าต้องสั่ง -ImagesDays เอง)

.EXAMPLE
  .\clean-my-cameras.ps1              # ดูก่อนว่าอะไรกินพื้นที่ แล้วเคลียร์
  .\clean-my-cameras.ps1 -ReportOnly  # ดูอย่างเดียว ไม่ลบอะไร
  .\clean-my-cameras.ps1 -ImagesDays 30
#>
[CmdletBinding()]
param(
    [switch] $ReportOnly,
    [int]    $ImagesDays = 0,
    [switch] $Restart,
    [string] $User = 'pi',
    [string] $Password = 'raspberry',
    [int]    $Jobs = 6
)

$ErrorActionPreference = 'Continue'

# the cameras answer in Thai (UTF-8); without this the console prints ?????
try { [Console]::OutputEncoding = [Text.Encoding]::UTF8 } catch { }

# กล้องทั้งหมด - แก้ตรงนี้เวลาเพิ่ม/ลดกล้อง
$Cameras = @(
    '10.41.182.15'
    '10.41.182.17'
    '10.31.182.15'
    '10.31.182.16'
    '10.31.182.17'
    '10.31.181.27'
    '10.31.181.28'
    '10.32.181.15'
    '10.32.181.16'
    '10.36.181.35'
    '10.36.181.36'
    '10.36.181.37'
    '10.11.181.43'
    '10.11.181.45'
    '10.11.181.47'
    '10.11.181.49'
) | Select-Object -Unique

$here = Split-Path -Parent $MyInvocation.MyCommand.Path
$cleaner = Join-Path $here 'clean-fleet.ps1'
if (-not (Test-Path $cleaner)) {
    Write-Host "ไม่พบ clean-fleet.ps1 ในโฟลเดอร์เดียวกัน ($here)" -ForegroundColor Red
    Write-Host 'ดึงใหม่ด้วย: git clone https://github.com/Commerry/OCR-V8.1.git' -ForegroundColor Yellow
    exit 1
}

Write-Host ''
Write-Host "=== เคลียร์พื้นที่กล้อง OCR $($Cameras.Count) ตัว ===" -ForegroundColor Cyan
Write-Host ''

# ---- 1. ssh ของ Windows ----
if (-not (Get-Command ssh.exe -ErrorAction SilentlyContinue)) {
    Write-Host 'เครื่องนี้ยังไม่ได้เปิด OpenSSH Client' -ForegroundColor Red
    Write-Host 'เปิดที่: Settings > Apps > Optional features > Add a feature > OpenSSH Client' -ForegroundColor Yellow
    Write-Host 'หรือรัน (ต้องเป็น Administrator):' -ForegroundColor Yellow
    Write-Host '  Add-WindowsCapability -Online -Name OpenSSH.Client~~~~0.0.1.0' -ForegroundColor Yellow
    exit 1
}

# ---- 2. ssh key ----
# This tool keeps its own key pair. Sharing the user's personal key made a
# broken or unreadable id_ed25519.pub stop the whole run, and there is no
# reason to touch their existing keys at all.
$keyPath = Join-Path $env:USERPROFILE '.ssh\ocr_fleet_ed25519'
$sshDir = Split-Path -Parent $keyPath
if (-not (Test-Path $sshDir)) { New-Item -ItemType Directory -Path $sshDir -Force | Out-Null }

function Read-PublicKey($path) {
    if (-not (Test-Path $path)) { return $null }
    try {
        $bytes = [IO.File]::ReadAllBytes($path)
        if ($bytes.Length -eq 0) { return $null }
        # a .pub written by a redirect can end up UTF-16; decode accordingly
        $text = if ($bytes.Length -gt 1 -and $bytes[0] -eq 0xFF -and $bytes[1] -eq 0xFE) {
            [Text.Encoding]::Unicode.GetString($bytes)
        } else {
            [Text.Encoding]::UTF8.GetString($bytes)
        }
        foreach ($line in ($text -split "[`r`n]+")) {
            $clean = ($line -replace '[^ -~]', '').Trim()
            if ($clean -match '^(ssh-|ecdsa-|sk-)') { return $clean }
        }
    } catch { return $null }
    return $null
}

$pub = Read-PublicKey "$keyPath.pub"
if (-not $pub) {
    if (Test-Path "$keyPath.pub") {
        Write-Host '[1/4] key เดิมของเครื่องมือใช้ไม่ได้ - สร้างใหม่' -ForegroundColor Yellow
        Remove-Item "$keyPath", "$keyPath.pub" -Force -ErrorAction SilentlyContinue
    } else {
        Write-Host '[1/4] สร้าง ssh key สำหรับงานนี้' -ForegroundColor Cyan
    }
    # through cmd: PowerShell 5.1 drops an empty-string argument, so -N "" has
    # to survive as a real pair of quotes for ssh-keygen to see "no passphrase"
    & cmd /c "ssh-keygen -t ed25519 -f `"$keyPath`" -N `"`" -C ocr-fleet-$env:USERNAME" | Out-Null
    $pub = Read-PublicKey "$keyPath.pub"
}

if (-not $pub) {
    Write-Host "สร้าง ssh key ไม่สำเร็จที่ $keyPath" -ForegroundColor Red
    Write-Host 'ลองรันมือ:  ssh-keygen -t ed25519 -f "$env:USERPROFILE\.ssh\ocr_fleet_ed25519" -N ""' -ForegroundColor Yellow
    exit 1
}
Write-Host "[1/4] ใช้ key: $keyPath" -ForegroundColor Cyan

# ---- ตัวช่วยป้อนรหัสให้ ssh อัตโนมัติ ----
# Windows ssh ไม่รับรหัสผ่านทาง command line และไม่มี sshpass
# แต่ OpenSSH 8.4+ มี SSH_ASKPASS_REQUIRE=force ซึ่งบังคับให้ไปถามรหัสจาก
# โปรแกรมภายนอกแทนการพิมพ์ที่หน้าจอ - เลยคอมไพล์โปรแกรมเล็ก ๆ ที่พ่นรหัสออกมา
# (ใช้ csc ที่มากับ .NET Framework ไม่ต้องโหลดอะไรเพิ่ม)
function New-AskPassExe($pass) {
    $exe = Join-Path $env:TEMP 'ocr-askpass.exe'
    $src = @"
using System;
class A { static int Main(string[] args) { Console.WriteLine("$($pass -replace '"','\"')"); return 0; } }
"@
    try {
        if (Test-Path $exe) { Remove-Item $exe -Force -ErrorAction Stop }
        Add-Type -TypeDefinition $src -OutputAssembly $exe -OutputType ConsoleApplication -ErrorAction Stop
        if (Test-Path $exe) { return $exe }
    } catch {
        Write-Host "   (สร้างตัวช่วยป้อนรหัสไม่ได้: $($_.Exception.Message))" -ForegroundColor DarkYellow
    }
    return $null
}

$askPass = New-AskPassExe $Password

# PuTTY's plink takes the password directly; if it happens to be installed it
# is the surest way to avoid typing anything
$plinkExe = (Get-Command plink.exe -ErrorAction SilentlyContinue).Source
if (-not $plinkExe) {
    foreach ($c in @("$env:ProgramFiles\PuTTY\plink.exe", "${env:ProgramFiles(x86)}\PuTTY\plink.exe")) {
        if (Test-Path $c) { $plinkExe = $c; break }
    }
}
$autoPass = [bool]$askPass -or [bool]$plinkExe

# ---- 3. หาว่ากล้องตัวไหนยังเข้าด้วย key ไม่ได้ ----
Write-Host '[2/4] ตรวจว่ากล้องตัวไหนเข้าได้แล้วบ้าง' -ForegroundColor Cyan
$needKey = @()
$reachable = @()
$dead = @()

foreach ($h in $Cameras) {
    $null = & ssh -o BatchMode=yes -o StrictHostKeyChecking=no -o UserKnownHostsFile=NUL `
        -o ConnectTimeout=6 -i $keyPath "$User@$h" 'echo ok' 2>&1
    if ($LASTEXITCODE -eq 0) {
        $reachable += $h
        Write-Host "   $h  เข้าได้ด้วย key แล้ว" -ForegroundColor Green
    } else {
        # แยกระหว่าง "ยังไม่มี key" กับ "ติดต่อเครื่องไม่ได้เลย"
        $ping = Test-Connection -ComputerName $h -Count 1 -Quiet -ErrorAction SilentlyContinue
        if ($ping) {
            $needKey += $h
            Write-Host "   $h  ต้องติดตั้ง key" -ForegroundColor Yellow
        } else {
            $dead += $h
            Write-Host "   $h  ติดต่อไม่ได้ (ปิดอยู่ / คนละวง / IP เปลี่ยน)" -ForegroundColor Red
        }
    }
}

# ---- 4. ติดตั้ง key ให้ตัวที่ยังไม่มี ----
if ($needKey.Count -gt 0) {
    Write-Host ''
    $how = if ($plinkExe) { 'ป้อนรหัสอัตโนมัติผ่าน plink' }
           elseif ($askPass) { 'ป้อนรหัสให้อัตโนมัติ' }
           else { "ต้องพิมพ์รหัส '$Password' ตัวละครั้ง" }
    Write-Host "[3/4] ติดตั้ง key $($needKey.Count) ตัว - $how" -ForegroundColor Cyan
    $cmd = "mkdir -p ~/.ssh; chmod 700 ~/.ssh; echo '$pub' >> ~/.ssh/authorized_keys; sort -u -o ~/.ssh/authorized_keys ~/.ssh/authorized_keys; chmod 600 ~/.ssh/authorized_keys; echo KEY_OK"
    $sshOpts = @('-o', 'StrictHostKeyChecking=no', '-o', 'UserKnownHostsFile=NUL',
                 '-o', 'ConnectTimeout=10', '-o', 'NumberOfPasswordPrompts=1',
                 '-o', 'PubkeyAuthentication=no', '-o', 'PreferredAuthentications=password,keyboard-interactive')

    foreach ($h in $needKey) {
        Write-Host "   -> $h" -ForegroundColor Cyan
        $installed = $false

        if ($plinkExe) {
            # -batch so it never stops on a host-key question
            $out = & $plinkExe -ssh -batch -pw $Password "$User@$h" $cmd 2>&1 | Out-String
            if ($out -match 'KEY_OK') { $installed = $true }
            elseif ($out -match 'host key is not cached|store key in cache') {
                # accept the key once, then retry
                'y' | & $plinkExe -ssh -pw $Password "$User@$h" 'echo cached' 2>&1 | Out-Null
                $out = & $plinkExe -ssh -batch -pw $Password "$User@$h" $cmd 2>&1 | Out-String
                if ($out -match 'KEY_OK') { $installed = $true }
            }
        }

        if (-not $installed -and $askPass) {
            $env:SSH_ASKPASS = $askPass
            $env:SSH_ASKPASS_REQUIRE = 'force'
            $env:DISPLAY = 'localhost:0'
            $out = & ssh @sshOpts "$User@$h" $cmd 2>&1 | Out-String
            Remove-Item Env:SSH_ASKPASS, Env:SSH_ASKPASS_REQUIRE, Env:DISPLAY -ErrorAction SilentlyContinue
            if ($out -match 'KEY_OK') {
                $installed = $true
            } elseif ($h -eq $needKey[0]) {
                # the first camera decides whether this machine can do it at all
                Write-Host '      ป้อนรหัสอัตโนมัติไม่ได้บนเครื่องนี้ - จะขอให้พิมพ์เอง' -ForegroundColor DarkYellow
                if (-not $plinkExe) {
                    Write-Host '      (ทางเลือก: winget install PuTTY.PuTTY แล้วรันใหม่ จะไม่ต้องพิมพ์เลย)' -ForegroundColor DarkYellow
                }
                $askPass = $null
            }
        }

        if (-not $installed) {
            # last resort: let ssh ask on screen
            & ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=NUL -o ConnectTimeout=10 "$User@$h" $cmd
            if ($LASTEXITCODE -eq 0) { $installed = $true }
        }

        if ($installed) {
            $reachable += $h
            Write-Host "      ติดตั้ง key แล้ว" -ForegroundColor Green
        } else {
            Write-Host "      ไม่สำเร็จ - ข้ามตัวนี้ไปก่อน" -ForegroundColor Red
            $dead += $h
        }
    }
} else {
    Write-Host '[3/4] ไม่ต้องติดตั้ง key เพิ่ม' -ForegroundColor Cyan
}

if ($reachable.Count -eq 0) {
    Write-Host ''
    Write-Host 'ไม่มีกล้องที่เข้าถึงได้เลย - ตรวจสายแลน/วงเน็ตก่อน' -ForegroundColor Red
    exit 1
}

# ---- 5. เคลียร์ ----
Write-Host ''
$what = if ($ReportOnly) { 'ดูอย่างเดียว' } else { 'เคลียร์พื้นที่' }
Write-Host "[4/4] $what $($reachable.Count) ตัว (ครั้งละ $Jobs)" -ForegroundColor Cyan
Write-Host ''

$opts = @{
    Hosts        = $reachable
    User         = $User
    Jobs         = $Jobs
    IdentityFile = $keyPath
}
if ($ReportOnly) {
    $opts['Report'] = $true
} else {
    $opts['SudoPass'] = $Password
    if ($ImagesDays -gt 0) { $opts['ImagesDays'] = $ImagesDays }
    if ($Restart) { $opts['Restart'] = $true }
}

& $cleaner @opts

if ($dead.Count -gt 0) {
    Write-Host ''
    Write-Host "กล้องที่ทำไม่ได้ $($dead.Count) ตัว: $($dead -join ', ')" -ForegroundColor Yellow
}
if ($askPass) { Remove-Item $askPass -Force -ErrorAction SilentlyContinue }

Write-Host ''
if (-not $ReportOnly) {
    Write-Host 'เสร็จแล้ว - กล้องที่เคลียร์ไปจะมี pm2-logrotate คุมขนาด log ไว้ ไม่กลับมาเต็มอีก' -ForegroundColor Green
}
