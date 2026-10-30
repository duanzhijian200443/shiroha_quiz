[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$CodexExecutable,
    [string]$PythonExecutable = 'python',
    [switch]$UnifiedProfile,
    [ValidateSet('disable', 'restart', 'upgrade', 'pending-disable', 'pending-turn-disable', 'pending-turn-stop-disable', 'pending-turn-stop-upgrade')]
    [string[]]$Scenarios = @('disable', 'restart', 'upgrade', 'pending-turn-stop-disable', 'pending-turn-stop-upgrade')
)

# An isolated synthetic consumer of the original App-owned relay. No real App,
# database, pairing record, provider request or user's Codex configuration.
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
if (!$IsWindows) { throw 'Windows desktop session required.' }
$taskRoot = (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot '../..')).ProviderPath
$taskCodex = (Get-Item -LiteralPath $CodexExecutable).FullName
if ([IO.Path]::GetExtension($taskCodex) -ne '.exe') { throw 'Select codex.exe.' }
$taskRun = Join-Path $taskRoot ('build/plugin_host_qualification/runs/' + [Guid]::NewGuid().ToString('N'))
$taskBin = Join-Path $taskRun 'bin'
New-Item -ItemType Directory -Path $taskBin | Out-Null
$taskDart = Join-Path (Split-Path -Parent (Get-Command dart).Source) 'cache/dart-sdk/bin/dart.exe'
$taskVswhere = Join-Path ${env:ProgramFiles(x86)} 'Microsoft Visual Studio/Installer/vswhere.exe'
$taskVs = & $taskVswhere -latest -products '*' -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -property installationPath
if ($LASTEXITCODE -ne 0 -or !$taskVs) { throw 'MSVC unavailable.' }
$taskCmake = Join-Path $taskVs 'Common7/IDE/CommonExtensions/Microsoft/CMake/CMake/bin/cmake.exe'

Push-Location -LiteralPath $taskRoot
try {
    & $taskCmake -S windows/local_relay -B (Join-Path $taskRun 'native') -G 'Visual Studio 17 2022' -A x64 *> (Join-Path $taskRun 'native-configure.log')
    if ($LASTEXITCODE -ne 0) { throw 'Native configure failed; retain configure log.' }
    & $taskCmake --build (Join-Path $taskRun 'native') --config Debug --target shiroha_relay_native *> (Join-Path $taskRun 'native-build.log')
    if ($LASTEXITCODE -ne 0) { throw 'Native build failed; retain build log.' }
    Copy-Item -LiteralPath (Join-Path $taskRun 'native/Debug/shiroha_relay_native.dll') -Destination $taskBin
    # PE inventory placeholder only; the synthetic Bridge does not load it.
    Copy-Item -LiteralPath (Join-Path $taskBin 'shiroha_relay_native.dll') -Destination (Join-Path $taskBin 'shiroha_external_native.dll')
    $taskSources = @{
        'shiroha_quiz' = 'test/mcp/fixtures/local_relay_app.dart'
        'shiroha_bridge' = 'test/mcp/fixtures/local_relay_bridge.dart'
        'shiroha_codex' = 'tool/external/codex_relay_candidate.dart'
        'qualify_model' = 'tool/plugin/qualify_model.dart'
    }
    foreach ($taskName in $taskSources.Keys) {
        & $taskDart compile exe $taskSources[$taskName] -o (Join-Path $taskBin "$taskName.exe") *> (Join-Path $taskRun "$taskName-compile.log")
        if ($LASTEXITCODE -ne 0) { throw "Fixture compilation failed: $taskName" }
    }
    $taskIdentity = @{
        head = (& git rev-parse HEAD)
        codexSha256 = (Get-FileHash -LiteralPath $taskCodex -Algorithm SHA256).Hash.ToLowerInvariant()
        codexVersion = (& $taskCodex --version)
        evidenceClass = 'synthetic fixture'
    }
    $taskIdentity | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $taskRun 'identity.json') -Encoding utf8
    Write-Output "Compiled isolated App/Bridge and original adapter. Evidence: $taskRun"
    $taskProfileArguments = @()
    if ($UnifiedProfile) { $taskProfileArguments += '--unified' }
    & $PythonExecutable (Join-Path $PSScriptRoot 'qualify_host.py') --codex $taskCodex --run $taskRun @taskProfileArguments --scenarios $Scenarios
    if ($LASTEXITCODE -ne 0) { throw 'Host qualification did not pass; preserve evidence and stop dependent implementation.' }
} finally {
    Pop-Location
}
