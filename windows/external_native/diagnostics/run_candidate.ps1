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
    [Parameter(Mandatory)][string]$SourceManifest,
    [Parameter(Mandatory)][ValidatePattern('^[0-9a-fA-F]{64}$')][string]$SourceManifestHash,
    [Parameter(Mandatory)][ValidatePattern('^[0-9a-fA-F]{64}$')][string]$FreezeGateHash,
    [switch]$Execute,
    [switch]$VerifyFreezeOnly
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
if (-not $Execute -and -not $VerifyFreezeOnly) { Write-Output 'DRY RUN: no calls; requires a new exact batch grant'; exit 0 }
$preflightStage = 'mode'
try {
    if ($Execute -and $VerifyFreezeOnly) { throw 'Conflicting modes' }
    $preflightStage = 'artifact_hash'
    $sequence = Join-Path $PSScriptRoot 'runner_sequence.ps1'
    $freezeGate = Join-Path $PSScriptRoot 'frozen_source.ps1'
    foreach ($entry in @(@($Dll, $DllHash), @($Probe, $ProbeHash), @($PSCommandPath, $RunnerHash), @($sequence, $SequenceHash),
            @($SourceManifest, $SourceManifestHash), @($freezeGate, $FreezeGateHash))) {
        if ((Get-FileHash -LiteralPath $entry[0] -Algorithm SHA256).Hash -ne $entry[1]) { throw 'Frozen artifact mismatch' }
    }
    $repo = Split-Path (Split-Path (Split-Path $PSScriptRoot))
    $preflightStage = 'head'
    $head = & git -C $repo rev-parse HEAD
    if ($LASTEXITCODE -ne 0 -or $head -ne $FrozenCommit) { throw 'Frozen head mismatch' }
    $preflightStage = 'source_manifest'
    $manifest = Get-Content -LiteralPath $SourceManifest -Raw | ConvertFrom-Json
    if ($manifest.BaseCommit -ne $FrozenCommit) { throw 'Source manifest base mismatch' }
    $preflightStage = 'source_paths'
    $paths = @(& git -C $repo ls-files --cached --others -- windows/external_native)
    if ($LASTEXITCODE -ne 0) { throw 'Source enumeration failed' }
    . $freezeGate
    $preflightStage = 'source_hashes'
    Assert-CandidateSourceFreeze -Entries @($manifest.Entries) -ObservedPaths $paths -HashOf {
        param($path)
        (Get-FileHash -LiteralPath (Join-Path $repo $path) -Algorithm SHA256).Hash.ToLowerInvariant()
    }
    if ($VerifyFreezeOnly) { Write-Output 'PASS: frozen artifacts/head/source; no lab inspection or probe launch'; exit 0 }
    # A future grant must separately approve these preconditions and external
    # metadata inspection on the independently initialized B device. Every parent,
    # lock, identity and environment must match its reviewed inventory immediately
    # before invocation. No initialization/ACL repair/cleanup is supplied here.
    # The .NET known-folder path is for this gate only; Helper still uses its own
    # SHGetKnownFolderPath and exposes no path injection.
    $preflightStage = 'state_gate'
    $state = Join-Path ([Environment]::GetFolderPath('LocalApplicationData')) 'Shiroha/external/app/state'
    if (-not (Test-Path -LiteralPath $state) -or @(Get-ChildItem -LiteralPath $state -Force).Count -ne 0) {
        throw 'Candidate requires an existing empty state directory; never cleans it'
    }
} catch {
    Write-Output "STOP stage=$preflightStage actual_status=not_called attempted_native=0 attempted_processes=0"
    Write-Output 'not_executed modes=symbols,abi,assoc,bridge-denied'
    exit 10
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
