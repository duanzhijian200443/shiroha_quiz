# Read-only observation of a fixture PID captured before client shutdown.
# Open and retain the original Process handle; never kill, restart or adopt it.
param([Parameter(Mandatory = $true)][int]$TargetPid)
$ErrorActionPreference = 'Stop'
$taskObservedProcess = [Diagnostics.Process]::GetProcessById($TargetPid)
try {
    $null = $taskObservedProcess.Handle
    @{ observed = $true } | ConvertTo-Json -Compress
    if (!$taskObservedProcess.WaitForExit(20000)) {
        @{ exited = $false } | ConvertTo-Json -Compress
        exit 2
    }
    @{ exited = $true; exitCode = $taskObservedProcess.ExitCode } | ConvertTo-Json -Compress
} finally {
    $taskObservedProcess.Dispose()
}
