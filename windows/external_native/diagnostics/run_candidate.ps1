# Future candidate only; no Batch 2 defaults, no automatic experiment authority.
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$Dll,
    [Parameter(Mandatory)][string]$Probe,
    [Parameter(Mandatory)][ValidatePattern('^[0-9a-fA-F]{64}$')][string]$DllHash,
    [Parameter(Mandatory)][ValidatePattern('^[0-9a-fA-F]{64}$')][string]$ProbeHash,
    [Parameter(Mandatory)][ValidatePattern('^[0-9a-fA-F]{64}$')][string]$RunnerHash,
    [Parameter(Mandatory)][ValidatePattern('^[0-9a-fA-F]{64}$')][string]$SequenceHash,
    [Parameter(Mandatory)][ValidatePattern('^[0-9a-fA-F]{40}$')][string]$FrozenCommit,
    [switch]$Execute
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
if (-not $Execute) { Write-Output 'DRY RUN: no calls; requires a new exact batch grant'; exit 0 }
$sequence = Join-Path $PSScriptRoot 'runner_sequence.ps1'
foreach ($entry in @(@($Dll, $DllHash), @($Probe, $ProbeHash), @($PSCommandPath, $RunnerHash), @($sequence, $SequenceHash))) {
    if ((Get-FileHash -LiteralPath $entry[0] -Algorithm SHA256).Hash -ne $entry[1]) { throw 'Frozen artifact mismatch' }
}
$repo = Split-Path (Split-Path (Split-Path $PSScriptRoot))
$head = & git -C $repo rev-parse HEAD
if ($LASTEXITCODE -ne 0 -or $head -ne $FrozenCommit) { throw 'Frozen head mismatch' }
$drift = & git -C $repo diff $FrozenCommit -- windows/external_native
if ($LASTEXITCODE -ne 0 -or $drift) { throw 'Native source drift' }
# A future grant must separately approve these preconditions and external
# metadata inspection. Existing Batch 2 leftovers deliberately block this runner.
$state = Join-Path $env:LOCALAPPDATA 'Shiroha/external/app/state'
if (-not (Test-Path -LiteralPath $state) -or @(Get-ChildItem -LiteralPath $state -Force).Count -ne 0) {
    throw 'Candidate requires an existing empty state directory; never cleans it'
}
. $sequence
$result = Invoke-CandidateSequence -InvokeMode {
    param($mode)
    # Probe emits only status/count/resource facts, never paths or payloads.
    $previous = $ErrorActionPreference
    try {
        $ErrorActionPreference = 'Continue'
        $LASTEXITCODE = $null
        $output = & $Probe $mode $Dll 2>&1
        $code = if ($null -eq $LASTEXITCODE) { -1 } else { $LASTEXITCODE }
    } finally { $ErrorActionPreference = $previous }
    foreach ($line in $output) { Write-Host $line }
    [pscustomobject]@{ Code = $code }
}
$result | ConvertTo-Json -Compress | Write-Host
exit $result.Code
