[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
$scriptPath = Join-Path $root 'tool/ci/summarize_flutter_test_times.ps1'
$workflowPath = Join-Path $root '.github/workflows/pr-contract-checks.yml'
$fixture = Join-Path $root ('.dart_tool/ci-timing-fixture-' + [Guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $fixture | Out-Null
$inputPath = Join-Path $fixture 'events.jsonl'
$outputPath = Join-Path $fixture 'summary.json'
function Assert-True([bool]$Condition, [string]$Message) {
    if (!$Condition) { throw "Assertion failed: $Message" }
}
function Write-Events([object[]]$Events) {
    $lines = @($Events | ForEach-Object { ConvertTo-Json -InputObject $_ -Depth 5 -Compress })
    [IO.File]::WriteAllLines($inputPath, $lines, [Text.UTF8Encoding]::new($false))
}
function Expect-Rejected([object[]]$Events) {
    Write-Events $Events
    $rejected = $false
    try { & $scriptPath -InputPath $inputPath -OutputPath $outputPath -ProjectRoot $root | Out-Null }
    catch { $rejected = $true }
    Assert-True $rejected 'invalid timing events must fail closed'
}
$events = @(
    @{type='suite';time=0;suite=@{id=0;path=(Join-Path $root 'test/widget_test.dart')}},
    @{type='testStart';time=10;test=@{id=1;suiteID=0;name='synthetic-private-message'}},
    @{type='print';time=15;message='synthetic-private-message'},
    @{type='testDone';time=110;testID=1;result='success'},
    @{type='testStart';time=120;test=@{id=2;suiteID=0;name='synthetic-private-message'}},
    @{type='testDone';time=170;testID=2;result='success'},
    @{type='done';time=180;success=$true}
)
Write-Events $events
& $scriptPath -InputPath $inputPath -OutputPath $outputPath -ProjectRoot $root | Out-Null
$summary = Get-Content -LiteralPath $outputPath -Raw | ConvertFrom-Json
Assert-True ($summary.successful -and $summary.elapsedMilliseconds -eq 180) 'whole-run metadata'
Assert-True ($summary.suites.Count -eq 1) 'one suite retained'
Assert-True ($summary.suites[0].path -eq 'test/widget_test.dart') 'portable relative path'
Assert-True ($summary.suites[0].suiteMilliseconds -eq 160) 'suite span includes gaps'
Assert-True ($summary.suites[0].testMilliseconds -eq 150) 'sum exact test intervals'
$serialized = Get-Content -LiteralPath $outputPath -Raw
Assert-True (!$serialized.Contains('synthetic-private-message')) 'messages and test names redacted'
Assert-True (!$serialized.Contains($root.Replace('\', '\\'))) 'absolute root not exported'

$failure = @($events[0..5]) + @(@{type='done';time=180;success=$false})
Write-Events $failure
& $scriptPath -InputPath $inputPath -OutputPath $outputPath -ProjectRoot $root | Out-Null
Assert-True (!(Get-Content -LiteralPath $outputPath -Raw | ConvertFrom-Json).successful) 'failed run stays failed'
Expect-Rejected @($events[0..5])
Expect-Rejected (@($events[0..1]) + @(@{type='testDone';time=9;testID=1}, @{type='done';time=20;success=$true}))
Expect-Rejected (@($events) + @(@{type='testDone';time=190;testID=1}))
Expect-Rejected @(@{type='suite';time=0;suite=@{id=0;path=(Join-Path $root '../outside_test.dart')}})

$workflow = Get-Content -LiteralPath $workflowPath -Raw
$contracts = [regex]::Match($workflow, '(?ms)^  contracts:\r?\n(.*?)(?=^  [a-z_]+:|\z)')
Assert-True $contracts.Success 'contracts job exists'
Assert-True ($contracts.Value -match '(?m)^    needs: impact\r?$') 'contract shards consume only the plan'
Assert-True (!($contracts.Value -match '(?m)^      - static\r?$')) 'contract shards do not depend on static'
$sourceGate = $contracts.Value.IndexOf('run: ./tool/external/check_bootstrap_source.ps1')
$vectorGate = $contracts.Value.IndexOf('run: python3 tool/external/verify_bootstrap_vectors.py')
$testRun = $contracts.Value.IndexOf('& flutter test --concurrency=1 --file-reporter')
Assert-True ($sourceGate -ge 0 -and $vectorGate -gt $sourceGate -and $testRun -gt $vectorGate) 'each shard guards source and public vectors before tests'

$verify = [regex]::Match($workflow, '(?ms)^  verify:\r?\n(.*?)(?=^  [a-z_]+:|\z)')
Assert-True ($verify.Success -and $verify.Value.Contains('    if: always()')) 'aggregate runs after upstream failures'
$requiredJobs = @('impact', 'static', 'train_c_finalization_parity', 'contracts', 'windows_native')
foreach ($job in $requiredJobs) {
    Assert-True ($verify.Value.Contains("      - $job")) "aggregate waits for $job"
}
Assert-True ($verify.Value.Contains('tool/ci/verify_ci_plan.py')) 'aggregate recomputes the plan and reuse evidence'
Assert-True ($verify.Value.Contains('name: ci-impact-plan')) 'aggregate consumes the uploaded plan'
foreach ($pair in @(
    @('impact', 'RESULT_IMPACT'), @('static', 'RESULT_STATIC'), @('windows_native', 'RESULT_WINDOWS_NATIVE'),
    @('train_c_finalization_parity', 'RESULT_TRAIN_C_FINALIZATION_PARITY'), @('contracts', 'RESULT_CONTRACTS'))) {
    Assert-True ($verify.Value.Contains(('${{ needs.' + $pair[0] + '.result }}')) -and
        $verify.Value.Contains($pair[1])) "aggregate receives the $($pair[0]) result"
}

$observer = [regex]::Match($workflow, '(?ms)^  impact:\r?\n(.*?)(?=^  [a-z_]+:|\z)')
Assert-True $observer.Success 'impact job exists'
foreach ($script in @(
    'ci_impact_test.py', 'ci_reuse_test.py', 'ci_gate_test.py',
    'tool/external/check_bootstrap_source.ps1', 'check_l1_windows_source.ps1 -SelfTest',
    'check_acceptance_readiness.ps1 -SelfTest', 'tool/ci/resolve_ci_impact.py --mode plan')) {
    Assert-True ($observer.Value.Contains($script)) "impact job executes $script"
}
Assert-True ($observer.Value.Contains('name: ci-impact-plan')) 'impact uploads the plan artifact'
foreach ($job in @('static', 'windows_native', 'train_c_finalization_parity', 'contracts')) {
    $block = [regex]::Match($workflow, "(?ms)^  ${job}:\r?\n(.*?)(?=^  [a-z_]+:|\z)")
    Assert-True ($block.Success -and $block.Value -match '(?m)^    needs: impact\r?$') "$job consumes the plan"
    Assert-True ($block.Value -match "(?m)^    if: needs\.impact\.outputs\.\w+ == 'execute'\r?$") "$job is plan-gated"
}
Assert-True ($workflow.Contains("cron: '0 20 * * 0'")) 'weekly full regression is scheduled'
Assert-True ($workflow.Contains("github.event_name == 'schedule' && 'schedule'")) 'schedule owns a concurrency namespace'
Assert-True ($workflow.Contains('actions: read')) 'plan and evidence reads use read-only Actions permission'
Assert-True (!$workflow.Contains('paths-ignore')) 'no workflow-level path filter bypasses required checks'
Write-Output 'PASS: plan-gated units, aggregate recomputation, weekly full regression and separate concurrency'

$block = [regex]::Match($workflow, '(?s)\$tests = @\((.*?)\n\s*\)')
$paths = @([regex]::Matches($block.Groups[1].Value, "'([^']+_test\.dart)'") | ForEach-Object { $_.Groups[1].Value })
Assert-True ($paths.Count -eq @($paths | Select-Object -Unique).Count) 'no duplicate standing tests'
foreach ($path in $paths) {
    Assert-True (Test-Path -LiteralPath (Join-Path $root $path) -PathType Leaf) "missing standing test: $path"
}
$v3 = @(Get-ChildItem -LiteralPath (Join-Path $root 'test') -Recurse -Filter '*_test.dart' | ForEach-Object {
    [IO.Path]::GetRelativePath($root, $_.FullName).Replace('\', '/')
} | Where-Object { $_ -match '/training/|/study_activity/|/training_[^/]+_test\.dart$|/study_activity_[^/]+_test\.dart$|/home_training_result_test\.dart$' })
foreach ($path in $v3) { Assert-True ($paths -contains $path) "V3 coverage missing: $path" }
$arR2 = @(Get-ChildItem -LiteralPath (Join-Path $root 'test/application/capabilities') -Filter '*_test.dart' | ForEach-Object {
    [IO.Path]::GetRelativePath($root, $_.FullName).Replace('\', '/')
})
foreach ($path in $arR2) { Assert-True ($paths -contains $path) "AR-R2 coverage missing: $path" }
foreach ($path in @('test/application/agent/agent_turn_transcript_test.dart', 'test/application/agent/agent_r3_architecture_boundary_test.dart', 'test/application/agent/agent_runtime_test.dart')) {
    Assert-True ($paths -contains $path) "AR-R3 coverage missing: $path"
}
$externalApp = @(Get-ChildItem -LiteralPath (Join-Path $root 'test/application/external') -Filter '*_test.dart' | ForEach-Object {
    [IO.Path]::GetRelativePath($root, $_.FullName).Replace('\', '/')
})
foreach ($path in $externalApp) { Assert-True ($paths -contains $path) "External application coverage missing: $path" }
$externalIpc = @(Get-ChildItem -LiteralPath (Join-Path $root 'test/data/external') -Filter '*_test.dart' | ForEach-Object {
    [IO.Path]::GetRelativePath($root, $_.FullName).Replace('\', '/')
})
foreach ($path in $externalIpc) { Assert-True ($paths -contains $path) "External IPC coverage missing: $path" }
$externalOrigin = @(Get-ChildItem -LiteralPath (Join-Path $root 'test/application/generated_question') -Filter 'generated_external_origin*_test.dart' | ForEach-Object {
    [IO.Path]::GetRelativePath($root, $_.FullName).Replace('\', '/')
})
foreach ($path in $externalOrigin) { Assert-True ($paths -contains $path) "External origin coverage missing: $path" }
foreach ($path in @(
    'test/ui/external_authorization_screen_test.dart',
    'test/ui/generated_question/generated_external_origin_review_test.dart',
    'test/services/retrieval/rag_lazy_artifact_provisioning_integration_test.dart',
    'test/application/agent/agent_config_service_test.dart',
    'test/application/agent/agent_history_test.dart',
    'test/data/repositories/agent_config_repository_test.dart'
)) {
    Assert-True ($paths -contains $path) "External regression coverage missing: $path"
}
Assert-True (!$workflow.Contains("'test/support/study_activity_time_fakes.dart'")) 'support is not executable'
Assert-True (!($workflow -match "'test/[^']*_(?:support|probe)\.dart'")) 'support/probe files are not executable entries'
$partitions = @(0..3 | ForEach-Object { $shard=$_; for ($i=$shard; $i -lt $paths.Count; $i+=4) { $paths[$i] } })
Assert-True ($partitions.Count -eq $paths.Count -and @($partitions | Select-Object -Unique).Count -eq $paths.Count) 'modulo assignment exactly once'
Assert-True ($workflow.Contains('github.head_ref || github.ref_name')) 'branch identity shared across events'
Assert-True ($workflow.Contains("github.event_name == 'pull_request' || github.event_name == 'push'")) 'manual and scheduled runs never cancel required PR work'
Assert-True ($workflow.Contains("github.event_name == 'push' && 'push'")) 'push owns a separate concurrency namespace'
$uploadStep = [regex]::Match($workflow, '(?s)- name: Upload test timings.*?(?=\r?\n      - |\r?\n\r?\n  verify:)')
Assert-True ($uploadStep.Success -and $uploadStep.Value.Contains('continue-on-error: true')) 'timing upload never gates the required result'
Assert-True ($workflow.Contains('if ($testExit -ne 0) { exit $testExit }')) 'original Flutter failure propagated'
Assert-True (!$workflow.Contains('path: .dart_tool/ci-contract-timings/raw')) 'raw reporter never uploaded'
Write-Output "PASS: timing/redaction/failure boundaries; $($paths.Count) standing tests including $($v3.Count) V3 suites, $($externalApp.Count) external application, $($externalIpc.Count) external IPC and $($externalOrigin.Count) external origin suites"
