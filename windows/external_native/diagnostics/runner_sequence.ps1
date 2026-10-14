# Pure orchestration seam. Offline tests inject a process-free invoker.
function Invoke-CandidateSequence {
    param([Parameter(Mandatory)][scriptblock]$InvokeMode)
    $modes = @('symbols', 'abi', 'assoc', 'bridge-denied')
    for ($index = 0; $index -lt $modes.Count; $index++) {
        try { $result = & $InvokeMode $modes[$index] }
        catch { $result = [pscustomobject]@{ Code = -1 } } # No raw exception/path logging.
        if ($null -eq $result -or $result.Code -ne 0) {
            return [pscustomobject]@{
                Code = 10
                FailedMode = $modes[$index]
                ProbeCode = if ($null -eq $result) { -1 } else { $result.Code }
                CompletedProcesses = $index + 1
                NotExecuted = @($modes | Select-Object -Skip ($index + 1))
            }
        }
    }
    return [pscustomobject]@{ Code = 0; FailedMode = ''; ProbeCode = 0; CompletedProcesses = 4; NotExecuted = @() }
}
