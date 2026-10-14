[CmdletBinding()]
param([string]$ScopeFile, [string]$ScopeHash, [string]$ReaderHash, [string]$PolicyHash,
      [string]$ReaderAssembly, [string]$ReaderAssemblyHash,
      [switch]$Inspect)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
if (-not $Inspect) { Write-Output 'DRY RUN: no metadata access; separate read-only grant required'; return }
$stage = 'scope_hash'
try {
    $reader = Join-Path $PSScriptRoot 'host_a_metadata.cs'
    $policy = Join-Path $PSScriptRoot 'host_a_policy.ps1'
    foreach ($entry in @(@($ScopeFile, $ScopeHash), @($reader, $ReaderHash), @($policy, $PolicyHash), @($ReaderAssembly, $ReaderAssemblyHash))) {
        if ($entry[1] -cnotmatch '^[0-9a-f]{64}$' -or
            (Get-FileHash -LiteralPath $entry[0] -Algorithm SHA256).Hash.ToLowerInvariant() -cne $entry[1]) { throw 'freeze' }
    }
    $stage = 'scope'
    . $policy
    $scope = Get-Content -LiteralPath $ScopeFile -Raw | ConvertFrom-Json
    $null = Get-Batch3Layout $scope # Empty template fails BEFORE loading reader.
    $stage = 'metadata'
    # Use only the frozen standalone assembly in a fresh approved worker; never
    # compile source implicitly at runtime or load the production helper.
    $assembly = [System.Reflection.Assembly]::LoadFile((Get-Item -LiteralPath $ReaderAssembly).FullName)
    $method = $assembly.GetType('ShirohaBatch3.MetadataReader', $true).GetMethod('Read')
    $arguments = [object[]]@([string[]]@($scope.History | ForEach-Object { $_.Name }),
        [long[]]@($scope.History | ForEach-Object { $_.ExpectedLength }))
    $report = $method.Invoke($null, $arguments)
    $stage = 'comparison'
    Assert-Batch3Metadata $scope @($report.Facts)
    [pscustomobject]@{ Result = 'CAPTURED_NOT_RUNTIME_APPROVAL'; Capture = $report } | ConvertTo-Json -Depth 8
} catch {
    Write-Output "STOP stage=$stage result=incomplete_or_denied runtime_authority=none"
    exit 10
}
