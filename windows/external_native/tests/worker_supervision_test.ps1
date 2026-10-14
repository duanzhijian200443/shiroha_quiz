Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot '../diagnostics/worker_supervision.ps1')
. (Join-Path $PSScriptRoot '../diagnostics/runner_sequence.ps1')
function Check($value) { if (-not $value) { throw "supervisor fake assertion case=$mode starts=$script:starts result=$($result | ConvertTo-Json -Compress)" } }
function CheckH($value, $tag) { if (-not $value) { throw "supervisor fake assertion $tag" } }
$cases = 0
$mode = 'prestart'

# Pre-start operator confirmation: an unconfirmed invocation has zero side
# effects, and the same untouched lease stays usable after confirmation.
$script:starts = 0
$lease = [pscustomobject]@{ Consumed = $false; Process = [pscustomobject]@{ Tag = 'original' } }
$result = Invoke-Batch3WorkerObservation -Lease $lease -OperatorConfirmed $false -DeadlineMilliseconds 150 -Clock { [long]0 } -StartWorker { ++$script:starts; $true } -GetHandle { throw 'never' } -GetPid { throw 'never' } -GetStartTicks { throw 'never' } -WaitForExit { param($ms); throw 'never' } -GetExitCode { throw 'never' } -Sample { throw 'never' }
CheckH ($result.State -ceq 'prestart_unconfirmed' -and $result.Code -eq 10 -and $result.Attempted -eq 0 -and $result.StartReturned -eq 0) 'unconfirmed state'
CheckH (-not $lease.Consumed -and $script:starts -eq 0) 'unconfirmed zero side effects'
++$cases
$script:tick = 0L; $script:starts = 0
$result = Invoke-Batch3WorkerObservation -Lease $lease -OperatorConfirmed $true -DeadlineMilliseconds 150 -Clock { [long]$script:tick } -StartWorker { ++$script:starts; $true } -GetHandle { [IntPtr]123 } -GetPid { [int]123 } -GetStartTicks { [long]2 } -WaitForExit { param($ms); $script:tick = 1L; $true } -GetExitCode { [int]0 } -Sample { [pscustomobject]@{ WorkerPeakWorkingSet = 1L; WorkerPeakCommit = 1L; WorkerHandles = 1L; ControllerPeakWorkingSet = 1L; ControllerPeakCommit = 1L; ControllerHandles = 1L } }
CheckH ($lease.Consumed -and $result.State -ceq 'normal_exit' -and $result.Code -eq 0) 'confirmed reuse of untouched lease'
++$cases

