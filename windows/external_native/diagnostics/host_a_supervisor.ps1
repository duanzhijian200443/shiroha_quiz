# Candidate only. This file is never called with -Observe during L0 validation.
[CmdletBinding()]
param([string]$ScopeFile, [string]$ScopeHash, [string]$ReaderHash, [string]$ContractHash,
      [string]$PolicyHash, [string]$ReaderAssembly, [string]$ReaderAssemblyHash,
      [string]$WorkerHash, [string]$SupervisorHash, [string]$SupervisionHash,
      [ValidateRange(1,30000)][int]$DeadlineMilliseconds = 15000,
      [ValidateRange(1,300000)][int]$ReceiptDeadlineMilliseconds = 60000,
      [ValidateRange(1,300000)][int]$HoldingDeadlineMilliseconds = 60000,
      [switch]$OperatorConfirmed,
      [switch]$Observe)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
if (-not $Observe) { Write-Output 'DRY RUN: zero workers; separate Batch 3-A0 grant required'; return }
if (-not $OperatorConfirmed) { Write-Output 'STOP stage=operator_confirmation attempted=0 runtime_authority=none'; exit 10 }
$stage = 'freeze'
try {
    $worker = Join-Path $PSScriptRoot 'host_a_preflight.ps1'
    $supervision = Join-Path $PSScriptRoot 'worker_supervision.ps1'
    foreach ($entry in @(@($PSCommandPath,$SupervisorHash), @($worker,$WorkerHash), @($supervision,$SupervisionHash),
        @($ScopeFile,$ScopeHash), @($ReaderAssembly,$ReaderAssemblyHash),
        @((Join-Path $PSScriptRoot 'host_a_metadata.cs'),$ReaderHash),
        @((Join-Path $PSScriptRoot 'metadata_contract.cs'),$ContractHash),
        @((Join-Path $PSScriptRoot 'host_a_policy.ps1'),$PolicyHash))) {
        if ($entry[1] -cnotmatch '^[0-9a-f]{64}$' -or
            (Get-FileHash -LiteralPath $entry[0] -Algorithm SHA256).Hash.ToLowerInvariant() -cne $entry[1]) { throw 'freeze' }
    }
    . (Join-Path $PSScriptRoot 'host_a_policy.ps1')
    $null = Get-Batch3Layout (Get-Content -LiteralPath $ScopeFile -Raw | ConvertFrom-Json)
    . $supervision
} catch { Write-Output "STOP stage=$stage attempted=0 runtime_authority=none"; exit 10 }
# Bounded console confirmation for the candidate handoff. Any unavailable or
# redirected console fails closed as a timeout; no other action exists here.
function Read-Batch3HandoffKey {
    param([string]$SuccessKey, [string]$SuccessToken, [int]$TimeoutMs, [scriptblock]$Clock)
    $deadline = (& $Clock) + $TimeoutMs
    try {
        while ((& $Clock) -lt $deadline) {
            if (-not [Console]::IsInputRedirected -and $Host.UI.RawUI.KeyAvailable) {
                $key = $Host.UI.RawUI.ReadKey('NoEcho,IncludeKeyDown')
                $char = [string]$key.Character
                if ($char -ieq 'd') { return 'declined' }
                if ($char -ieq $SuccessKey) { return $SuccessToken }
            }
            Start-Sleep -Milliseconds 100
        }
    } catch { return 'timeout' }
    return 'timeout'
}
# Retain this lease/reference on failure. No redirected output buffers or reader
# threads: frozen worker emits its bounded redacted record to inherited stdout.
# Timely exit is distinct from capture acceptance. No native helper is loaded.
$script:Batch3A0WorkerLease = [pscustomobject]@{ Consumed = $false; Process = $null; Pid = $null; StartedUtcTicks = $null }
$controller = [System.Diagnostics.Process]::GetCurrentProcess()
$timer = [System.Diagnostics.Stopwatch]::StartNew()
$result = Invoke-Batch3WorkerObservation -Lease $script:Batch3A0WorkerLease -OperatorConfirmed $true -DeadlineMilliseconds $DeadlineMilliseconds -Clock {
    [long]$timer.ElapsedMilliseconds
} -StartWorker {
    $p = [System.Diagnostics.Process]::new()
    $script:Batch3A0WorkerLease.Process = $p # Own before attempting launch.
    $p.StartInfo.FileName = Join-Path $env:WINDIR 'System32/WindowsPowerShell/v1.0/powershell.exe'
    $p.StartInfo.UseShellExecute = $false; $p.StartInfo.CreateNoWindow = $true
    $tokens = @('-NoLogo','-NoProfile','-NonInteractive','-File',$worker,
        '-ScopeFile',$ScopeFile,'-ScopeHash',$ScopeHash,'-ReaderHash',$ReaderHash,'-ContractHash',$ContractHash,
        '-PolicyHash',$PolicyHash,'-ReaderAssembly',$ReaderAssembly,'-ReaderAssemblyHash',$ReaderAssemblyHash,'-Inspect')
    # Frozen filesystem paths only, using Windows argv quoting. Reject embedded
    # quote/newline rather than permit another command/switch or inline code.
    foreach ($token in $tokens) { if ($token -match '["\r\n]' -or $token.EndsWith('\')) { throw 'argument' } }
    $p.StartInfo.Arguments = (($tokens | ForEach-Object { '"' + $_ + '"' }) -join ' ')
    [bool]$p.Start() # Only the actual launch result; identity getters run separately.
} -GetHandle {
    [System.IntPtr]$script:Batch3A0WorkerLease.Process.Handle
} -GetPid {
    [int]$script:Batch3A0WorkerLease.Process.Id
} -GetStartTicks {
    [long]$script:Batch3A0WorkerLease.Process.StartTime.ToUniversalTime().Ticks
} -WaitForExit {
    param($ms); $script:Batch3A0WorkerLease.Process.WaitForExit($ms)
} -GetExitCode { [int]$script:Batch3A0WorkerLease.Process.ExitCode } -Sample {
    $p = $script:Batch3A0WorkerLease.Process
    $p.Refresh(); $controller.Refresh()
    [pscustomobject]@{
        WorkerPeakWorkingSet = [long]$p.PeakWorkingSet64; WorkerPeakCommit = [long]$p.PeakPagedMemorySize64
        WorkerHandles = [long]$p.HandleCount
        ControllerPeakWorkingSet = [long]$controller.PeakWorkingSet64; ControllerPeakCommit = [long]$controller.PeakPagedMemorySize64
        ControllerHandles = [long]$controller.HandleCount
    }
}
# Bounded operator handoff: receipt and holding acknowledgment within candidate
# windows pending the ruled lifecycle contract. No worker observation and no
# automatic action happens on any path of this phase.
$handoff = $null
if ($result.State -cne 'prestart_unconfirmed') {
    $handoff = Invoke-Batch3HoldingHandoff -Lease $script:Batch3A0WorkerLease -Observation $result -Clock {
        [long]$timer.ElapsedMilliseconds
    } -ReceiptDeadlineMilliseconds $ReceiptDeadlineMilliseconds -HoldingDeadlineMilliseconds $HoldingDeadlineMilliseconds -AwaitReceipt {
        param($ms)
        Write-Host 'HANDOFF: frozen observation requires operator receipt (r) or decline (d) within the receipt window'
        Read-Batch3HandoffKey -SuccessKey 'r' -SuccessToken 'received' -TimeoutMs $ms -Clock { [long]$timer.ElapsedMilliseconds }
    } -AwaitAcknowledgment {
        param($ms)
        Write-Host 'HANDOFF: continued holding responsibility requires acknowledgment (h) or decline (d) within the holding window'
        Read-Batch3HandoffKey -SuccessKey 'h' -SuccessToken 'acknowledged' -TimeoutMs $ms -Clock { [long]$timer.ElapsedMilliseconds }
    }
}
[pscustomobject]@{ Observation = $result; Handoff = $handoff } | ConvertTo-Json -Depth 5
if ($result.Code -ne 0) { exit $result.Code }
if ($null -eq $handoff -or $handoff.Code -ne 0) { exit 10 }
exit 0
