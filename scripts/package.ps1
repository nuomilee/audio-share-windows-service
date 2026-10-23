# Builds a self-contained release folder and zip under dist\.
# The release can be copied to another Windows machine and installed with install.cmd.
param(
    [string]$Version = '1.0.0'
)

$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$name = "audio-share-service-$Version"
$dist = Join-Path $root 'dist'
$pkg = Join-Path $dist $name
$payload = Join-Path $pkg 'payload'

& (Join-Path $PSScriptRoot 'build.ps1') | Out-Host

if (Test-Path $pkg) { Remove-Item -LiteralPath $pkg -Recurse -Force }
New-Item -ItemType Directory -Force -Path $payload | Out-Null

Copy-Item (Join-Path $root 'build\AudioShareService.exe') $payload -Force
Copy-Item (Join-Path $root 'vendor\as-cmd.exe') $payload -Force
Copy-Item (Join-Path $root 'vendor\LICENSE') (Join-Path $payload 'LICENSE-as-cmd.txt') -Force
Copy-Item (Join-Path $root 'config\settings.ini') $payload -Force

Copy-Item (Join-Path $PSScriptRoot 'install.ps1') $pkg -Force
Copy-Item (Join-Path $PSScriptRoot 'uninstall.ps1') $pkg -Force
Copy-Item (Join-Path $PSScriptRoot 'install.cmd') $pkg -Force
Copy-Item (Join-Path $PSScriptRoot 'uninstall.cmd') $pkg -Force
Copy-Item (Join-Path $root 'docs\deployment.md') (Join-Path $pkg 'README.md') -Force
Copy-Item (Join-Path $root 'docs\configuration.md') $pkg -Force
Copy-Item (Join-Path $root 'docs\troubleshooting.md') $pkg -Force

$zip = Join-Path $dist "$name-win64.zip"
if (Test-Path $zip) { Remove-Item -LiteralPath $zip -Force }
Compress-Archive -Path (Join-Path $pkg '*') -DestinationPath $zip -CompressionLevel Optimal

Write-Host ''
Write-Host "Release folder : $pkg"
Write-Host "Release zip    : $zip"
Get-ChildItem $pkg -Recurse -File | Select-Object FullName, Length |
    Format-Table -AutoSize | Out-String -Width 200 | Write-Host
