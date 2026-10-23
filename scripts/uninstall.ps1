# Stops and removes the AudioShareServer Windows service.
#
# From a release folder:  right-click uninstall.cmd -> Run as administrator
# From the repo:          powershell -ExecutionPolicy Bypass -File scripts\uninstall.ps1
[CmdletBinding()]
param(
    [string]$ServiceName = 'AudioShareServer',
    [string]$InstallDir = 'C:\Services\audio-share',
    [switch]$RemoveFiles,
    [switch]$KeepFirewallRules,
    [switch]$NoElevate
)

$ErrorActionPreference = 'Stop'

function Test-Admin {
    $id = [Security.Principal.WindowsIdentity]::GetCurrent()
    return (New-Object Security.Principal.WindowsPrincipal($id)).IsInRole(
        [Security.Principal.WindowsBuiltInRole]::Administrator)
}

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

$svc = Get-Service -Name $ServiceName -ErrorAction SilentlyContinue
if ($svc) {
    if ($svc.Status -ne 'Stopped') {
        Write-Host "停止服务 $ServiceName ..."
        Stop-Service -Name $ServiceName -Force -ErrorAction SilentlyContinue
        try { $svc.WaitForStatus('Stopped', '00:00:20') } catch { }
    }
    Write-Host "删除服务 $ServiceName ..."
    & sc.exe delete $ServiceName | Out-Null
    Start-Sleep -Seconds 1
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
    foreach ($name in @(
            "Audio Share Server TCP $serverPort",
            "Audio Share Server UDP $serverPort",
            "Audio Share Server Discovery UDP $($serverPort + 1)")) {
        if (Get-NetFirewallRule -DisplayName $name -ErrorAction SilentlyContinue) {
            Remove-NetFirewallRule -DisplayName $name
            Write-Host "已删除防火墙规则: $name"
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
