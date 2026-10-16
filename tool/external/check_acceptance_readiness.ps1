[CmdletBinding()]
param([switch]$SelfTest)

# G0-L0 only. Reads fixed repository inputs; never loads a DLL, probes a device,
# launches a process, writes files, contacts a service or admits an experiment.
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
$planPath = Join-Path $root 'docs/product/agent-refactor/windows-host-acceptance-plan.json'
$workflow = [IO.File]::ReadAllText((Join-Path $root '.github/workflows/pr-contract-checks.yml'))
$plan = [IO.File]::ReadAllText($planPath) | ConvertFrom-Json -AsHashtable

function Require([bool]$Condition, [string]$Code) {
    if (!$Condition) { throw "readiness:$Code" }
}
function Has-Fields([System.Collections.IDictionary]$Value, [string[]]$Fields) {
    foreach ($field in $Fields) {
        Require ($Value.Contains($field) -and $null -ne $Value[$field] -and
            ![string]::IsNullOrWhiteSpace([string]$Value[$field])) 'required_field'
    }
}
function Assert-RepoPath([string]$Path, [string]$Prefix) {
    Require ($Path.StartsWith($Prefix) -and $Path -notmatch '[\\:]|(^|/)\.\.(/|$)' -and
        $Path -match '^[a-zA-Z0-9_./-]+$') 'repository_path'
    Require ([IO.File]::Exists((Join-Path $root $Path))) 'missing_source'
}
function Assert-Plan([System.Collections.IDictionary]$Value) {
    Has-Fields $Value @('schemaVersion', 'purpose', 'authority', 'guide', 'executionAuthorized',
        'invariants', 'environment', 'ownership', 'failurePolicy', 'l2Budget',
        'dependencyOrder', 'matrix', 'requests', 'evidenceFields', 'hostABatch3')
    Require ($Value.schemaVersion -eq 1 -and $Value.executionAuthorized -ceq $false) 'not_authorized'
    Require ($Value.authority -ceq 'docs/product/agent-refactor/windows-host-security-readiness.md') 'authority'
    Require ($Value.guide -ceq 'docs/product/agent-refactor/windows-host-acceptance-preparation.md') 'guide'
    Assert-RepoPath $Value.authority 'docs/product/agent-refactor/'
    Assert-RepoPath $Value.guide 'docs/product/agent-refactor/'
    $states = @{ 'HOST_STABILITY_HALT'='ACTIVE'; TRANSPORT='BLOCKED'; 'AR-R6A'='NOT_ACCEPTED';
        'REAL WINDOWS'='PENDING'; 'FORMAL ACCEPTANCE'='PENDING' }
    foreach ($name in $states.Keys) { Require ($Value.invariants[$name] -ceq $states[$name]) 'invariant' }
    Has-Fields $Value.environment @('device', 'independentKernelEvidence', 'osEditionBuildPatch',
        'architecture', 'toolchainAndLockfile', 'sourceSha', 'baseSha', 'artifactSha256Manifest',
        'testRoot', 'rootOwnership', 'principalA', 'principalBAndDistinctSid',
        'resourceMeasurementMethod', 'osPeakMemoryLimitBytes', 'osHandleLimit',
        'backupOperator', 'recoveryOperator', 'cleanupOperator', 'verifier', 'reviewer')
    # This tracked template contains no selected device/path/operator or approval.
    foreach ($name in $Value.environment.Keys | Where-Object { $_ -ne 'target' }) {
        Require ($Value.environment[$name] -ceq 'REQUIRES USER DECISION') 'unselected_environment'
    }
    Has-Fields $Value.ownership @('evidenceOwner', 'requireIndependentReviewer', 'requireFixedTargetVerifier')
    Require ($Value.ownership.requireIndependentReviewer -ceq $true -and
        $Value.ownership.requireFixedTargetVerifier -ceq $true) 'independence'
    Has-Fields $Value.failurePolicy @('codes', 'stop', 'recovery', 'privacy')
    Require ($Value.failurePolicy.codes.Count -eq 12) 'failure_codes'
    $budgets = @{ sockets=8; pendingHandshakes=2; activePipelines=2; protocolBytes=16777216;
        decodedStringBytes=33554432; outputBytes=524288; handshakeSeconds=5;
        noProgressSeconds=2; frameSeconds=10; requestsPerConnection=1 }
    foreach ($name in $budgets.Keys) { Require ($Value.l2Budget[$name] -eq $budgets[$name]) 'budget' }
    $order = @('X3','X1','X0','X2','X6','X7_PRIMITIVE','X4','X7_SETTLEMENT','X5','X8','X9','X10','X11','X12')
    Require (($Value.dependencyOrder -join ',') -ceq ($order -join ',')) 'dependency_order'
    Require ($Value.matrix.Count -eq 13) 'matrix_count'
    $minimum = @(@('X1','X3'), @('X3'), @('X0','X1','X3'), @(),
        @('X0','X1','X2','X3','X6','X7_PRIMITIVE'), @('X4','X7_SETTLEMENT'),
        @('X0','X1','X2','X3'), @('X0','X1','X2','X3','X6'),
        @('X4','X5','X6','X7_SETTLEMENT'), @(), @(), @('X3','X7_SETTLEMENT'),
        @('X1','X2','X3','X4','X5','X6','X7_SETTLEMENT','X8','X9','X10','X11'))
    for ($i = 0; $i -lt 13; $i++) {
        $row = $Value.matrix[$i]
        Has-Fields $row @('id', 'trial', 'contractSections', 'responsibility', 'state', 'formalTier',
            'localScope', 'environmentRef', 'ownersRef', 'failurePolicyRef', 'source',
            'offlineTests', 'offlineEvidence', 'frozenCriterion', 'windowsTrial', 'success', 'blockerClass')
        Require ($row.id -ceq "A$i" -and $row.trial -ceq "X$i") 'matrix_identity'
        Require ($row.state -ceq 'WINDOWS_PENDING' -and $row.formalTier -ceq 'G0-I') 'pending_only'
        Require (($row.contractSections -join ',') -ceq '6,7,9.F,21') 'contract_sections'
        Require ($row.environmentRef -ceq 'environment' -and $row.ownersRef -ceq 'ownership' -and
            $row.failurePolicyRef -ceq 'failurePolicy') 'row_references'
        $subsets = @('G0-L2','G0-L1','G0-L2','G0-L1','','G0-L1,G0-L2','','G0-L2','','','','G0-L1,G0-L2','G0-L1')
        Require (($row.localSubsets -join ',') -ceq $subsets[$i]) 'local_subset'
        Require ($row.blockerClass -cin @('MUST_FIX_BEFORE_L1','MUST_FIX_BEFORE_L2','MUST_FIX_BEFORE_G0-I')) 'blocker_class'
        Require (($row.dependencies -join ',') -ceq ($minimum[$i] -join ',')) 'dependencies'
        if ($i -eq 7) { Require (($row.businessSettlementRequires -join ',') -ceq 'X4') 'settlement_phase' }
        foreach ($path in $row.source) { Assert-RepoPath $path 'lib/' }
        foreach ($path in $row.offlineTests) {
            Assert-RepoPath $path 'test/'
            Require ([regex]::Matches($workflow, [regex]::Escape("'$path'")).Count -eq 1) 'standing_test'
        }
    }
    $ids = @('L1-CRYPTO','L1-OBJECTS','L1-STORE','L1-RELEASE','L2-AUTH','G0-I-FORMAL')
    Require ($Value.requests.Count -eq $ids.Count) 'request_count'
    for ($i = 0; $i -lt $ids.Count; $i++) {
        $request = $Value.requests[$i]
        Has-Fields $request @('id','tier','state','executionAuthorized','environmentRef','ownersRef',
            'failurePolicyRef','dependsOn','allowedObjects','operations','maxSecondsCandidate',
            'memoryLimitBytes','handleLimit','backupAndRecovery','cleanup','grantAndTimeWindow','resultFormat')
        Require ($request.id -ceq $ids[$i] -and $request.state -ceq 'DRAFT_NOT_AUTHORIZED' -and
            $request.executionAuthorized -ceq $false) 'request_authority'
        $tier = if ($i -lt 4) { 'G0-L1' } elseif ($i -eq 4) { 'G0-L2' } else { 'G0-I' }
        Require ($request.tier -ceq $tier -and $request.maxSecondsCandidate -gt 0 -and
            $request.maxSecondsCandidate -le 600) 'request_scope'
        Require ($request.environmentRef -ceq 'environment' -and $request.ownersRef -ceq 'ownership' -and
            $request.failurePolicyRef -ceq 'failurePolicy') 'request_references'
        Require ($request.memoryLimitBytes -ceq 'REQUIRES USER DECISION' -and
            $request.handleLimit -ceq 'REQUIRES USER DECISION' -and
            $request.grantAndTimeWindow -ceq 'REQUIRES USER DECISION') 'unresolved_grant'
    }
    Require ($Value.requests[4].budgetRef -ceq 'l2Budget' -and
        $Value.requests[4].port -ceq 'REQUIRES USER DECISION') 'l2_bind_budget'
    Require ($Value.requests[5].perTrialOperationsCountsAndResources -ceq 'REQUIRES USER DECISION') 'formal_ledger'
    $l1Crypto = $Value.requests[0]
    Has-Fields $l1Crypto @('isolatedHarness', 'offlineHarnessTest', 'allowedNativeSymbols', 'defaultEntryGate')
    Require ($l1Crypto.isolatedHarness.Count -eq 2 -and
        $l1Crypto.defaultEntryGate -ceq 'l1_crypto_execution_not_authorized') 'l1_crypto_harness'
    foreach ($path in $l1Crypto.isolatedHarness) { Assert-RepoPath $path 'windows/external_native/diagnostics/' }
    Assert-RepoPath $l1Crypto.offlineHarnessTest 'windows/external_native/tests/'
    $allowedL1Symbols = @('shiroha_native_abi_version', 'shiroha_native_buffer_alloc', 'shiroha_native_buffer_free',
        'shiroha_native_ecdsa_generate_key', 'shiroha_native_ecdsa_sign_digest', 'shiroha_native_ecdsa_verify_digest',
        'shiroha_native_peer_certificate_policy')
    Require ($l1Crypto.allowedNativeSymbols.Count -eq 7 -and
        @(Compare-Object $allowedL1Symbols @($l1Crypto.allowedNativeSymbols)).Count -eq 0) 'l1_crypto_symbols'
    Has-Fields $l1Crypto @('admissionModel', 'nativeObservation', 'offlineAdmissionTests',
        'abiAttemptBudget', 'nativeAttemptBudget', 'admissionEvidenceClass', 'realAdmission', 'resourceObservation')
    Assert-RepoPath $l1Crypto.admissionModel 'windows/external_native/diagnostics/'
    Assert-RepoPath $l1Crypto.nativeObservation 'windows/external_native/diagnostics/'
    Require ($l1Crypto.offlineAdmissionTests.Count -eq 2) 'l1_admission_tests'
    foreach ($path in $l1Crypto.offlineAdmissionTests) { Assert-RepoPath $path 'windows/external_native/tests/' }
    $abiBudget = @{ abi=1; generate=3; encodeSign=3; verify=6; policy=3; allocation=45; free=45; total=106; maxLiveBuffers=5 }
    $nativeBudget = @{ provider_open=12; key_generate=3; key_finalize=3; key_export=3; key_import=9;
        sign=3; verify=6; provider_close=12; key_destroy=12; certificate_create=3; certificate_free=3;
        decode=20; local_free=20; time=3 }
    foreach ($pair in @(@($abiBudget, $l1Crypto.abiAttemptBudget), @($nativeBudget, $l1Crypto.nativeAttemptBudget))) {
        Require ($pair[0].Count -eq $pair[1].Count) 'l1_attempt_budget'
        foreach ($name in $pair[0].Keys) {
            Require (($pair[1][$name] -is [long] -or $pair[1][$name] -is [int]) -and
                $pair[1][$name] -ceq $pair[0][$name]) 'l1_attempt_budget'
        }
    }
    Require ($l1Crypto.admissionEvidenceClass -ceq 'OFFLINE' -and
        $l1Crypto.realAdmission -ceq 'BLOCKED_WINDOWS_IDENTITY_ATOMIC_CONSUMPTION_SUPERVISION') 'l1_real_admission_blocked'
    Require ($l1Crypto.resourceObservation.samples -eq 18) 'l1_observation'
    Has-Fields $l1Crypto @('windowsAdmission')
    $windows = $l1Crypto.windowsAdmission
    Has-Fields $windows @('scope','executionAuthorized','source','offlineTest','sourceGuard',
        'evidenceClass','backend','realBackend','crossProcessDurability','candidateVolume','evidenceFields')
    Require ($windows.scope -ceq 'G0-L0 SOURCE / COMPILE / FAKE ONLY' -and
        $windows.executionAuthorized -ceq $false -and $windows.evidenceClass -ceq 'OFFLINE' -and
        $windows.backend -ceq 'FAKE' -and $windows.realBackend -ceq 'COMPILE_ONLY_STOP' -and
        $windows.crossProcessDurability -ceq 'NOT_PROVEN' -and $windows.candidateVolume -ceq 'C:') 'e3_scope'
    Require ($windows.source.Count -eq 3 -and $windows.evidenceFields.Count -eq 14) 'e3_inventory'
    foreach ($path in $windows.source) { Assert-RepoPath $path 'windows/external_native/diagnostics/' }
    Assert-RepoPath $windows.offlineTest 'windows/external_native/tests/'
    Assert-RepoPath $windows.sourceGuard 'tool/external/'
    foreach ($field in @('approvalSource','signerKeyTrustAndCustody','exactNewRootAndObjects',
        'exactAccountSidAndToken','selectedDevice','experimentWindow','workingSetLimitBytes',
        'commitLimitBytes','sampledHandleLimit','stopRecoveryEvidenceOwners','finalTargetReviewerVerifier',
        'durableRequestJournal','processIpcHandleEnvironmentPlan')) {
        Has-Fields $windows @($field)
        Require ($windows[$field] -ceq 'REQUIRES USER DECISION') 'e3_unapproved_parameter'
    }
    foreach ($name in @('workingSetLimitBytes', 'commitLimitBytes', 'sampledHandleLimit')) {
        Require ($l1Crypto.resourceObservation[$name] -ceq 'REQUIRES USER DECISION') 'l1_unapproved_ceiling'
    }
    Require ($Value.hostABatch3.state -ceq 'BLOCKED' -and
        $Value.hostABatch3.metadataCaptureAuthorized -ceq $false -and
        $Value.hostABatch3.oldRootAccessAuthorized -ceq $false) 'host_a_blocked'
    foreach ($field in @('testId','sourceSha','baseSha','artifactSha256','osToolchainId','deviceId',
        'trialId','expectedCriterion','actualState','resourceCounts','elapsedMilliseconds','failureCode',
        'verifier','reviewer','verdict','stopResult','recoveryResult')) {
        Require ($field -cin $Value.evidenceFields) 'evidence_field'
    }
}

