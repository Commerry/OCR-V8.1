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
$keyPath = Join-Path $env:USERPROFILE '.ssh\id_ed25519'
if (-not (Test-Path "$keyPath.pub")) {
    Write-Host '[1/4] สร้าง ssh key ใหม่' -ForegroundColor Cyan
    $sshDir = Split-Path -Parent $keyPath
    if (-not (Test-Path $sshDir)) { New-Item -ItemType Directory -Path $sshDir -Force | Out-Null }
    & ssh-keygen -t ed25519 -N '""' -f $keyPath -C "ocr-fleet-$env:USERNAME" | Out-Null
} else {
    Write-Host '[1/4] มี ssh key อยู่แล้ว' -ForegroundColor Cyan
}

$pub = ((Get-Content "$keyPath.pub" -TotalCount 1) -join '').Trim()
$pub = ($pub -replace '[^\x20-\x7E]', '')
if ($pub -notmatch '^ssh-') {
    Write-Host "อ่าน public key ไม่ได้จาก $keyPath.pub" -ForegroundColor Red
    exit 1
}

# ---- 3. หาว่ากล้องตัวไหนยังเข้าด้วย key ไม่ได้ ----
Write-Host '[2/4] ตรวจว่ากล้องตัวไหนเข้าได้แล้วบ้าง' -ForegroundColor Cyan
$needKey = @()
$reachable = @()
$dead = @()

foreach ($h in $Cameras) {
    $null = & ssh -o BatchMode=yes -o StrictHostKeyChecking=no -o UserKnownHostsFile=NUL `
        -o ConnectTimeout=6 "$User@$h" 'echo ok' 2>&1
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
    Write-Host "[3/4] ติดตั้ง key $($needKey.Count) ตัว - ใส่รหัส '$Password' ตัวละครั้ง" -ForegroundColor Cyan
    $cmd = "mkdir -p ~/.ssh; chmod 700 ~/.ssh; echo '$pub' >> ~/.ssh/authorized_keys; sort -u -o ~/.ssh/authorized_keys ~/.ssh/authorized_keys; chmod 600 ~/.ssh/authorized_keys; echo KEY_OK"
    foreach ($h in $needKey) {
        Write-Host "   -> $h" -ForegroundColor Cyan
        & ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=NUL -o ConnectTimeout=10 "$User@$h" $cmd
        if ($LASTEXITCODE -eq 0) {
            $reachable += $h
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
    Hosts = $reachable
    User  = $User
    Jobs  = $Jobs
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
Write-Host ''
if (-not $ReportOnly) {
    Write-Host 'เสร็จแล้ว - กล้องที่เคลียร์ไปจะมี pm2-logrotate คุมขนาด log ไว้ ไม่กลับมาเต็มอีก' -ForegroundColor Green
}
