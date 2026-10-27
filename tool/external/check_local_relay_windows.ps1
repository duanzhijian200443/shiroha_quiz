[CmdletBinding()]
param(
    [ValidateSet('idle', 'malformed', 'monitored-idle', 'inventory', 'sdk-error', 'failed-close', 'pending-peer', 'pending-peer-failed-close', 'adapter-reconnect', 'adapter-reconnect-failed-close')]
    [string[]]$Scenarios = @('idle', 'malformed', 'monitored-idle', 'inventory', 'sdk-error', 'failed-close', 'pending-peer', 'pending-peer-failed-close')
)

# Isolated ordinary-process diagnostics only. No normal App, database, protected
# objects, credentials, Codex configuration or provider. Retain every run artifact.
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
if (!$IsWindows) { throw 'Windows desktop session required' }
$root = (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot '../..')).ProviderPath
$run = Join-Path $root ('.dart_tool/relay-repair-' + [Guid]::NewGuid().ToString('N'))
$bin = Join-Path $run 'bin'
New-Item -ItemType Directory -Path $bin | Out-Null
$dart = Join-Path (Split-Path -Parent (Get-Command dart).Source) 'cache/dart-sdk/bin/dart.exe'
$vswhere = Join-Path ${env:ProgramFiles(x86)} 'Microsoft Visual Studio/Installer/vswhere.exe'
$installation = & $vswhere -latest -products '*' -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -property installationPath
if ($LASTEXITCODE -ne 0 -or !$installation) { throw 'MSVC unavailable' }
$cmake = Join-Path $installation 'Common7/IDE/CommonExtensions/Microsoft/CMake/CMake/bin/cmake.exe'