# Phase A: separated start/identity facts, first-failure quarantine, all budgets
# and late/deadline behavior, with the original reference retained untouched.
foreach ($mode in @('normal','nonzero','start_throw','start_shape','start_false','identity_handle','identity_pid','identity_ticks','identity_late','start_late','sample_throw','sample_shape','budget','wait_throw','wait_shape','deadline','late_exit','late_getter','exit_throw','exit_shape','clock_back','clock_throw','frozen','sample_late')) {
    $script:tick = 0L; $script:starts = 0; $script:exitReads = 0; $script:waits = 0; $script:getters = 0
    $lease = [pscustomobject]@{ Consumed = $false; Process = [pscustomobject]@{ Tag = 'original' } }
    $processRef = $lease.Process
    $result = Invoke-Batch3WorkerObservation -Lease $lease -OperatorConfirmed $true -DeadlineMilliseconds 150 -Clock {
        if ($mode -ceq 'clock_throw' -and $script:starts) { throw 'clock' }
        if ($mode -ceq 'clock_back' -and $script:starts) { return [long]-1 }
        [long]$script:tick
    } -StartWorker {
        ++$script:starts
        if ($mode -ceq 'start_throw') { throw 'synthetic launch uncertainty' }
        if ($mode -ceq 'start_shape') { return 'true' }
        if ($mode -ceq 'start_late') { $script:tick = 150L }
        if ($mode -ceq 'start_false') { return $false }
        $true
    } -GetHandle {
        ++$script:getters
        if ($mode -ceq 'identity_handle') { throw 'synthetic handle failure' }
        [IntPtr]123
    } -GetPid {
        ++$script:getters
        if ($mode -ceq 'identity_pid') { return '123' }
        [int]123
    } -GetStartTicks {
        ++$script:getters
        if ($mode -ceq 'identity_ticks') { return '2' }
        if ($mode -ceq 'identity_late') { $script:tick = 150L }
        [long]2
    } -Sample {
        if ($mode -ceq 'sample_throw') { throw 'synthetic resource failure' }
        if ($mode -ceq 'sample_late') { $script:tick = 150L }
        $s = [pscustomobject]@{ WorkerPeakWorkingSet = 1L; WorkerPeakCommit = 1L; WorkerHandles = 1L
            ControllerPeakWorkingSet = 1L; ControllerPeakCommit = 1L; ControllerHandles = 1L }
        if ($mode -ceq 'sample_shape') { $s.WorkerHandles = '1' }
        if ($mode -ceq 'budget') { $s.WorkerPeakCommit = [long](257MB) }
        $s
    } -WaitForExit {
        param($ms); ++$script:waits
        if ($mode -ceq 'wait_throw') { throw 'synthetic wait failure' }
        if ($mode -ceq 'wait_shape') { return 'true' }
        if ($mode -ceq 'late_exit') { $script:tick = 150L; return $true }
        if ($mode -ceq 'deadline') { $script:tick += $ms; return $false }
        if ($mode -ceq 'frozen') { return $false }
        $script:tick = 1L; $true
    } -GetExitCode {
        ++$script:exitReads
        if ($mode -ceq 'late_getter') { $script:tick = 150L }
        if ($mode -ceq 'exit_throw') { throw 'synthetic exit read failure' }
        if ($mode -ceq 'exit_shape') { return '0' }
        if ($mode -ceq 'nonzero') { return [int]7 }
        [int]0
    }
    ++$cases
    Check ($script:starts -eq 1 -and $lease.Consumed -and $result.Attempted -eq 1)
    Check ([object]::ReferenceEquals($lease.Process, $processRef))
    if ($mode -in @('normal','nonzero')) {
        Check (-not $result.SettlementUnknown -and $result.ExitObserved -and $result.WorkerResourcesReleased -and $result.Returned -eq 1 -and $result.Completed -eq 1)
        Check ($result.IdentityComplete -and $result.HandleObtained -and $result.StartReturned -eq 1 -and $result.StartSucceeded -eq 1 -and $result.Pid -eq 123 -and $result.StartedUtcTicks -eq 2)
        Check ($result.State -ceq $(if ($mode -ceq 'normal') { 'normal_exit' } else { 'abnormal_exit' }))
    } else {
        Check ($result.Code -eq 10 -and $result.SettlementUnknown -and -not $result.WorkerResourcesReleased -and $result.Completed -eq 0 -and $null -ne $result.FirstFailure)
    }
    if ($mode -ceq 'start_false') { Check ($result.State -ceq 'start_false' -and $result.FirstFailure -ceq 'start_returned_false' -and $result.StartReturned -eq 1 -and $result.StartSucceeded -eq 0 -and $script:getters -eq 0 -and $script:waits -eq 0 -and -not $result.IdentityComplete) }
    if ($mode -in @('start_throw','start_shape')) { Check ($result.State -ceq 'start_unknown' -and $result.FirstFailure -ceq 'startup' -and $result.StartReturned -eq 0 -and $script:getters -eq 0 -and $script:waits -eq 0) }
    if ($mode -eq 'identity_handle') { Check ($result.State -ceq 'identity_failed' -and $result.FirstFailure -ceq 'identity_handle' -and $result.StartReturned -eq 1 -and -not $result.HandleObtained -and -not $result.IdentityComplete -and $script:getters -eq 1 -and $script:waits -eq 0) }
    if ($mode -eq 'identity_pid') { Check ($result.State -ceq 'identity_failed' -and $result.FirstFailure -ceq 'identity_pid' -and $result.HandleObtained -and $null -eq $result.Pid -and $script:getters -eq 2 -and $script:waits -eq 0) }
    if ($mode -eq 'identity_ticks') { Check ($result.State -ceq 'identity_failed' -and $result.FirstFailure -ceq 'identity_ticks' -and $result.HandleObtained -and $result.Pid -eq 123 -and $null -eq $result.StartedUtcTicks -and -not $result.IdentityComplete -and $script:getters -eq 3 -and $script:waits -eq 0) }
    if ($mode -eq 'identity_late') { Check ($result.State -ceq 'identity_failed' -and $result.FirstFailure -ceq 'identity_deadline' -and $result.Pid -eq 123 -and -not $result.IdentityComplete -and $script:waits -eq 0 -and $script:exitReads -eq 0) }
    if ($mode -eq 'start_late') { Check ($result.FirstFailure -ceq 'deadline' -and $result.State -ceq 'timed_out' -and $result.StartReturned -eq 1 -and $script:getters -eq 0 -and $script:exitReads -eq 0) }
    if ($mode -in @('deadline','late_exit','sample_late')) { Check ($result.FirstFailure -ceq 'deadline' -and $script:exitReads -eq 0) }
    if ($mode -eq 'budget') { Check ($result.FirstFailure -ceq 'resource_budget' -and $script:waits -eq 0) }
    if ($mode -eq 'frozen') { Check ($result.Polls -eq 301 -and $result.FirstFailure -ceq 'poll_budget') }
    # Late OS exit after timeout cannot retroactively change retained evidence.
    $first = $result.FirstFailure; $script:tick = 1000L
    if ($mode -ceq 'deadline') { Check ($result.SettlementUnknown -and -not $result.ExitObserved -and $result.Returned -eq 0 -and $result.FirstFailure -ceq $first) }
    $rejected = $false
    try { Invoke-Batch3WorkerObservation -Lease $lease -OperatorConfirmed $true -Clock { throw 'never' } -StartWorker { throw 'never' } -GetHandle { throw 'never' } -GetPid { throw 'never' } -GetStartTicks { throw 'never' } -Sample { throw 'never' } -WaitForExit { throw 'never' } -GetExitCode { throw 'never' } }
    catch { $rejected = $true }
    Check ($rejected -and $script:starts -eq 1)
    if ($result.Code -ne 0) {
        $script:modes = 0
        $sequence = Invoke-CandidateSequence -InvokeMode { param($mode); ++$script:modes; $result }
        Check ($script:modes -eq 1 -and $sequence.NotExecuted.Count -eq 3)
    }
}
# Every worker/controller memory and handle budget is independently enforced.
foreach ($field in @('WorkerPeakWorkingSet','WorkerPeakCommit','ControllerPeakWorkingSet','ControllerPeakCommit','WorkerHandles','ControllerHandles')) {
    $mode = 'budget'
    $lease = [pscustomobject]@{ Consumed = $false; Process = [pscustomobject]@{ Tag = 'original' } }
    $result = Invoke-Batch3WorkerObservation -Lease $lease -OperatorConfirmed $true -Clock { [long]0 } -StartWorker { $true } -GetHandle { [IntPtr]123 } -GetPid { [int]123 } -GetStartTicks { [long]2 } -Sample {
        $s = [pscustomobject]@{ WorkerPeakWorkingSet = 1L; WorkerPeakCommit = 1L; WorkerHandles = 1L
            ControllerPeakWorkingSet = 1L; ControllerPeakCommit = 1L; ControllerHandles = 1L }
        $s.$field = if ($field -like '*Handles') { 1025L } else { [long](257MB) }; $s
    } -WaitForExit { throw 'budget must stop before waiting' } -GetExitCode { throw 'never' }
    Check ($result.FirstFailure -ceq 'resource_budget' -and $result.Polls -eq 0 -and $result.SettlementUnknown); ++$cases
}
# Source guards: the supervisor and the pure state machine never contain any
# automatic terminate/cleanup/retry operation; the new gates are present.
$source = Get-Content (Join-Path $PSScriptRoot '../diagnostics/host_a_supervisor.ps1') -Raw
Check ($source -notmatch '\b(Kill|Stop-Process|Remove-Item|Restart-Computer|LoadLibrary)\b')
Check ($source -match 'operator_confirmation' -and $source -match 'Invoke-Batch3HoldingHandoff')
$supervisionSource = Get-Content (Join-Path $PSScriptRoot '../diagnostics/worker_supervision.ps1') -Raw
Check ($supervisionSource -notmatch '\.(Dispose|Close|Kill)\(')
Check ($supervisionSource -notmatch '\b(Stop-Process|Remove-Item|Restart-Computer|LoadLibrary)\b')
Check ($supervisionSource -match 'prestart_unconfirmed' -and $supervisionSource -match 'start_false' -and $supervisionSource -match 'acknowledged_holding')
$dry = & (Join-Path $PSScriptRoot '../diagnostics/host_a_supervisor.ps1')
Check ($dry -match '^DRY RUN: zero workers')

