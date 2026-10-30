[CmdletBinding()]
param(
    [string]$Flutter = 'flutter',
    [string]$Dart = 'dart',
    [string]$Dotnet = 'dotnet'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
if (!$IsWindows) { throw 'Windows x64 build required.' }
$taskRoot = (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot '../..')).ProviderPath
$taskBuild = Join-Path $taskRoot 'build/windows/x64/runner/Debug'
$taskApp = Join-Path $taskBuild 'shiroha_quiz.exe'
$running = @(Get-Process -Name shiroha_quiz -ErrorAction SilentlyContinue |
    Where-Object { $_.Path -eq $taskApp })
if ($running.Count -gt 0) { throw 'Close this Shiroha build normally before rebuilding it.' }

Push-Location -LiteralPath $taskRoot
try {
    & $Flutter build windows --debug --no-pub
    if ($LASTEXITCODE -ne 0) { throw 'Windows App build failed.' }
    & $Dart compile exe tool/external/codex_relay_candidate.dart -o (Join-Path $taskBuild 'shiroha_codex.exe')
    if ($LASTEXITCODE -ne 0) { throw 'Codex adapter build failed.' }
    & $Dart compile exe tool/external/bridge_candidate.dart -o (Join-Path $taskBuild 'shiroha_bridge.exe')
    if ($LASTEXITCODE -ne 0) { throw 'Windows Bridge build failed.' }
    $taskAndroid = Join-Path $taskRoot 'build/plugin_runtime/android'
    & $Dotnet publish tool/android_device_adapter/AndroidDeviceAdapter.csproj --configuration Debug --no-restore --output $taskAndroid --nologo
    if ($LASTEXITCODE -ne 0) { throw 'Android adapter build failed.' }
    foreach ($name in @('AndroidDeviceAdapter.exe', 'AndroidDeviceAdapter.dll', 'AndroidDeviceAdapter.deps.json', 'AndroidDeviceAdapter.runtimeconfig.json')) {
        Copy-Item -LiteralPath (Join-Path $taskAndroid $name) -Destination (Join-Path $taskBuild $name)
    }
    Write-Output 'Built the local App and adjacent adapters. No App, credential or business connection was started.'
} finally {
    Pop-Location
}
