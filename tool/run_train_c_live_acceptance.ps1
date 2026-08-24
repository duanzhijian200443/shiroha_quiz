[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$InputJson
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$extension = [IO.Path]::GetExtension($InputJson)
if ($extension -ne '.json' -or
    -not (Test-Path -LiteralPath $InputJson -PathType Leaf -ErrorAction SilentlyContinue)) {
    [Console]::Error.WriteLine('TRAIN_C_HARNESS_NOT_READY')
    exit 2
}

$repoRoot = Split-Path -Parent $PSScriptRoot
$exitCode = 2
Push-Location $repoRoot
try {
    & dart run tool/train_c_evidence_probe.dart --input $InputJson
    $exitCode = $LASTEXITCODE
}
finally {
    Pop-Location
}

exit $exitCode
