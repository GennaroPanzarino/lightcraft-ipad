# Installs the tethering build of LightCraft for this user: the release build plus Sony's Camera
# Remote SDK files beside it (the SDK looks for CrAdapter\ next to the executable), and a desktop
# shortcut "LightCraft Tethering". Run after `cargo build --release -p lightcraft`.
param(
    [string]$Sdk = "C:\Users\gennaro\Progetti\CrSDK_v2.02.00\SimpleCli\external\crsdk",
    [string]$Dest = "$env:LOCALAPPDATA\Programs\LightCraft Tethering"
)
$ErrorActionPreference = "Stop"
$repo = $PSScriptRoot
$exe = Join-Path $repo "target\release\lightcraft.exe"
if (-not (Test-Path $exe)) { throw "Build first: cargo build --release -p lightcraft" }
if (-not (Test-Path (Join-Path $Sdk "Cr_Core.dll"))) { throw "Sony SDK not found in $Sdk" }
New-Item -ItemType Directory -Force $Dest | Out-Null
Copy-Item $exe $Dest -Force
$cli = Join-Path $repo "target\release\lightcraft-cli.exe"
if (Test-Path $cli) { Copy-Item $cli $Dest -Force }
Copy-Item (Join-Path $Sdk "*.dll") $Dest -Force
Copy-Item (Join-Path $Sdk "CrAdapter") $Dest -Recurse -Force
$ws = New-Object -ComObject WScript.Shell
$lnk = $ws.CreateShortcut((Join-Path ([Environment]::GetFolderPath('Desktop')) "LightCraft Tethering.lnk"))
$lnk.TargetPath = Join-Path $Dest "lightcraft.exe"
$lnk.WorkingDirectory = $Dest
$lnk.IconLocation = (Join-Path $Dest "lightcraft.exe") + ",0"
$lnk.Description = "LightCraft with tethered capture (Sony, camera Wi-Fi)"
$lnk.Save()
Write-Output "Installed in $Dest"
