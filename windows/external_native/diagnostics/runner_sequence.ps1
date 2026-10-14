# Pure orchestration seam. Offline tests inject a process-free invoker.
function Invoke-CandidateSequence {
    param([Parameter(Mandatory)][scriptblock]$InvokeMode)
    $modes = @('symbols', 'abi', 'assoc', 'bridge-denied')
    $returned = 0; $completed = 0; $successful = 0
    for ($index = 0; $index -lt $modes.Count; $index++) {
        $code = -1; $failureKind = 'invalid_result'
        try {
            $result = & $InvokeMode $modes[$index]
            $returned++
            # Extra output, missing Code and coerced strings are not success.
            if ($null -ne $result -and $result -isnot [array] -and
                $null -ne $result.PSObject.Properties['Code'] -and $result.Code -is [int]) {
                $code = $result.Code; $completed++
                $failureKind = 'exit_status'
            }
        } catch { $failureKind = 'invocation_exception' } # Never log raw exception/path.
        if ($code -ne 0) {
            return [pscustomobject]@{
                Code = 10; FailedMode = $modes[$index]; ProbeCode = $code; FailureKind = $failureKind
                AttemptedProcesses = $index + 1; ReturnedProcesses = $returned
                CompletedProcesses = $completed; SuccessfulProcesses = $successful
                NotExecuted = @($modes | Select-Object -Skip ($index + 1))
            }
        }
        $successful++
    }
    return [pscustomobject]@{
        Code = 0; FailedMode = ''; ProbeCode = 0; FailureKind = ''
        AttemptedProcesses = 4; ReturnedProcesses = 4; CompletedProcesses = 4; SuccessfulProcesses = 4
        NotExecuted = @()
    }
}
