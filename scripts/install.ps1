# Installs AudioShareServer as an auto-start Windows service.
#
# From a release folder:  right-click install.cmd -> Run as administrator
# From the repo:          powershell -ExecutionPolicy Bypass -File scripts\install.ps1
#
# The script copies the payload, opens the firewall, registers the service,
# starts it and waits until as-cmd reports "server started" in the log.
[CmdletBinding()]
param(
    [string]$InstallDir = 'C:\Services\audio-share',
    [string]$ServiceName = 'AudioShareServer',
    [string]$DisplayName = 'Audio Share Server (as-cmd)',
    [string]$Payload,
    [switch]$SkipFirewall,
    [switch]$Force,
    [switch]$NoElevate
)

$ErrorActionPreference = 'Stop'

function Test-Admin {
    $id = [Security.Principal.WindowsIdentity]::GetCurrent()
    return (New-Object Security.Principal.WindowsPrincipal($id)).IsInRole(
        [Security.Principal.WindowsBuiltInRole]::Administrator)
}

# ---------- self elevation ----------
if (-not (Test-Admin) -and -not $NoElevate) {
    $argList = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-NoExit', '-File', ('"' + $PSCommandPath + '"'))
    foreach ($kv in $PSBoundParameters.GetEnumerator()) {
        if ($kv.Value -is [switch]) {
            if ($kv.Value.IsPresent) { $argList += ('-' + $kv.Key) }
            continue
        }
        $argList += @(('-' + $kv.Key), ('"' + [string]$kv.Value + '"'))
    }
    Write-Host '需要管理员权限，正在重新以管理员身份启动...'
    Start-Process -FilePath 'powershell.exe' -Verb RunAs -ArgumentList $argList
    return
}
if (-not (Test-Admin)) {
    throw 'Please run this script from an elevated (Administrator) PowerShell.'
}

# ---------- resolve the payload ----------
if (-not $Payload) {
    $candidates = @(
        (Join-Path $PSScriptRoot 'payload'),
        (Join-Path (Split-Path -Parent $PSScriptRoot) 'dist\payload')
    )
    $Payload = $candidates | Where-Object {
        (Test-Path (Join-Path $_ 'as-cmd.exe')) -and (Test-Path (Join-Path $_ 'AudioShareService.exe'))
    } | Select-Object -First 1
}
if (-not $Payload) {
    throw '找不到安装文件（payload 目录）。请在发布包目录运行 install.cmd，或先执行 scripts\package.ps1。'
}

$payloadAsCmd = Join-Path $Payload 'as-cmd.exe'
$payloadHost = Join-Path $Payload 'AudioShareService.exe'
if (-not (Test-Path $payloadAsCmd) -or -not (Test-Path $payloadHost)) {
    throw "payload 不完整：$Payload（需要 as-cmd.exe 和 AudioShareService.exe）"
}

Write-Host "安装目录 : $InstallDir"
Write-Host "安装来源 : $Payload"
Write-Host "服务名称 : $ServiceName"

# ---------- remove previous installation (logs and settings are kept) ----------
$existing = Get-Service -Name $ServiceName -ErrorAction SilentlyContinue
if ($existing) {
    Write-Host "发现已安装的服务，先停止并删除 ..."
    if ($existing.Status -ne 'Stopped') {
        Stop-Service -Name $ServiceName -Force -ErrorAction SilentlyContinue
        try { $existing.WaitForStatus('Stopped', '00:00:20') } catch { }
    }
    & sc.exe delete $ServiceName | Out-Null
    Start-Sleep -Seconds 1
}

# ---------- copy files ----------
New-Item -ItemType Directory -Force -Path $InstallDir | Out-Null
Get-ChildItem -Path $Payload -File | ForEach-Object {
    if ($_.Name -eq 'settings.ini' -and (Test-Path (Join-Path $InstallDir 'settings.ini'))) {
        Write-Host '保留已有 settings.ini（删除它可恢复默认配置）'
        return
    }
    Copy-Item -LiteralPath $_.FullName -Destination (Join-Path $InstallDir $_.Name) -Force
}
New-Item -ItemType Directory -Force -Path (Join-Path $InstallDir 'logs') | Out-Null

$hostExe = Join-Path $InstallDir 'AudioShareService.exe'
$asCmdExe = Join-Path $InstallDir 'as-cmd.exe'

