param(
  [Parameter(Mandatory=$true)][string]$DartExecutable,
  [Parameter(Mandatory=$true)][string]$CmakeExecutable,
  [Parameter(Mandatory=$true)][string]$OutputDirectory,
  [switch]$IncludeWindowsClient
)
$ErrorActionPreference = 'Stop'
$taskRoot = (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot '../..')).ProviderPath
$taskOutput = [IO.Path]::GetFullPath($OutputDirectory)
if (Test-Path -LiteralPath $taskOutput) { throw 'Choose a new version directory; never replace an in-use runtime.' }
New-Item -ItemType Directory -Path $taskOutput | Out-Null
Push-Location -LiteralPath $taskRoot
try {
  $taskEntries = [ordered]@{link='shiroha_link'; frontend='shiroha'; control='shiroha_link_control'; initialize_state='shiroha_link_initialize'}
  if ($IncludeWindowsClient) { $taskEntries['windows_client']='shiroha_codex'; $taskEntries['windows_bridge']='shiroha_bridge' }
  foreach ($taskEntry in $taskEntries.GetEnumerator()) {
    & $DartExecutable compile exe "tool/link/$($taskEntry.Key).dart" -o (Join-Path $taskOutput "$($taskEntry.Value).exe")
    if ($LASTEXITCODE -ne 0) { throw 'Dart compilation failed.' }
  }
  & $CmakeExecutable -S windows/link -B build/link-native -A x64
  if ($LASTEXITCODE -ne 0) { throw 'Native configuration failed.' }
  & $CmakeExecutable --build build/link-native --config Release
  if ($LASTEXITCODE -ne 0) { throw 'Native compilation failed.' }
  foreach ($taskLibrary in @('shiroha_link_native.dll','shiroha_link_control_native.dll','shiroha_handoff_native.dll')) {
    Copy-Item -LiteralPath (Join-Path $taskRoot "build/link-native/Release/$taskLibrary") -Destination (Join-Path $taskOutput $taskLibrary)
  }
  $taskFeed = Join-Path $taskRoot 'build/link-offline-feed'
  New-Item -ItemType Directory -Path $taskFeed -Force | Out-Null
  & dotnet restore tool/android_device_adapter/AndroidDeviceAdapter.csproj --runtime win-x64 -p:RuntimeFrameworkVersion=10.0.7 --source $taskFeed
  if ($LASTEXITCODE -ne 0) { throw 'Offline runtime pack restore failed; no network restore was attempted.' }
  & dotnet publish tool/android_device_adapter/AndroidDeviceAdapter.csproj --configuration Release --runtime win-x64 --self-contained true -p:RuntimeFrameworkVersion=10.0.7 -p:PublishSingleFile=true -p:PublishTrimmed=false --no-restore --output $taskOutput
  if ($LASTEXITCODE -ne 0) { throw 'Adapter publish failed; restore is a separate explicit build step.' }
  Write-Output 'Runtime compiled. Installation, pairing/claim, and real-client acceptance have not run.'
} finally { Pop-Location }
