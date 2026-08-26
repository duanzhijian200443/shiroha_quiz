[CmdletBinding()]
param(
    [switch]$Preflight,
    [switch]$AuthorizeRun1,
    [switch]$Live,
    [switch]$Continue,
    [switch]$Status,
    [string]$AttemptStateDirectory,
    [string]$InputJson
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if (@($Preflight, $AuthorizeRun1, $Live, $Continue, $Status).Where({ $_ }).Count -gt 1 -or
    (($Preflight -or $AuthorizeRun1 -or $Live -or $Continue -or $Status) -and
        -not [string]::IsNullOrWhiteSpace($InputJson)) -or
    (-not $Preflight -and -not $AuthorizeRun1 -and -not $Live -and
        -not $Continue -and -not $Status -and [string]::IsNullOrWhiteSpace($InputJson))) {
    [Console]::Error.WriteLine('TRAIN_C_HARNESS_NOT_READY')
    exit 2
}

$repoRoot = Split-Path -Parent $PSScriptRoot
$exitCode = 2
Push-Location $repoRoot
try {
    if ($Preflight) {
        & dart run tool/train_c_l1_preflight.dart --preflight
    } elseif ($AuthorizeRun1) {
        if ([string]::IsNullOrWhiteSpace($AttemptStateDirectory)) {
            [Console]::Error.WriteLine('TRAIN_C_PROVIDER_ENVIRONMENT_BLOCKED')
            exit 2
        }
        $env:TRAIN_C_ATTEMPT_STATE_DIRECTORY = $AttemptStateDirectory
        & dart run tool/train_c_live_entrypoint.dart --authorize-run1
    } elseif ($Live) {
        if ([string]::IsNullOrWhiteSpace($AttemptStateDirectory)) {
            [Console]::Error.WriteLine('TRAIN_C_PROVIDER_ENVIRONMENT_BLOCKED')
            exit 2
        }
        $capabilityPath = Join-Path $AttemptStateDirectory 'capability.v1'
        if (-not (Test-Path -LiteralPath $capabilityPath -PathType Leaf -ErrorAction SilentlyContinue)) {
            [Console]::Error.WriteLine('TRAIN_C_PROVIDER_ENVIRONMENT_BLOCKED')
            exit 2
        }
        $env:TRAIN_C_LIVE_ATTEMPT_CAPABILITY = (Get-Content -LiteralPath $capabilityPath -Raw).Trim()
        & dart run tool/train_c_live_entrypoint.dart --live
    } elseif ($Continue) {
        if ([string]::IsNullOrWhiteSpace($AttemptStateDirectory)) {
            [Console]::Error.WriteLine('TRAIN_C_PROVIDER_ENVIRONMENT_BLOCKED')
            exit 2
        }
        $capabilityPath = Join-Path $AttemptStateDirectory 'capability.v1'
        if (-not (Test-Path -LiteralPath $capabilityPath -PathType Leaf -ErrorAction SilentlyContinue)) {
            [Console]::Error.WriteLine('TRAIN_C_PROVIDER_ENVIRONMENT_BLOCKED')
            exit 2
        }
        $env:TRAIN_C_LIVE_ATTEMPT_CAPABILITY = (Get-Content -LiteralPath $capabilityPath -Raw).Trim()
        $env:TRAIN_C_L1B_CONTINUATION = '1'
        & dart run tool/train_c_live_entrypoint.dart --continue
    } elseif ($Status) {
        if ([string]::IsNullOrWhiteSpace($AttemptStateDirectory)) {
            [Console]::Error.WriteLine('TRAIN_C_PROVIDER_ENVIRONMENT_BLOCKED')
            exit 2
        }
        $capabilityPath = Join-Path $AttemptStateDirectory 'capability.v1'
        if (-not (Test-Path -LiteralPath $capabilityPath -PathType Leaf -ErrorAction SilentlyContinue)) {
            [Console]::Error.WriteLine('TRAIN_C_PROVIDER_ENVIRONMENT_BLOCKED')
            exit 2
        }
        $env:TRAIN_C_LIVE_ATTEMPT_CAPABILITY = (Get-Content -LiteralPath $capabilityPath -Raw).Trim()
        & dart run tool/train_c_live_entrypoint.dart --status
    } else {
        $extension = [IO.Path]::GetExtension($InputJson)
        if ($extension -ne '.json' -or
            -not (Test-Path -LiteralPath $InputJson -PathType Leaf -ErrorAction SilentlyContinue)) {
            [Console]::Error.WriteLine('TRAIN_C_HARNESS_NOT_READY')
            exit 2
        }
        & dart run tool/train_c_evidence_probe.dart --input $InputJson
    }
    $exitCode = $LASTEXITCODE
}
finally {
    Pop-Location
}

exit $exitCode
