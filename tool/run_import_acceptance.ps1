<#
.SYNOPSIS
  Offline import acceptance runner with OCR replay cache.

.DESCRIPTION
  Replays a cached OcrDocument through the production Regionizer / Assembler /
  QualityGate pipeline and emits a PASS / REVIEW / FAIL verdict.

  OCR refresh delegates to the existing run_ocr_smoke.ps1 infrastructure.

.PARAMETER Case
  Test case ID, e.g. "2022_math1". Must have a matching
  tool/import_cases/<Case>.json.

.PARAMETER RefreshOcr
  Run a single live OCR call and save the result to the replay cache before
  running the acceptance pipeline.

.PARAMETER UseSavedAppKey
  When -RefreshOcr is set, load the OCR API key from the app database instead
  of prompting.

.EXAMPLE
  .\tool\run_import_acceptance.ps1 -Case "2022_math1"
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [string]$Case,

    [switch]$RefreshOcr,

    [switch]$UseSavedAppKey,

    [Parameter(DontShow)]
    [string]$DartExecutableForTesting
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Write-SafeAcceptanceEvent {
    param(
        [Parameter(Mandatory)]
        [string]$Stage,

        [Parameter(Mandatory)]
        [string]$Status,

        [Parameter(Mandatory)]
        [string]$CauseType
    )

    [ordered]@{
        stage = $Stage
        status = $Status
        causeType = $CauseType
    } | ConvertTo-Json -Compress
}

$repoRoot = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Definition)

# ── Validate case file ──────────────────────────────────────────────────
if ([string]::IsNullOrWhiteSpace($Case) -or $Case -notmatch '^[A-Za-z0-9_-]+$') {
    Write-SafeAcceptanceEvent -Stage 'launcher' -Status 'invalid_case_id' -CauseType 'InvalidAcceptanceCaseId'
    exit 2
}

$caseFile = Join-Path $repoRoot "tool\import_cases\$Case.json"
if (-not (Test-Path $caseFile)) {
    Write-SafeAcceptanceEvent -Stage 'launcher' -Status 'case_not_found' -CauseType 'CaseNotFound'
    exit 1
}

# ── Refresh OCR via existing smoke infrastructure ───────────────────────
if ($RefreshOcr) {
    try {
        $caseJson = Get-Content $caseFile -Raw | ConvertFrom-Json
    } catch {
        Write-SafeAcceptanceEvent -Stage 'launcher' -Status 'case_config_invalid' -CauseType ($_.Exception.GetType().Name)
        exit 1
    }
    if ($caseJson.schemaVersion -eq 2) {
        Write-SafeAcceptanceEvent -Stage 'launcher' -Status 'paired_refresh_not_supported' -CauseType 'PairedReplayOnly'
        exit 2
    }

    Write-Output "--- Refreshing OCR cache via ocr_smoke ---"
    $pdfRelative = $caseJson.pdf

    $smokeArgs = @(
        '-NoProfile', '-ExecutionPolicy', 'Bypass',
        '-File', (Join-Path $repoRoot 'tool\run_ocr_smoke.ps1'),
        '-Pdf', $pdfRelative,
        '-WriteReplayCache',
        '-CaseId', $Case
    )
    if ($UseSavedAppKey) { $smokeArgs += '-UseSavedAppKey' }

    $smokeExit = 0
    $replayCacheWritten = $false
    try {
        & powershell.exe @smokeArgs 2>&1 | ForEach-Object {
            $line = $_.ToString()
            try {
                $evt = $line | ConvertFrom-Json -ErrorAction Stop
                if ($evt.stage -eq 'replay_cache' -and $evt.status -eq 'written') {
                    $replayCacheWritten = $true
                }
                if ($evt.stage -in @('launcher', 'preflight', 'provider', 'replay_cache', 'credential_probe', 'completed')) {
                    Write-Output $line
                }
            } catch {
                # Suppress non-JSON line to avoid leaking secrets
            }
        }
        $smokeExit = $LASTEXITCODE
    } catch {
        Write-SafeAcceptanceEvent -Stage 'launcher' -Status 'refresh_runner_failed' -CauseType ($_.Exception.GetType().Name)
        exit 1
    }

    if ($smokeExit -ne 0 -or -not $replayCacheWritten) {
        Write-SafeAcceptanceEvent -Stage 'replay_cache' -Status 'refresh_failed' -CauseType 'OcrRefreshFailed'
        exit 1
    }
    Write-Output "--- OCR cache refreshed ---"
}

