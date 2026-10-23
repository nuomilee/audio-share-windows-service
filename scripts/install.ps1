# Installs AudioShareServer as an auto-start Windows service.
#
# From a release folder:  right-click install.cmd -> Run as administrator
# From the repo:          powershell -ExecutionPolicy Bypass -File scripts\install.ps1
#
# Compatible with Windows 7 SP1+ (PowerShell 3.0+) and Windows 10/11.
# Firewall rules use netsh, so the NetSecurity module is not required.
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

$self = $MyInvocation.MyCommand.Path
$scriptDir = Split-Path -Parent $self

function Test-Admin {
    try {
        $id = [Security.Principal.WindowsIdentity]::GetCurrent()
        $principal = New-Object Security.Principal.WindowsPrincipal -ArgumentList $id
        return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
    } catch {
        return $false
    }
}

# ---------- self elevation ----------
if (-not (Test-Admin) -and -not $NoElevate) {
    $argList = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-NoExit', '-File', ('"' + $self + '"'))
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
    throw '请用管理员身份运行本脚本。'
}

# ---------- runtime check ----------
$ndp = Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\NET Framework Setup\NDP\v4\Full' -ErrorAction SilentlyContinue
if (-not $ndp -or $ndp.Release -lt 378389) {
    throw '.NET Framework 4.5 或更高版本未安装。请先安装 .NET Framework 4.8，再重新运行安装。'
}

