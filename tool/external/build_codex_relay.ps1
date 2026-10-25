param(
  [Parameter(Mandatory = $true)][string]$DartExecutable,
  [Parameter(Mandatory = $true)][string]$AppDirectory
)
$ErrorActionPreference = 'Stop'
if (-not $IsWindows) { throw 'Windows is required.' }
$taskRoot = (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot '../..')).ProviderPath
$taskDart = (Get-Item -LiteralPath $DartExecutable).FullName
$taskApp = (Resolve-Path -LiteralPath $AppDirectory).ProviderPath
if ([IO.Path]::GetExtension($taskDart) -ne '.exe') {
  throw 'Select the existing Dart VM executable.'
}
foreach ($taskRequired in @('shiroha_quiz.exe', 'shiroha_relay_native.dll', 'shiroha_external_native.dll')) {
  if (-not (Test-Path -LiteralPath (Join-Path $taskApp $taskRequired) -PathType Leaf)) {
    throw 'Build the normal Windows App before its adjacent relay package.'
  }
}
# Development packaging only. Neither binary gains security admission.
# No installation, dependency download, credentials or Codex configuration work.
Push-Location -LiteralPath $taskRoot
try {
  & $taskDart compile exe tool/external/bridge_candidate.dart -o (Join-Path $taskApp 'shiroha_bridge.exe')
  if ($LASTEXITCODE -ne 0) { throw 'Bridge compilation failed.' }
  & $taskDart compile exe tool/external/codex_relay_candidate.dart -o (Join-Path $taskApp 'shiroha_codex.exe')
  if ($LASTEXITCODE -ne 0) { throw 'Codex relay compilation failed.' }
} finally {
  Pop-Location
}
