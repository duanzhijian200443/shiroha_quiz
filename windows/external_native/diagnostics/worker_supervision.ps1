# Pure one-shot supervision. Callbacks belong to one independently owned worker.
# Never kills, restarts, retries, cleans objects or dispatches another mode.
# Phase A separates start-attempt, actual start-return, identity facts and
# observation facts; a failed getter quarantines and never continues.
# Phase B is a bounded operator handshake: no worker observation, no auto action.
function Invoke-Batch3WorkerObservation {
    param([Parameter(Mandatory)]$Lease,
          [Parameter(Mandatory)][bool]$OperatorConfirmed,
          [Parameter(Mandatory)][scriptblock]$StartWorker,
          [Parameter(Mandatory)][scriptblock]$GetHandle,
          [Parameter(Mandatory)][scriptblock]$GetPid,
          [Parameter(Mandatory)][scriptblock]$GetStartTicks,
          [Parameter(Mandatory)][scriptblock]$WaitForExit,
          [Parameter(Mandatory)][scriptblock]$GetExitCode,
          [Parameter(Mandatory)][scriptblock]$Sample,
          [Parameter(Mandatory)][scriptblock]$Clock,
          [ValidateRange(1,30000)][int]$DeadlineMilliseconds = 15000,
          [ValidateRange(1,512)][int]$WorkerMemoryMiB = 256,
          [ValidateRange(1,512)][int]$ControllerMemoryMiB = 256,
          [ValidateRange(1,512)][int]$WorkerHandles = 256,
          [ValidateRange(1,1024)][int]$ControllerHandles = 512)
    if ($Lease.Consumed -isnot [bool] -or $Lease.Consumed) { throw 'observation_already_consumed' }
    $r = [pscustomobject]@{
        Code = 10; State = 'not_started'; FirstFailure = $null
        Attempted = 0; StartReturned = 0; StartSucceeded = 0; Returned = 0; Completed = 0; ExitObserved = $false
        SettlementUnknown = $true; WorkerResourcesReleased = $false
        Pid = $null; StartedUtcTicks = $null; ProcessHandle = $null; HandleObtained = $false; IdentityComplete = $false
        Polls = 0; SampleAttempts = 0; SamplesReturned = 0; LastSample = $null; LastAttempt = 'clock'
        RecoveryRequiresSeparateGrant = $true
        ManualRecovery = 'retain_worker_reference_and_identity; operator_decision_required; no_auto_termination'
    }
    if (-not $OperatorConfirmed) {
        # Zero side effects: nothing starts and the one-shot lease is not consumed.
        $r.State = 'prestart_unconfirmed'; $r.LastAttempt = 'operator_confirmation'
        return $r
    }
    $Lease.Consumed = $true # Includes startup failures; one invocation, no retry.
    $stage = 'clock'; $previous = -1L
    try {
        $start = & $Clock
        if ($start -isnot [long] -or $start -lt 0) { throw 'clock' }
        $previous = $start
        $stage = 'startup'; $r.LastAttempt = $stage; ++$r.Attempted
        $started = & $StartWorker
        # The actual launch result is fixed before any identity getter runs.
        if ($started -isnot [bool]) { throw 'startup' }
        ++$r.StartReturned
        if (-not $started) {
            # A false launch is never evidence that no worker exists.
            $r.State = 'start_false'; $r.FirstFailure = 'start_returned_false'
            return $r
        }
        ++$r.StartSucceeded
        $stage = 'clock'; $r.LastAttempt = $stage
        $now = & $Clock
        if ($now -isnot [long] -or $now -lt $previous) { throw 'clock' }
        $previous = $now
        if ($now - $start -ge $DeadlineMilliseconds) { $stage = 'deadline'; throw 'deadline' }
        $stage = 'identity_handle'; $r.LastAttempt = $stage
        $handle = & $GetHandle
        if ($null -eq $handle -or $handle -isnot [IntPtr] -or $handle.ToInt64() -eq 0) { throw 'identity_handle' }
        $r.ProcessHandle = $handle.ToInt64(); $r.HandleObtained = $true
        $stage = 'identity_pid'; $r.LastAttempt = $stage
        $pidValue = & $GetPid
        if ($pidValue -isnot [int] -or $pidValue -le 0) { throw 'identity_pid' }
        $r.Pid = [int]$pidValue
        $stage = 'identity_ticks'; $r.LastAttempt = $stage
        $ticks = & $GetStartTicks
        if ($ticks -isnot [long] -or $ticks -le 0) { throw 'identity_ticks' }
        $r.StartedUtcTicks = [long]$ticks
        $stage = 'clock'; $r.LastAttempt = $stage
        $now = & $Clock
        if ($now -isnot [long] -or $now -lt $previous) { throw 'clock' }
        $previous = $now
        # A late identity is recorded but never accepted as complete.
        if ($now - $start -ge $DeadlineMilliseconds) { $stage = 'identity_deadline'; throw 'identity_deadline' }
        $r.IdentityComplete = $true; $r.State = 'started'
        while ($r.Polls -lt 301) {
            $stage = 'clock'; $r.LastAttempt = $stage
            $now = & $Clock
            if ($now -isnot [long] -or $now -lt $previous) { throw 'clock' }
            $previous = $now
            if ($now - $start -ge $DeadlineMilliseconds) { $stage = 'deadline'; throw 'deadline' }
            $stage = 'resource_query'; $r.LastAttempt = $stage; ++$r.SampleAttempts
            $resourceSample = & $Sample
            ++$r.SamplesReturned
            foreach ($field in @('WorkerPeakWorkingSet','WorkerPeakCommit','ControllerPeakWorkingSet','ControllerPeakCommit','WorkerHandles','ControllerHandles')) {
                if ($resourceSample.$field -isnot [long] -or $resourceSample.$field -lt 0) { throw 'sample_shape' }
            }
            $r.LastSample = $resourceSample
            $stage = 'resource_budget'
            if ($resourceSample.WorkerPeakWorkingSet -gt ($WorkerMemoryMiB * 1MB) -or $resourceSample.WorkerPeakCommit -gt ($WorkerMemoryMiB * 1MB) -or
                $resourceSample.ControllerPeakWorkingSet -gt ($ControllerMemoryMiB * 1MB) -or $resourceSample.ControllerPeakCommit -gt ($ControllerMemoryMiB * 1MB) -or
                $resourceSample.WorkerHandles -gt $WorkerHandles -or $resourceSample.ControllerHandles -gt $ControllerHandles) { throw 'resource_budget' }
            $stage = 'clock'; $r.LastAttempt = $stage
            $now = & $Clock
            if ($now -isnot [long] -or $now -lt $previous) { throw 'clock' }
            $previous = $now
            if ($now - $start -ge $DeadlineMilliseconds) { $stage = 'deadline'; throw 'deadline' }
            $stage = 'wait'; $r.LastAttempt = $stage; ++$r.Polls
            $exited = & $WaitForExit ([int][Math]::Min(100, $DeadlineMilliseconds - ($now - $start)))
            if ($exited -isnot [bool]) { throw 'wait_shape' }
            $r.ExitObserved = $exited
            $stage = 'clock'; $r.LastAttempt = $stage
            $after = & $Clock
            if ($after -isnot [long] -or $after -lt $previous) { throw 'clock' }
            $previous = $after
            if ($after - $start -ge $DeadlineMilliseconds) { $stage = 'deadline'; throw 'deadline' }
            if ($exited) {
                $stage = 'exit_code'; $r.LastAttempt = $stage
                $code = & $GetExitCode
                ++$r.Returned
                if ($code -isnot [int]) { throw 'exit_shape' }
                $stage = 'clock'; $r.LastAttempt = $stage
                $finished = & $Clock
                if ($finished -isnot [long] -or $finished -lt $previous) { throw 'clock' }
                if ($finished - $start -ge $DeadlineMilliseconds) { $stage = 'deadline'; throw 'deadline' }
                $r.Code = $code; $r.Completed = 1; $r.SettlementUnknown = $false
                $r.WorkerResourcesReleased = $true # OS exit only; never commit/capture approval.
                $r.State = if ($code -eq 0) { 'normal_exit' } else { 'abnormal_exit' }
                if ($code -ne 0) { $r.FirstFailure = 'worker_nonzero' }
                return $r
            }
        }
        $stage = 'poll_budget'; throw 'poll_budget'
    } catch {
        if ($null -eq $r.FirstFailure) { $r.FirstFailure = $stage }
        if ($stage -ceq 'deadline') { $r.State = 'timed_out' }
        elseif ($stage -clike 'identity_*') { $r.State = 'identity_failed' }
        elseif ($stage -ceq 'startup') { $r.State = 'start_unknown' }
        else { $r.State = 'observation_failed' }
    }
    return $r # Stop observing. Process termination is NOT implied.
}