# Phase B: bounded operator handoff. Receipt and acknowledgment windows are
# enforced with the clock; late results are never accepted; a receipt without
# acknowledgment is not holding; no callback of Phase A is reachable here.
foreach ($mode in @('ack_ok','receipt_declined','receipt_timeout','receipt_shape','receipt_throw','receipt_late','ack_declined','ack_timeout','ack_shape','ack_throw','ack_late','clock_back','clock_throw')) {
    $script:hTick = 0L; $script:hReceiptCalls = 0; $script:hAckCalls = 0; $script:receiptMs = -1; $script:ackMs = -1
    $lease = [pscustomobject]@{ Consumed = $true; Process = [pscustomobject]@{ Tag = 'original' } }
    $processRef = $lease.Process
    $observation = [pscustomobject]@{ WorkerResourcesReleased = $true; Code = 10; State = 'timed_out' }
    $handoff = Invoke-Batch3HoldingHandoff -Lease $lease -Observation $observation -ReceiptDeadlineMilliseconds 150 -HoldingDeadlineMilliseconds 150 -Clock {
        if ($mode -ceq 'clock_throw') { throw 'clock' }
        if ($mode -ceq 'clock_back') { return [long]-1 }
        [long]$script:hTick
    } -AwaitReceipt {
        param($ms); ++$script:hReceiptCalls; $script:receiptMs = $ms
        if ($mode -ceq 'receipt_throw') { throw 'synthetic receipt failure' }
        if ($mode -ceq 'receipt_declined') { return 'declined' }
        if ($mode -ceq 'receipt_timeout') { $script:hTick = 150L; return 'timeout' }
        if ($mode -ceq 'receipt_shape') { return 'yes' }
        if ($mode -ceq 'receipt_late') { $script:hTick = 200L; return 'received' }
        'received'
    } -AwaitAcknowledgment {
        param($ms); ++$script:hAckCalls; $script:ackMs = $ms
        if ($mode -ceq 'ack_throw') { throw 'synthetic ack failure' }
        if ($mode -ceq 'ack_declined') { return 'declined' }
        if ($mode -ceq 'ack_timeout') { return 'timeout' }
        if ($mode -ceq 'ack_shape') { return [pscustomobject]@{} }
        if ($mode -ceq 'ack_late') { $script:hTick = 400L; return 'acknowledged' }
        'acknowledged'
    }
    ++$cases
    CheckH ([object]::ReferenceEquals($lease.Process, $processRef)) "reference retained $mode"
    if ($mode -ceq 'ack_ok') {
        CheckH ($handoff.Code -eq 0 -and $handoff.HandoffState -ceq 'acknowledged_holding' -and $handoff.Received -and $handoff.AcknowledgedHolding) 'ack_ok'
        CheckH ($handoff.ReceiptDeadlineMilliseconds -eq 150 -and $handoff.HoldingDeadlineMilliseconds -eq 150 -and $script:receiptMs -eq 150 -and $script:ackMs -eq 150) 'window echo'
        CheckH ($handoff.RecoveryRequiresSeparateGrant -and $handoff.ElapsedMilliseconds -ge 0 -and $handoff.WorkerResourcesReleased) 'ack_ok meta'
    } else {
        CheckH ($handoff.Code -eq 10 -and $handoff.HandoffState -ceq 'failed' -and $null -ne $handoff.FirstFailure -and -not $handoff.AcknowledgedHolding) "handoff failed $mode"
    }
    if ($mode -eq 'receipt_declined') { CheckH ($handoff.FirstFailure -ceq 'handoff_receipt_declined' -and -not $handoff.Received -and $script:hAckCalls -eq 0) 'receipt_declined' }
    if ($mode -eq 'receipt_timeout') { CheckH ($handoff.FirstFailure -ceq 'handoff_receipt_timeout' -and $script:hAckCalls -eq 0) 'receipt_timeout' }
    if ($mode -eq 'receipt_late') { CheckH ($handoff.FirstFailure -ceq 'handoff_receipt_timeout' -and -not $handoff.Received -and $script:hAckCalls -eq 0) 'receipt_late' }
    if ($mode -eq 'receipt_shape') { CheckH ($handoff.FirstFailure -ceq 'handoff_receipt_shape' -and $script:hAckCalls -eq 0) 'receipt_shape' }
    if ($mode -eq 'receipt_throw') { CheckH ($handoff.FirstFailure -ceq 'handoff_receipt' -and $script:hAckCalls -eq 0) 'receipt_throw' }
    if ($mode -in @('ack_declined','ack_timeout','ack_shape','ack_throw','ack_late')) { CheckH ($handoff.Received) "$mode receipt retained" }
    if ($mode -eq 'ack_declined') { CheckH ($handoff.FirstFailure -ceq 'handoff_ack_declined') 'ack_declined' }
    if ($mode -eq 'ack_timeout') { CheckH ($handoff.FirstFailure -ceq 'handoff_ack_timeout') 'ack_timeout' }
    if ($mode -eq 'ack_late') { CheckH ($handoff.FirstFailure -ceq 'handoff_ack_timeout') 'ack_late' }
    if ($mode -eq 'ack_shape') { CheckH ($handoff.FirstFailure -ceq 'handoff_ack_shape') 'ack_shape' }
    if ($mode -eq 'ack_throw') { CheckH ($handoff.FirstFailure -ceq 'handoff_ack') 'ack_throw' }
    if ($mode -in @('clock_back','clock_throw')) { CheckH ($handoff.FirstFailure -ceq 'handoff_clock' -and $script:hReceiptCalls -eq 0) $mode }
}
# The handoff mirrors an unsettled observation without claiming release.
$script:hTick = 0L
$lease = [pscustomobject]@{ Consumed = $true; Process = [pscustomobject]@{ Tag = 'original' } }
$handoff = Invoke-Batch3HoldingHandoff -Lease $lease -Observation ([pscustomobject]@{ WorkerResourcesReleased = $false }) -ReceiptDeadlineMilliseconds 150 -HoldingDeadlineMilliseconds 150 -Clock { [long]$script:hTick } -AwaitReceipt { param($ms); 'received' } -AwaitAcknowledgment { param($ms); 'acknowledged' }
CheckH ($handoff.Code -eq 0 -and -not $handoff.WorkerResourcesReleased) 'ack mirrors unsettled resources'
++$cases
# A malformed observation record is rejected before any callback runs.
$script:hTick = 0L
$badShape = $false
try {
    $null = Invoke-Batch3HoldingHandoff -Lease ([pscustomobject]@{ Consumed = $true }) -Observation ([pscustomobject]@{ Nope = 1 }) -Clock { [long]$script:hTick } -AwaitReceipt { 'received' } -AwaitAcknowledgment { 'acknowledged' }
} catch { $badShape = $true }
CheckH ($badShape) 'malformed observation rejected'
++$cases

