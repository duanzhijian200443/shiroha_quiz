Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot '../diagnostics/runner_sequence.ps1')
foreach ($failure in @('symbols', 'abi', 'assoc', 'bridge-denied', 'none')) {
    $seen = [System.Collections.Generic.List[string]]::new()
    $result = Invoke-CandidateSequence -InvokeMode {
        param($mode)
        $seen.Add($mode)
        [pscustomobject]@{ Code = if ($mode -eq $failure) { 10 } else { 0 } }
    }
    $expected = if ($failure -eq 'none') { 4 } else { @('symbols', 'abi', 'assoc', 'bridge-denied').IndexOf($failure) + 1 }
    if ($seen.Count -ne $expected -or $result.CompletedProcesses -ne $expected -or
        $result.NotExecuted.Count -ne 4 - $expected -or
        ($result.Code -eq 0) -ne ($failure -eq 'none')) { throw 'Runner continued or lost failure evidence' }
    if ($failure -eq 'assoc' -and $seen.Contains('bridge-denied')) { throw 'Bridge launched after failed association' }
}
$seen = [System.Collections.Generic.List[string]]::new()
$crash = Invoke-CandidateSequence -InvokeMode {
    param($mode)
    $seen.Add($mode)
    throw 'synthetic invocation exception'
}
if ($seen.Count -ne 1 -or $crash.ProbeCode -ne -1 -or $crash.NotExecuted.Count -ne 3) {
    throw 'Invocation exception did not stop sequence'
}
Write-Output 'PASS: pure runner orchestration, no child process or security operations'
