# Builds the service host (AudioShareService.exe) with the .NET Framework compiler
# that ships with Windows. No SDK / NuGet / internet access required.
param(
    [string]$Configuration = 'Release'
)

$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$source = Join-Path $root 'src\AudioShareService.cs'
$outDir = Join-Path $root 'build'

$csc = Join-Path $env:WINDIR 'Microsoft.NET\Framework64\v4.0.30319\csc.exe'
if (-not (Test-Path $csc)) {
    $csc = Join-Path $env:WINDIR 'Microsoft.NET\Framework\v4.0.30319\csc.exe'
}
if (-not (Test-Path $csc)) {
    throw 'csc.exe (.NET Framework 4.x) not found. Windows 10/11 should ship it.'
}

New-Item -ItemType Directory -Force -Path $outDir | Out-Null
$out = Join-Path $outDir 'AudioShareService.exe'

& $csc /nologo /target:exe /platform:anycpu /optimize+ `
    "/out:$out" /r:System.ServiceProcess.dll $source

if ($LASTEXITCODE -ne 0) {
    throw "compile failed, exit code $LASTEXITCODE"
}

Get-Item $out | Select-Object FullName, Length, LastWriteTime | Format-List