# Integrated: a frozen observation followed by a failed receipt means no
# re-observation, an unchanged first failure and the same retained reference.
$script:tick = 0L; $script:starts = 0; $script:getters = 0; $script:samples = 0; $script:waits = 0; $script:exitReads = 0
$lease = [pscustomobject]@{ Consumed = $false; Process = [pscustomobject]@{ Tag = 'original' } }
$processRef = $lease.Process
$result = Invoke-Batch3WorkerObservation -Lease $lease -OperatorConfirmed $true -DeadlineMilliseconds 150 -Clock { [long]$script:tick } -StartWorker { $script:tick = 150L; $true } -GetHandle { ++$script:getters; [IntPtr]123 } -GetPid { ++$script:getters; [int]123 } -GetStartTicks { ++$script:getters; [long]2 } -Sample { ++$script:samples; throw 'never' } -WaitForExit { param($ms); ++$script:waits; throw 'never' } -GetExitCode { ++$script:exitReads; throw 'never' }
CheckH ($result.State -ceq 'timed_out' -and $result.FirstFailure -ceq 'deadline' -and $script:getters -eq 0 -and $script:samples -eq 0 -and $script:waits -eq 0 -and $script:exitReads -eq 0) 'frozen before identity'
$observed = "$($script:getters,$script:samples,$script:waits,$script:exitReads)"
$handoff = Invoke-Batch3HoldingHandoff -Lease $lease -Observation $result -ReceiptDeadlineMilliseconds 150 -HoldingDeadlineMilliseconds 150 -Clock { [long]$script:tick } -AwaitReceipt { param($ms); 'received' } -AwaitAcknowledgment { param($ms); 'acknowledged' }
++$cases
CheckH ($handoff.HandoffState -ceq 'acknowledged_holding') 'integrated ack'
CheckH ("$($script:getters,$script:samples,$script:waits,$script:exitReads)" -ceq $observed) 'no re-observation during handoff'
CheckH ([object]::ReferenceEquals($lease.Process, $processRef) -and $result.SettlementUnknown) 'reference and settlement retained'
Write-Output "PASS: $cases process-free supervisor cases; prestart confirmation, separated start/identity facts with first-failure quarantine, all budgets, timeout/late exit, unknown settlement, bounded receipt/ack handoff without re-observation and immutable first failure, no subsequent Runner mode"
