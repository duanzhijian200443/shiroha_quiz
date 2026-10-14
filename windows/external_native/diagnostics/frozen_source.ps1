# Pure comparison seam; callers supply paths/hashes, never execute this to inspect lab objects.
function Assert-CandidateSourceFreeze {
    param([Parameter(Mandatory)][object[]]$Entries,
          [Parameter(Mandatory)][string[]]$ObservedPaths,
          [Parameter(Mandatory)][scriptblock]$HashOf)
    $prefix = 'windows/external_native/'
    $expected = [System.Collections.Generic.List[string]]::new()
    foreach ($entry in $Entries) {
        $path = $entry.Path
        if ($path -isnot [string] -or -not $path.StartsWith($prefix, [StringComparison]::Ordinal) -or
            $path.Contains('\') -or $path -match '(^|/)\.\.?(/|$)|[:*?]' -or
            $expected.Contains($path) -or $entry.Sha256 -notmatch '^[0-9a-fA-F]{64}$') {
            throw 'Invalid source freeze entry'
        }
        $expected.Add($path)
        if ((& $HashOf $path) -cne $entry.Sha256.ToLowerInvariant()) { throw 'Frozen source hash mismatch' }
    }
    if ($expected.Count -eq 0 -or $ObservedPaths.Count -ne $expected.Count -or
        @(Compare-Object -CaseSensitive $expected.ToArray() $ObservedPaths).Count -ne 0) {
        throw 'Frozen source path set mismatch'
    }
}
