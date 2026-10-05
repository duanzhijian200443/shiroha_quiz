[CmdletBinding()]
param([string]$BodyPath, [switch]$Compute)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Get-TaskPackageIdentity {
    param([Parameter(Mandatory)][string]$Body)

    $text = $Body.Replace("`r`n", "`n").Replace("`r", "`n")
    if ($text.StartsWith([string][char]0xfeff, [StringComparison]::Ordinal)) {
        $text = $text.Substring(1)
    }
    $lines = $text.Split([char]"`n")
    $outside = [Collections.Generic.List[int]]::new()
    $headings = [Collections.Generic.List[int]]::new()
    $packages = [Collections.Generic.List[int]]::new()
    $fenceCharacter = ''
    $fenceLength = 0
    for ($i = 0; $i -lt $lines.Count; $i++) {
        $line = $lines[$i]
        if ($fenceLength -gt 0) {
            $closing = '^ {0,3}' + [regex]::Escape($fenceCharacter) +
                '{' + $fenceLength + ',}[ \t]*$'
            if ([regex]::IsMatch($line, $closing)) { $fenceLength = 0 }
            continue
        }
        $fence = [regex]::Match($line, '^ {0,3}(`{3,}|~{3,})(.*)$')
        if ($fence.Success -and !($fence.Groups[1].Value[0] -eq [char]0x60 -and
                $fence.Groups[2].Value.Contains([string][char]0x60))) {
            $fenceCharacter = [string]$fence.Groups[1].Value[0]
            $fenceLength = $fence.Groups[1].Value.Length
            continue
        }
        $outside.Add($i)
        if ([regex]::IsMatch($line, '^ {0,3}#{1,2}(?:[ \t]|$)')) { $headings.Add($i) }
        if ([regex]::IsMatch($line, '^ {0,3}##[ \t]+Task package(?:[ \t]+#+)?[ \t]*$')) {
            if ($line -cne '## Task package') { throw 'Task package heading must be exact.' }
            $packages.Add($i)
        }
    }
    if ($packages.Count -ne 1) { throw 'Exactly one Task package section is required.' }
    $start = $packages[0]
    $end = $lines.Count
    foreach ($heading in $headings) {
        if ($heading -gt $start) { $end = $heading; break }
    }
    if ($end -eq $lines.Count -and $fenceLength -gt 0) { throw 'Unclosed task package fence.' }

    $revisionLines = @($outside | Where-Object {
        $_ -gt $start -and $_ -lt $end -and $lines[$_].StartsWith('Task-package revision:')
    })
    $digestLines = @($outside | Where-Object {
        $_ -gt $start -and $_ -lt $end -and $lines[$_].StartsWith('Task-package digest:')
    })
    if ($revisionLines.Count -ne 1 -or $digestLines.Count -ne 1) {
        throw 'Exactly one revision and digest field are required.'
    }
    $revisionMatch = [regex]::Match($lines[$revisionLines[0]], '^Task-package revision: ([1-9][0-9]*)$')
    $revision = 0L
    if (!$revisionMatch.Success -or
        ![long]::TryParse($revisionMatch.Groups[1].Value, [ref]$revision)) {
        throw 'Invalid task package revision.'
    }
    $digestMatch = [regex]::Match($lines[$digestLines[0]], '^Task-package digest: ([0-9a-f]{64})$')
    if (!$digestMatch.Success) { throw 'Invalid task package digest.' }

    $content = [Collections.Generic.List[string]]::new()
    for ($i = $start; $i -lt $end; $i++) {
        if ($i -ne $digestLines[0]) { $content.Add($lines[$i]) }
    }
    while ($content.Count -gt 0 -and $content[$content.Count - 1] -ceq '') {
        $content.RemoveAt($content.Count - 1)
    }
    $bytes = [Text.UTF8Encoding]::new($false, $true).GetBytes(
        [string]::Join("`n", $content) + "`n")
    $sha = [Security.Cryptography.SHA256]::Create()
    try { $digest = [BitConverter]::ToString($sha.ComputeHash($bytes)).Replace('-', '').ToLowerInvariant() }
    finally { $sha.Dispose() }
    [pscustomobject]@{
        TaskPackageRevision = $revision
        TaskPackageDigest = $digest
        DeclaredDigest = $digestMatch.Groups[1].Value
        DigestMatches = $digest -ceq $digestMatch.Groups[1].Value
    }
}

# Dot-sourcing exposes the pure parser to offline tests; CLI mode verifies by default.
if ($MyInvocation.InvocationName -ne '.') {
    if ([string]::IsNullOrWhiteSpace($BodyPath)) { throw 'BodyPath is required.' }
    try { $body = [Text.UTF8Encoding]::new($false, $true).GetString([IO.File]::ReadAllBytes($BodyPath)) }
    catch { throw 'Cannot read a UTF-8 PR body.' }
    $identity = Get-TaskPackageIdentity -Body $body
    if (!$Compute -and !$identity.DigestMatches) { throw 'Task package digest mismatch.' }
    $identity | ConvertTo-Json -Compress
}
