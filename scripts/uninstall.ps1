# Stops and removes the AudioShareServer Windows service.
#
# From a release folder:  right-click uninstall.cmd -> Run as administrator
# From the repo:          powershell -ExecutionPolicy Bypass -File scripts\uninstall.ps1
#
# Compatible with Windows 7 SP1+ (PowerShell 3.0+) and Windows 10/11.
[CmdletBinding()]
param(
    [string]$ServiceName = 'AudioShareServer',
    [string]$InstallDir = 'C:\Services\audio-share',
    [switch]$RemoveFiles,
    [switch]$KeepFirewallRules,
    [switch]$NoElevate
)

$ErrorActionPreference = 'Stop'

$self = $MyInvocation.MyCommand.Path

function Test-Admin {
    try {
        $id = [Security.Principal.WindowsIdentity]::GetCurrent()
        $principal = New-Object Security.Principal.WindowsPrincipal -ArgumentList $id
        return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
    } catch {
        return $false
    }
}

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

$svc = Get-Service -Name $ServiceName -ErrorAction SilentlyContinue
if ($svc) {
    if ($svc.Status -ne 'Stopped') {
        Write-Host "停止服务 $ServiceName ..."
        Stop-Service -Name $ServiceName -Force -ErrorAction SilentlyContinue
        try { $svc.WaitForStatus('Stopped', '00:00:20') } catch { }
    }
    Write-Host "删除服务 $ServiceName ..."
    & sc.exe delete $ServiceName | Out-Null
    $deadline = (Get-Date).AddSeconds(10)
    while ((Get-Service -Name $ServiceName -ErrorAction SilentlyContinue) -and (Get-Date) -lt $deadline) {
        Start-Sleep -Milliseconds 300
    }
} else {
    Write-Host "服务 $ServiceName 未安装。"
}

if (-not $KeepFirewallRules) {
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
    if (Get-Command netsh.exe -ErrorAction SilentlyContinue) {
        foreach ($name in @(
                "Audio Share Server TCP $serverPort",
                "Audio Share Server UDP $serverPort",
                "Audio Share Server Discovery UDP $($serverPort + 1)")) {
            & netsh advfirewall firewall delete rule "name=$name" | Out-Null
            if ($LASTEXITCODE -eq 0) {
                Write-Host "已删除防火墙规则: $name"
            }
        }
    }
}

if ($RemoveFiles) {
    if (Test-Path $InstallDir) {
        Write-Host "删除目录 $InstallDir ..."
        Remove-Item -LiteralPath $InstallDir -Recurse -Force
    }
} else {
    Write-Host "程序文件保留在 $InstallDir（加 -RemoveFiles 可一并删除）。"
}
