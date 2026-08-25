[CmdletBinding()]
param(
    [switch]$Preflight,
    [switch]$Live,
    [string]$InputJson
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if (($Preflight -and $Live) -or
    (($Preflight -or $Live) -and -not [string]::IsNullOrWhiteSpace($InputJson)) -or
    (-not $Preflight -and -not $Live -and [string]::IsNullOrWhiteSpace($InputJson))) {
    [Console]::Error.WriteLine('TRAIN_C_HARNESS_NOT_READY')
    exit 2
}

$repoRoot = Split-Path -Parent $PSScriptRoot
$exitCode = 2
Push-Location $repoRoot
try {
    if ($Preflight) {
        & dart run tool/train_c_l1_preflight.dart --preflight
    } elseif ($Live) {
        & dart run tool/train_c_live_entrypoint.dart --live
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