# ── Locate Dart executable ──────────────────────────────────────────────
$dartExe = $DartExecutableForTesting
$flutterRoot = $env:FLUTTER_ROOT
if (-not $dartExe -and $flutterRoot -and (Test-Path (Join-Path $flutterRoot 'bin\cache\dart-sdk\bin\dart.exe'))) {
    $dartExe = Join-Path $flutterRoot 'bin\cache\dart-sdk\bin\dart.exe'
} elseif (-not $dartExe) {
    $dartExe = Get-Command 'dart' -ErrorAction SilentlyContinue | Select-Object -ExpandProperty Source
}
if (-not $dartExe) {
    $flutterCmd = Get-Command 'flutter' -ErrorAction SilentlyContinue
    if ($flutterCmd) {
        $flutterBin = Split-Path $flutterCmd.Source
        $candidate = Join-Path $flutterBin 'cache\dart-sdk\bin\dart.exe'
        if (Test-Path $candidate) { $dartExe = $candidate }
    }
}
if (-not $dartExe) {
    Write-SafeAcceptanceEvent -Stage 'launcher' -Status 'runner_unavailable' -CauseType 'DartExecutableUnavailable'
    exit 1
}

# ── Run acceptance tool ─────────────────────────────────────────────────
$toolScript = Join-Path $repoRoot 'tool\import_acceptance.dart'
$dartArgs = @('run', $toolScript, "--case=$Case", "--repository-root=$repoRoot")

Write-Output "--- Running import acceptance (case=$Case) ---"

$exitCode = 0
try {
    & $dartExe @dartArgs 2>&1 | ForEach-Object {
        $line = $_.ToString()
        # Parse JSON lines for terminal display
        try {
            $evt = $line | ConvertFrom-Json -ErrorAction Stop
            $stage  = if ($evt.stage)  { $evt.stage }  else { '?' }
            $status = if ($evt.status) { $evt.status } else { '?' }

            if ($stage -eq 'completed') {
                $verdict = if ($evt.verdict) { $evt.verdict } else { $status.ToUpper() }
                $qCount  = if ($evt.actualQuestionCount) { $evt.actualQuestionCount } else { '?' }
                $expected = if ($evt.expectedQuestionCount) { $evt.expectedQuestionCount } else { '?' }
                $dur = if ($evt.durationMs) { $evt.durationMs } else { '?' }
                $hardCount = $null
                if ($null -ne $evt.PSObject.Properties['hardIssueCount']) {
                    $hardCount = $evt.hardIssueCount
                } elseif ($null -ne $evt.PSObject.Properties['hardFailureCount']) {
                    $hardCount = $evt.hardFailureCount
                }
                Write-Output ""
                Write-Output "=== ACCEPTANCE RESULT ==="
                Write-Output "Verdict:   $verdict"
                Write-Output "Questions: $qCount / $expected"
                Write-Output "Duration:  ${dur}ms"
                if ($null -ne $hardCount -and $hardCount -gt 0) {
                    Write-Output "Hard:      $hardCount failures"
                }
                if ($evt.reviewIssueCount -and $evt.reviewIssueCount -gt 0) {
                    Write-Output "Review:    $($evt.reviewIssueCount) issues"
                }
                Write-Output "Repair:    $($evt.repairMode) ($($evt.repairCandidateCount) candidates)"
                Write-Output "========================="
            } else {
                Write-Output "[$stage] $status"
            }
        } catch {
            # Non-JSON line — suppress to prevent leaking sensitive data
        }
    }
    $exitCode = $LASTEXITCODE
} catch {
    Write-SafeAcceptanceEvent -Stage 'launcher' -Status 'runner_start_failed' -CauseType ($_.Exception.GetType().Name)
    exit 1
}

if ($exitCode -eq 0) {
    Write-Output "Result: PASS"
} elseif ($exitCode -eq 2) {
    Write-Output "Result: REVIEW (issues found, see reports)"
} elseif ($exitCode -eq 3) {
    Write-Output "Result: NOT_VERIFIED"
} else {
    Write-Output "Result: FAIL"
}

exit $exitCode