Assert-Plan $plan
$guide = [IO.File]::ReadAllText((Join-Path $root $plan.guide))
for ($i = 0; $i -lt 13; $i++) {
    Require ([regex]::Matches($guide, "(?m)^\| A$i / X$i \|[^\r\n]*\| WINDOWS_PENDING \|\r?$").Count -eq 1) 'guide_matrix'
}
# Source-only ABI comparison. Compiled exports/imports remain the existing
# Native offline gate's responsibility; this check never opens a DLL.
$header = [IO.File]::ReadAllText((Join-Path $root 'windows/external_native/shiroha_external_native.h'))
$bindings = [IO.File]::ReadAllText((Join-Path $root 'lib/data/external/native/external_native_bindings.dart'))
$nativeGate = [IO.File]::ReadAllText((Join-Path $root 'windows/external_native/check_offline.ps1'))
$declared = @([regex]::Matches($header, '(shiroha_native_[a-z_]+)\s*\(') | ForEach-Object { $_.Groups[1].Value } | Sort-Object -Unique)
$bound = @([regex]::Matches($bindings, "'(shiroha_native_[a-z_]+)'") | ForEach-Object { $_.Groups[1].Value } | Sort-Object -Unique)
$expectedArray = [regex]::Match($nativeGate, '(?s)\$expected\s*=\s*@\((.*?)\)')
Require $expectedArray.Success 'native_gate_inventory'
$expected = @([regex]::Matches($expectedArray.Groups[1].Value, "'(shiroha_native_[a-z_]+)'") | ForEach-Object { $_.Groups[1].Value } | Sort-Object -Unique)
Require ($header.Contains('#define SHIROHA_NATIVE_ABI_VERSION 3u') -and $declared.Count -eq 27 -and
    @(Compare-Object $declared $bound).Count -eq 0 -and @(Compare-Object $declared $expected).Count -eq 0) 'abi_source_inventory'