function Assert-True([bool]$Value, [string]$Message) {
    if (!$Value) { throw $Message }
}
function Read-Events([string]$Path) {
    if (Test-Path -LiteralPath $Path) {
        Get-Content -LiteralPath $Path | Where-Object { $_ } | ForEach-Object { $_ | ConvertFrom-Json }
    }
}
function Wait-Event([string]$Path, [string]$Event, [int]$Count = 1) {
    $watch = [Diagnostics.Stopwatch]::StartNew()
    do {
        $matches = @(Read-Events $Path | Where-Object event -eq $Event)
        if ($matches.Count -ge $Count) { return $matches[$Count - 1] }
        Start-Sleep -Milliseconds 25
    } while ($watch.Elapsed.TotalSeconds -lt 20)
    throw "Timed out waiting for $Event ($Count)"
}
function Pin-Process([int]$Id, [string]$Expected) {
    $process = [Diagnostics.Process]::GetProcessById($Id)
    $null = $process.Handle # Retain the original OS handle before allowing exit.
    Assert-True ($process.MainModule.FileName -eq $Expected) 'Unexpected test process image'
    return $process
}
function Start-Adapter([string]$Directory, [string]$Label) {
    Start-Process -FilePath (Join-Path $Directory 'shiroha_codex.exe') -ArgumentList $Label `
        -WorkingDirectory $Directory -WindowStyle Hidden -PassThru `
        -RedirectStandardOutput (Join-Path $Directory "$Label.stdout") `
        -RedirectStandardError (Join-Path $Directory "$Label.stderr")
}
function Join-Process($Process, [int]$Expected) {
    Assert-True ($Process.WaitForExit(15000)) 'Original process did not settle'
    Assert-True ($Process.ExitCode -eq $Expected) 'Unexpected original process exit'
}

Push-Location -LiteralPath $root
try {
    & $cmake -S windows/local_relay -B (Join-Path $run 'native') -G 'Visual Studio 17 2022' -A x64 *> (Join-Path $run 'configure.log')
    Assert-True ($LASTEXITCODE -eq 0) 'Native configure failed'
    & $cmake --build (Join-Path $run 'native') --config Debug --target shiroha_relay_native *> (Join-Path $run 'build.log')
    Assert-True ($LASTEXITCODE -eq 0) 'Native build failed'
    Copy-Item -LiteralPath (Join-Path $run 'native/Debug/shiroha_relay_native.dll') -Destination $bin
    # PE inventory placeholder only. The test Bridge never loads this name.
    Copy-Item -LiteralPath (Join-Path $bin 'shiroha_relay_native.dll') -Destination (Join-Path $bin 'shiroha_external_native.dll')
    foreach ($pair in @(@('app', 'quiz'), @('bridge', 'bridge'), @('adapter', 'codex'))) {
        & $dart compile exe "test/mcp/fixtures/local_relay_$($pair[0]).dart" -o (Join-Path $bin "shiroha_$($pair[1]).exe") *> (Join-Path $run "$($pair[0])-compile.log")
        Assert-True ($LASTEXITCODE -eq 0) "Fixture $($pair[0]) compile failed"
    }
    Write-Output 'PASS: MSVC /W4 /WX and three AOT fixtures compiled'
    $shellWindows = (New-Object -ComObject Shell.Application).Windows()
    $desktopHandle = 0
    $desktop = $shellWindows.FindWindowSW(0, 0, 8, [ref]$desktopHandle, 1)
    $shell = $desktop.Document.Application
    $results = @()
    foreach ($scenario in $Scenarios) {
        $pendingPeer = $scenario.StartsWith('pending-peer')
        $failedClose = $scenario -in @('failed-close', 'pending-peer-failed-close', 'adapter-reconnect-failed-close')
        $adapterReconnect = $scenario.StartsWith('adapter-reconnect')
        $directory = Join-Path $run $scenario
        New-Item -ItemType Directory -Path $directory | Out-Null
        Get-ChildItem -LiteralPath $bin -File | Copy-Item -Destination $directory
        [IO.File]::WriteAllText((Join-Path $directory 'scenario'), $scenario)
        $app = $old = $fresh = $child = $nextChild = $null
        try {
            $appExe = Join-Path $directory 'shiroha_quiz.exe'
            $appEvents = Join-Path $directory 'app.jsonl'
            $bridgeEvents = Join-Path $directory 'bridge.jsonl'
            $shell.ShellExecute($appExe, '', $directory, 'open', 0)
            $ready = Wait-Event $appEvents 'ready'
            $app = Pin-Process $ready.pid $appExe
            $old = Start-Adapter $directory 'old'
            $started = Wait-Event $bridgeEvents 'started'
            $child = Pin-Process $started.pid (Join-Path $directory 'shiroha_bridge.exe')
            if ($adapterReconnect) {
                $null = Wait-Event (Join-Path $directory 'old.jsonl') 'firstResponse'
                [IO.File]::WriteAllText((Join-Path $directory 'allow-exit-1'), '')
                $null = Wait-Event $bridgeEvents 'eof'
                Join-Process $child $(if ($failedClose) { 23 } else { 0 })
                if (!$failedClose) {
                    $null = Wait-Event $appEvents 'originalBridgeSettled'
                    $null = Wait-Event $appEvents 'listening' 2
                }
                Assert-True (!$old.HasExited) 'The original adapter must remain alive for reconnection'
                [IO.File]::WriteAllText((Join-Path $directory 'allow-exit-2'), '')
                [IO.File]::WriteAllText((Join-Path $directory 'request-reconnect'), '')
                $null = Wait-Event (Join-Path $directory 'old.jsonl') 'secondResponse'
                Join-Process $old 0
                if ($failedClose) {
                    Assert-True (@(Read-Events $bridgeEvents | Where-Object event -eq 'started').Count -eq 1) 'Failed original cleanup permitted a replacement Bridge'
                    Assert-True (@(Read-Events $appEvents | Where-Object event -eq 'originalBridgeSettled').Count -eq 0) 'Failed original cleanup was called settled'
                } else {
                    $null = Wait-Event $appEvents 'originalBridgeSettled' 2
                    Assert-True (@(Read-Events $bridgeEvents | Where-Object event -eq 'started').Count -eq 2) 'The same adapter did not acquire a new original Bridge'
                    Assert-True (@(Read-Events $bridgeEvents | Where-Object event -eq 'call').Count -eq 2) 'A request was replayed'
                }
                [IO.File]::WriteAllText((Join-Path $directory 'stop'), '')
                $expectedExit = if ($failedClose) { 23 } else { 0 }
                Join-Process $app $expectedExit
                $results += @{scenario=$scenario;result='PASS';appExit=$expectedExit;sameAdapterPid=$old.Id}
                Write-Output "PASS: $scenario"
                continue
            }
            if ($pendingPeer) {
                $null = Wait-Event $bridgeEvents 'pendingCall'
                [IO.File]::WriteAllText((Join-Path $directory 'disconnect-old'), '')
                Join-Process $old 0
                $null = Wait-Event $bridgeEvents 'eof'
                $null = Wait-Event $appEvents 'enableWithdrawn'
                $ticks = @(Read-Events $appEvents | Where-Object event -eq 'launchCurrent').Count
                $watch = [Diagnostics.Stopwatch]::StartNew()
                do {
                    $observed = @(Read-Events $appEvents)
                    Assert-True (@($observed | Where-Object event -in @('launchLost', 'deploymentStopped')).Count -eq 0) 'Outer peer loss invalidated deployment while original settlement was pending'
                    Assert-True (!$child.HasExited) 'Original Bridge exited before the controlled settlement release'
                    Assert-True (@($observed | Where-Object event -eq 'originalBridgeSettled').Count -eq 0) 'Pending original child was labeled settled'
                    $currentTicks = @($observed | Where-Object event -eq 'launchCurrent').Count
                    if ($currentTicks -ge $ticks + 3) { break }
                    Start-Sleep -Milliseconds 25
                } while ($watch.Elapsed.TotalSeconds -lt 5)
                Assert-True ($currentTicks -ge $ticks + 3) 'Missing production monitor ticks during pending settlement'
            }
            [IO.File]::WriteAllText((Join-Path $directory 'allow-exit-1'), '')
            if (!$pendingPeer) {
                $lostEvent = if ($scenario -eq 'monitored-idle') { 'closedOnLoss' } else { 'lostWithHandleRetained' }
                $null = Wait-Event (Join-Path $directory 'old.jsonl') $lostEvent
                Assert-True (!$old.HasExited) 'Old adapter must remain alive'
            }
            $null = Wait-Event $bridgeEvents 'eof'
            if ($failedClose) {
                Join-Process $child 23
                # Fresh peer cannot dispatch on a failed original close.
                $fresh = Start-Adapter $directory 'fresh'
                Join-Process $fresh 1
                Assert-True (@(Read-Events $bridgeEvents | Where-Object event -eq 'started').Count -eq 1) 'Failed close launched another Bridge'
                Assert-True (@(Read-Events $appEvents | Where-Object event -eq 'originalBridgeSettled').Count -eq 0) 'Failed close was labeled settled'
            } else {
                Join-Process $child 0
                $null = Wait-Event $appEvents 'originalBridgeSettled'
                $null = Wait-Event $appEvents 'listening' 2
                $fresh = Start-Adapter $directory 'fresh'
                $next = Wait-Event $bridgeEvents 'started' 2
                $nextChild = Pin-Process $next.pid (Join-Path $directory 'shiroha_bridge.exe')
                [IO.File]::WriteAllText((Join-Path $directory 'allow-exit-2'), '')
                $null = Wait-Event (Join-Path $directory 'fresh.jsonl') 'response'
                Join-Process $fresh 0
                Join-Process $nextChild 0
                $null = Wait-Event $appEvents 'originalBridgeSettled' 2
                if (!$pendingPeer) { Assert-True (!$old.HasExited) 'Fresh connection must succeed with old adapter alive' }
                $calls = @(Read-Events $bridgeEvents | Where-Object event -eq 'call').Count
                $expectedCalls = if ($scenario -eq 'inventory') { 1 } else { 2 }
                Assert-True ($calls -eq $expectedCalls) 'Unexpected call replay'
            }
            [IO.File]::WriteAllText((Join-Path $directory 'release-old'), '')
            Join-Process $old 0
            [IO.File]::WriteAllText((Join-Path $directory 'stop'), '')
            $expectedExit = if ($failedClose) { 23 } else { 0 }
            Join-Process $app $expectedExit
            $event = if ($failedClose) { 'appCloseFailed' } else { 'appClosed' }
            $null = Wait-Event $appEvents $event
            $results += @{scenario=$scenario;result='PASS';appExit=$expectedExit}
            Write-Output "PASS: $scenario"
        } finally {
            # Only graceful test control; no process kill or erased failure.
            foreach ($marker in @('allow-exit-1', 'allow-exit-2', 'release-old', 'disconnect-old', 'request-reconnect', 'stop')) {
                [IO.File]::WriteAllText((Join-Path $directory $marker), '')
            }
            foreach ($process in @($old, $fresh, $child, $nextChild, $app)) {
                if ($null -ne $process) {
                    $null = $process.WaitForExit(15000)
                    $process.Dispose()
                }
            }
        }
    }
    $results | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $run 'results.json')
    Write-Output ('Evidence: ' + [IO.Path]::GetRelativePath($root, $run))
} catch {
    [IO.File]::WriteAllText((Join-Path $run 'FAILED'), 'Regression failed; retain per-scenario events and build logs.')
    Write-Output ('FAILED evidence: ' + [IO.Path]::GetRelativePath($root, $run))
    throw
} finally {
    Pop-Location
}