# Bounded operator handoff after the frozen observation. This phase never
# observes the worker again and performs no automatic action on any path.
# Candidate receipt/holding windows are parameters pending the ruled contract.
function Invoke-Batch3HoldingHandoff {
    param([Parameter(Mandatory)]$Lease,
          [Parameter(Mandatory)]$Observation,
          [Parameter(Mandatory)][scriptblock]$AwaitReceipt,
          [Parameter(Mandatory)][scriptblock]$AwaitAcknowledgment,
          [Parameter(Mandatory)][scriptblock]$Clock,
          [ValidateRange(1,300000)][int]$ReceiptDeadlineMilliseconds = 60000,
          [ValidateRange(1,300000)][int]$HoldingDeadlineMilliseconds = 60000)
    if ($null -eq $Lease) { throw 'handoff_lease' }
    if ($null -eq $Observation -or $null -eq $Observation.PSObject.Properties['WorkerResourcesReleased']) { throw 'handoff_observation' }
    $h = [pscustomobject]@{
        Code = 10; HandoffState = 'failed'; FirstFailure = $null; LastAttempt = 'handoff_clock'
        Received = $false; AcknowledgedHolding = $false
        ReceiptDeadlineMilliseconds = $ReceiptDeadlineMilliseconds
        HoldingDeadlineMilliseconds = $HoldingDeadlineMilliseconds
        ElapsedMilliseconds = $null
        WorkerResourcesReleased = [bool]$Observation.WorkerResourcesReleased
        RecoveryRequiresSeparateGrant = $true
        ManualRecovery = 'operator_settlement_required; no_auto_termination; no_cross_process_handoff'
    }
    $stage = 'handoff_clock'
    try {
        $start = & $Clock
        if ($start -isnot [long] -or $start -lt 0) { throw 'handoff_clock' }
        $previous = $start
        $stage = 'handoff_receipt'; $h.LastAttempt = $stage
        $receipt = & $AwaitReceipt $ReceiptDeadlineMilliseconds
        if ($receipt -isnot [string] -or @('received','declined','timeout') -cnotcontains $receipt) { $stage = 'handoff_receipt_shape'; throw $stage }
        $now = & $Clock
        if ($now -isnot [long] -or $now -lt $previous) { throw 'handoff_clock' }
        $previous = $now
        # A receipt that completes outside its window is never accepted.
        if ($now - $start -gt $ReceiptDeadlineMilliseconds) { $stage = 'handoff_receipt_timeout'; throw $stage }
        if ($receipt -cne 'received') { $stage = 'handoff_receipt_' + $receipt; throw $stage }
        $h.Received = $true
        $stage = 'handoff_ack'; $h.LastAttempt = $stage
        $ack = & $AwaitAcknowledgment $HoldingDeadlineMilliseconds
        if ($ack -isnot [string] -or @('acknowledged','declined','timeout') -cnotcontains $ack) { $stage = 'handoff_ack_shape'; throw $stage }
        $now = & $Clock
        if ($now -isnot [long] -or $now -lt $previous) { throw 'handoff_clock' }
        # A late acknowledgment is never accepted as holding.
        if ($now - $start -gt ($ReceiptDeadlineMilliseconds + $HoldingDeadlineMilliseconds)) { $stage = 'handoff_ack_timeout'; throw $stage }
        if ($ack -cne 'acknowledged') { $stage = 'handoff_ack_' + $ack; throw $stage }
        $h.AcknowledgedHolding = $true; $h.HandoffState = 'acknowledged_holding'; $h.Code = 0
        $h.ElapsedMilliseconds = $now - $start; $h.LastAttempt = 'handoff_complete'
    } catch {
        if ($null -eq $h.FirstFailure) { $h.FirstFailure = $stage }
    }
    return $h
}