Write-Output 'PASS: G0-L0 plan structure; 13 WINDOWS_PENDING rows; 6 unapproved drafts; 27 ABI-3 source symbols. NO EXPERIMENT AUTHORITY.'

if ($SelfTest) {
    $mutations = @(
        { param($p) $p.matrix = $p.matrix[0..11] },
        { param($p) $p.matrix[1].trial = 'X0' },
        { param($p) $p.matrix[0].state = 'PASS' },
        { param($p) $p.matrix[4].dependencies = @('X0','X1','X2','X3','X6') },
        { param($p) $p.matrix[7].businessSettlementRequires = @() },
        { param($p) $p.executionAuthorized = $true },
        { param($p) $p.requests[4].executionAuthorized = $true },
        { param($p) $p.l2Budget.sockets = 9 },
        { param($p) $p.environment.Remove('reviewer') },
        { param($p) $p.failurePolicy.Remove('recovery') },
        { param($p) $p.hostABatch3.oldRootAccessAuthorized = $true },
        { param($p) $p.requests[0].operations = @() },
        { param($p) $p.requests[0].Remove('handleLimit') },
        { param($p) $p.requests[0].maxSecondsCandidate = 0 },
        { param($p) $p.matrix[0].source = @('lib/../../outside.dart') },
        { param($p) $p.matrix[0].offlineTests = @('test/not_in_ci_test.dart') },
        { param($p) $p.environment.device = 'unilaterally-selected-device' },
        { param($p) $p.dependencyOrder = @('X4','X7_PRIMITIVE') },
        { param($p) $p.evidenceFields = @('testId') },
        { param($p) $p.requests[5].Remove('perTrialOperationsCountsAndResources') },
        { param($p) $p.requests[0].allowedNativeSymbols = @('shiroha_native_owner_acquire') },
        { param($p) $p.requests[0].defaultEntryGate = 'bypassed' },
        { param($p) $p.requests[0].abiAttemptBudget.allocation = 46 },
        { param($p) $p.requests[0].abiAttemptBudget.total = 105 },
        { param($p) $p.requests[0].nativeAttemptBudget.local_free = 19 },
        { param($p) $p.requests[0].resourceObservation.commitLimitBytes = 1024 },
        { param($p) $p.requests[0].realAdmission = 'ENABLED' },
        { param($p) $p.requests[0].admissionEvidenceClass = 'LOCAL-L1' },
        { param($p) $p.requests[0].windowsAdmission.executionAuthorized = $true },
        { param($p) $p.requests[0].windowsAdmission.crossProcessDurability = 'PROVEN' },
        { param($p) $p.requests[0].windowsAdmission.approvalSource = 'json-user-approved' },
        { param($p) $p.requests[0].windowsAdmission.commitLimitBytes = 2048 },
        { param($p) $p.requests[0].windowsAdmission.realBackend = 'ENABLED' },
        { param($p) $p.requests[0].windowsAdmission.Remove('exactAccountSidAndToken') }
    )
    $count = 0
    foreach ($mutate in $mutations) {
        $copy = $plan | ConvertTo-Json -Depth 30 | ConvertFrom-Json -AsHashtable
        & $mutate $copy | Out-Null
        $rejected = $false
        try { Assert-Plan $copy } catch { $rejected = $true }
        Require $rejected 'mutation_not_rejected'
        $count++
    }
    Write-Output "PASS: $count in-memory rejection cases; no tracked or runtime inputs modified."
}
