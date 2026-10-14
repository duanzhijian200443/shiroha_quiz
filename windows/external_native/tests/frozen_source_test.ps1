Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot '../diagnostics/frozen_source.ps1')
$paths = @('windows/external_native/a.cpp', 'windows/external_native/diagnostics/run_candidate.ps1')
$digest = 'a' * 64
$entries = @($paths | ForEach-Object { [pscustomobject]@{ Path = $_; Sha256 = $digest } })
Assert-CandidateSourceFreeze $entries $paths { param($path); $digest }
$rejected = 0
foreach ($case in @('hash', 'added', 'missing', 'duplicate', 'traversal', 'outside', 'empty')) {
    $inputEntries = $entries; $observed = $paths; $hash = $digest
    switch ($case) {
        hash { $hash = 'b' * 64 }
        added { $observed = @($paths) + 'windows/external_native/unknown.cpp' }
        missing { $observed = @($paths[0]) }
        duplicate { $inputEntries = @($entries) + $entries[0] }
        traversal { $inputEntries = @([pscustomobject]@{ Path = 'windows/external_native/../escape'; Sha256 = $digest }) }
        outside { $inputEntries = @([pscustomobject]@{ Path = 'elsewhere/a'; Sha256 = $digest }) }
        empty { $inputEntries = @() }
    }
    try { Assert-CandidateSourceFreeze $inputEntries $observed { param($path); $hash } }
    catch { $rejected++; continue }
    throw 'Frozen-source failure accepted'
}
if ($rejected -ne 7) { throw 'Missing freeze regression' }
Write-Output 'PASS: source freeze, drift/unknown/missing/duplicate/traversal rejected; no processes or lab objects'