# ---------- resolve the payload ----------
if (-not $Payload) {
    $parent = Split-Path -Parent $scriptDir
    $candidates = @(
        (Join-Path $scriptDir 'payload'),
        (Join-Path $parent 'dist\payload')
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
    Write-Host '发现已安装的服务，先停止并删除 ...'
    if ($existing.Status -ne 'Stopped') {
        Stop-Service -Name $ServiceName -Force -ErrorAction SilentlyContinue
        try { $existing.WaitForStatus('Stopped', '00:00:20') } catch { }
    }
    & sc.exe delete $ServiceName | Out-Null
    $deadline = (Get-Date).AddSeconds(10)
    while ((Get-Service -Name $ServiceName -ErrorAction SilentlyContinue) -and (Get-Date) -lt $deadline) {
        Start-Sleep -Milliseconds 300
    }
}

# ---------- copy files ----------
New-Item -ItemType Directory -Force -Path $InstallDir | Out-Null
Get-ChildItem -Path $Payload | Where-Object { -not $_.PSIsContainer } | ForEach-Object {
    if ($_.Name -eq 'settings.ini' -and (Test-Path (Join-Path $InstallDir 'settings.ini'))) {
        Write-Host '保留已有 settings.ini（删除它可恢复默认配置）'
        return
    }
    Copy-Item -LiteralPath $_.FullName -Destination (Join-Path $InstallDir $_.Name) -Force
}
New-Item -ItemType Directory -Force -Path (Join-Path $InstallDir 'logs') | Out-Null

$hostExe = Join-Path $InstallDir 'AudioShareService.exe'
$asCmdExe = Join-Path $InstallDir 'as-cmd.exe'

# ---------- parse the configured port ----------
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

# ---------- refuse to fight an old instance ----------
function Get-ListenerPid([int]$port) {
    $rows = & netstat -ano -p tcp 2>$null
    foreach ($row in $rows) {
        if ($row -match 'LISTENING' -and $row -match (':' + $port + '\s')) {
            $parts = ($row.Trim() -split '\s+')
            $last = $parts[$parts.Length - 1]
            if ($last -match '^\d+$') { return [int]$last }
        }
    }
    return 0
}

if (-not $Force) {
    $ownerPid = Get-ListenerPid $serverPort
    if ($ownerPid -gt 0) {
        $procName = (Get-Process -Id $ownerPid -ErrorAction SilentlyContinue).ProcessName
        throw "端口 $serverPort 已被占用（$procName，PID $ownerPid）。请先关闭旧的 as-cmd / cmd 窗口，释放端口后重试。"
    }
}

# ---------- firewall (netsh: works on Windows 7 through 11) ----------
function Set-FirewallRules([string]$program, [int]$port) {
    if (-not (Get-Command netsh.exe -ErrorAction SilentlyContinue)) {
        Write-Warning '未找到 netsh，跳过防火墙配置'
        return
    }
    $rules = @(
        @{ Name = "Audio Share Server TCP $port"; Protocol = 'TCP'; Port = $port },
        @{ Name = "Audio Share Server UDP $port"; Protocol = 'UDP'; Port = $port },
        @{ Name = "Audio Share Server Discovery UDP $($port + 1)"; Protocol = 'UDP'; Port = $port + 1 }
    )
    foreach ($r in $rules) {
        & netsh advfirewall firewall delete rule "name=$($r.Name)" | Out-Null
        $prev = $ErrorActionPreference
        $ErrorActionPreference = 'Continue'
        $output = & netsh advfirewall firewall add rule "name=$($r.Name)" dir=in action=allow `
            "protocol=$($r.Protocol)" "localport=$($r.Port)" "program=$program" profile=any enable=yes 2>&1
        $code = $LASTEXITCODE
        $ErrorActionPreference = $prev
        if ($code -ne 0) {
            Write-Warning ("防火墙规则添加失败：{0}（{1}）" -f $r.Name, ($output -join ' '))
        } else {
            Write-Host "防火墙规则: $($r.Name)"
        }
    }
}

if (-not $SkipFirewall) {
    Set-FirewallRules $asCmdExe $serverPort
}

# ---------- register the service ----------
Write-Host '注册服务 ...'
New-Service -Name $ServiceName `
    -BinaryPathName ('"' + $hostExe + '"') `
    -DisplayName $DisplayName `
    -StartupType Automatic | Out-Null

& sc.exe description $ServiceName 'Shares the default Windows audio endpoint with the Audio Share Android app (as-cmd).' | Out-Null
& sc.exe config $ServiceName depend= Audiosrv | Out-Null
& sc.exe failure $ServiceName reset= 86400 actions= restart/5000/restart/10000/restart/30000 | Out-Null

# ---------- start and verify ----------
$log = Join-Path $InstallDir ('logs\as-cmd-' + (Get-Date -Format 'yyyyMMdd') + '.log')
$offset = 0
if (Test-Path $log) { $offset = (Get-Item $log).Length }

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
        $reader = New-Object IO.StreamReader -ArgumentList $fs, ([Text.Encoding]::UTF8)
        $newText = $reader.ReadToEnd()
    } finally {
        $fs.Dispose()
    }
    if ($newText -match 'server started') { $started = $true; break }
    if ($newText -match 'bind:') { break }
}

$svc = Get-Service -Name $ServiceName

Write-Host ''
$svc | Select-Object Name, DisplayName, Status, StartType | Format-List
Write-Host ("监听端口 : {0} (TCP/UDP)，发现端口 UDP {1}" -f $serverPort, ($serverPort + 1))
Write-Host ("日志文件 : {0}" -f $log)
Write-Host ''

if (Test-Path $log) {
    Write-Host '--- 日志末尾 ---'
    Get-Content -LiteralPath $log -Encoding UTF8 | Select-Object -Last 25
}

if ($svc.Status -ne 'Running') {
    throw "服务未正常启动（状态 $($svc.Status)）。请查看上面的日志；常见原因是端口被占用或音频设备不可用。"
}
if (-not $started) {
    Write-Warning '服务已运行，但 20 秒内没有在日志里看到 server started，请检查上面的日志确认音频设备。'
} else {
    Write-Host ''
    Write-Host 'OK: AudioShareServer 已安装并运行，开机自动启动。'
    Write-Host '下一步：用手机 App 连接本机 IP:端口；如需换设备/参数，编辑 settings.ini 后 Restart-Service AudioShareServer。'
}