# ---------- parse the configured port, refuse to fight an old instance ----------
$serverPort = 65530
$ini = Join-Path $InstallDir 'settings.ini'
if (Test-Path $ini) {
    foreach ($line in Get-Content -LiteralPath $ini -Encoding UTF8) {
        if ($line -match '^\s*args\s*=\s*(.+)$') {
            $m = [regex]::Match($matches[1], ':(\d{2,5})')
            if ($m.Success) { $serverPort = [int]$m.Groups[1].Value }
            break
        }
    }
}

if (-not $Force) {
    $busy = Get-NetTCPConnection -State Listen -LocalPort $serverPort -ErrorAction SilentlyContinue |
        Select-Object -First 1
    if ($busy) {
        $proc = (Get-Process -Id $busy.OwningProcess -ErrorAction SilentlyContinue).ProcessName
        throw "端口 $serverPort 已被占用（$proc，PID $($busy.OwningProcess)）。请先关闭旧的 as-cmd / cmd 窗口，释放端口后重试。"
    }
}

# ---------- firewall ----------
if (-not $SkipFirewall) {
    $rules = @(
        @{ Name = "Audio Share Server TCP $serverPort"; Protocol = 'TCP'; Port = $serverPort },
        @{ Name = "Audio Share Server UDP $serverPort"; Protocol = 'UDP'; Port = $serverPort },
        @{ Name = "Audio Share Server Discovery UDP $($serverPort + 1)"; Protocol = 'UDP'; Port = $serverPort + 1 }
    )
    foreach ($r in $rules) {
        if (-not (Get-NetFirewallRule -DisplayName $r.Name -ErrorAction SilentlyContinue)) {
            New-NetFirewallRule -DisplayName $r.Name -Direction Inbound -Action Allow `
                -Protocol $r.Protocol -LocalPort $r.Port -Program $asCmdExe -Profile Any | Out-Null
            Write-Host "防火墙规则: $($r.Name)"
        }
    }
}

# ---------- register the service ----------
Write-Host '注册服务 ...'
New-Service -Name $ServiceName `
    -BinaryPathName $hostExe `
    -DisplayName $DisplayName `
    -Description 'Shares the default Windows audio endpoint with the Audio Share Android app (as-cmd).' `
    -StartupType Automatic | Out-Null

# audio must be ready before we capture from it; restart automatically on crash
& sc.exe config $ServiceName depend= Audiosrv | Out-Null
& sc.exe failure $ServiceName reset= 86400 actions= restart/5000/restart/10000/restart/30000 | Out-Null

# ---------- start and verify ----------
$log = Join-Path $InstallDir ('logs\as-cmd-' + (Get-Date -Format 'yyyyMMdd') + '.log')
$offset = if (Test-Path $log) { (Get-Item $log).Length } else { 0 }

Write-Host '启动服务 ...'
Start-Service -Name $ServiceName
$svc = Get-Service -Name $ServiceName
try { $svc.WaitForStatus('Running', '00:00:20') } catch { }

$started = $false
$deadline = (Get-Date).AddSeconds(20)
while ((Get-Date) -lt $deadline) {
    Start-Sleep -Milliseconds 500
    if (-not (Test-Path $log)) { continue }
    $fs = [IO.File]::Open($log, 'Open', 'Read', 'ReadWrite')
    try {
        [void]$fs.Seek($offset, 'Begin')
        $reader = New-Object IO.StreamReader($fs, [Text.Encoding]::UTF8)
        $newText = $reader.ReadToEnd()
    } finally {
        $fs.Dispose()
    }
    if ($newText -match 'server started') { $started = $true; break }
    if ($newText -match 'bind:') { break }   # as-cmd failed to bind
}

$svc = Get-Service -Name $ServiceName

Write-Host ''
$svc | Select-Object Name, DisplayName, Status, StartType | Format-List
Write-Host ("监听端口 : {0} (TCP/UDP)，发现端口 UDP {1}" -f $serverPort, ($serverPort + 1))
Write-Host ("日志文件 : {0}" -f $log)
Write-Host ''

if (Test-Path $log) {
    Write-Host '--- 日志末尾 ---'
    Get-Content -LiteralPath $log -Encoding UTF8 -Tail 25
}

if (-not $started -or $svc.Status -ne 'Running') {
    throw "服务未正常启动（状态 $($svc.Status)）。请查看上面的日志；常见原因是端口被占用或音频设备不可用。"
}

Write-Host ''
Write-Host 'OK: AudioShareServer 已安装并运行，开机自动启动。'
Write-Host '下一步：用手机 App 连接本机 IP:端口；如需换设备/参数，编辑 settings.ini 后 Restart-Service AudioShareServer。'
