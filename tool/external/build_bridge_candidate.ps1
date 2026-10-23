param(
    [Parameter(Mandatory = $true)][string]$CMake,
    [string]$Dart = 'dart'
)
$ErrorActionPreference = 'Stop'
if ([Environment]::OSVersion.Platform -ne [PlatformID]::Win32NT) { throw 'Windows x64 build required' }
$root = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../..'))
$output = Join-Path $root '.dart_tool/ar-r6b-integration'
New-Item -ItemType Directory -Force -Path $output | Out-Null
Push-Location $root
try {
    # Build only the original production DLL; no diagnostic or security run.
    & $CMake -S windows/external_native -B "$output/native" -A x64
    if ($LASTEXITCODE -ne 0) { throw 'Native configure failed' }
    & $CMake --build "$output/native" --config Release --target shiroha_external_native
    if ($LASTEXITCODE -ne 0) { throw 'Native build failed' }
    & $Dart compile exe tool/external/bridge_candidate.dart -o "$output/shiroha_bridge.exe"
    if ($LASTEXITCODE -ne 0) { throw 'Bridge AOT build failed' }
    Copy-Item -LiteralPath "$output/native/Release/shiroha_external_native.dll" -Destination $output
    Write-Output 'BUILT: fixed-name Bridge AOT and Native DLL; not loaded, activated or admitted.'
} finally {
    Pop-Location
}
