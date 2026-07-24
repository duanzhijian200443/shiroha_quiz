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

    [switch]$UseSavedAppKey
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$repoRoot = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Definition)

# ── Validate case file ──────────────────────────────────────────────────
$caseFile = Join-Path $repoRoot "tool\import_cases\$Case.json"
if (-not (Test-Path $caseFile)) {
    Write-Error "Case file not found: $caseFile"
    exit 1
}

# ── Refresh OCR via existing smoke infrastructure ───────────────────────
if ($RefreshOcr) {
    Write-Output "--- Refreshing OCR cache via ocr_smoke ---"

    $caseJson = Get-Content $caseFile -Raw | ConvertFrom-Json
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
    try {
        & powershell.exe @smokeArgs
        $smokeExit = $LASTEXITCODE
    } catch {
        Write-Warning "OCR smoke failed: $_"
        $smokeExit = 1
    }

    if ($smokeExit -ne 0) {
        Write-Error "OCR refresh failed (exit $smokeExit). Cannot generate replay cache."
        exit 1
    }
    Write-Output "--- OCR cache refreshed ---"
}

# ── Locate Dart executable ──────────────────────────────────────────────
$dartExe = $null
$flutterRoot = $env:FLUTTER_ROOT
if ($flutterRoot -and (Test-Path (Join-Path $flutterRoot 'bin\cache\dart-sdk\bin\dart.exe'))) {
    $dartExe = Join-Path $flutterRoot 'bin\cache\dart-sdk\bin\dart.exe'
} else {
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
    Write-Error "Cannot find dart executable. Ensure Flutter/Dart is on PATH."
    exit 1
}

# ── Run acceptance tool ─────────────────────────────────────────────────
$toolScript = Join-Path $repoRoot 'tool\import_acceptance.dart'
$dartArgs = @('run', $toolScript, "--case=$Case")

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
                Write-Output ""
                Write-Output "=== ACCEPTANCE RESULT ==="
                Write-Output "Verdict:   $verdict"
                Write-Output "Questions: $qCount / $expected"
                Write-Output "Duration:  ${dur}ms"
                if ($evt.hardFailureCount -and $evt.hardFailureCount -gt 0) {
                    Write-Output "Hard:      $($evt.hardFailureCount) failures"
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
    Write-Error "Acceptance runner failed: $_"
    $exitCode = 1
}

if ($exitCode -eq 0) {
    Write-Output "Result: PASS"
} elseif ($exitCode -eq 2) {
    Write-Output "Result: REVIEW (issues found, see reports)"
} else {
    Write-Output "Result: FAIL"
}

exit $exitCode
