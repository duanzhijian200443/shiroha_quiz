# Pure metadata policy. Importing this file performs no filesystem/OS inspection.
function Get-Batch3Layout {
    param([Parameter(Mandatory)]$Scope)
    if ($Scope.Schema -cne 'batch3-host-a-metadata-v1' -or @($Scope.History).Count -ne 2) { throw 'scope_shape' }
    $layout = [ordered]@{
        'Shiroha' = 'directory'; 'Shiroha/external' = 'directory'
        'Shiroha/external/runtime.lock' = 'lock'; 'Shiroha/external/app' = 'directory'
        'Shiroha/external/app/trust' = 'directory'; 'Shiroha/external/app/state' = 'directory'
        'Shiroha/external/discovery' = 'directory'; 'Shiroha/external/exchange' = 'directory'
        'Shiroha/external/bridge' = 'directory'; 'Shiroha/external/bridge/client.lock' = 'lock'
    }
    foreach ($item in $Scope.History) {
        if ($item.Name -isnot [string] -or $item.Name -cnotmatch '^~tmp-[0-9a-f]{16}-[0-9a-f]{8}\z' -or
            ($item.ExpectedLength -isnot [int] -and $item.ExpectedLength -isnot [long]) -or
            $item.ExpectedLength -le 0 -or $item.ExpectedLength -gt 65536) { throw 'history_scope' }
        $path = 'Shiroha/external/app/state/' + $item.Name
        if ($layout.Contains($path)) { throw 'duplicate_history' }
        $layout.Add($path, 'history')
    }
    return $layout
}

function Assert-Batch3Metadata {
    param([Parameter(Mandatory)]$Scope, [Parameter(Mandatory)][object[]]$Facts)
    $layout = Get-Batch3Layout $Scope
    if ($Facts.Count -ne 13) { throw 'object_count' }
    $seen = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    $identities = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    $volume = $null
    foreach ($fact in $Facts) {
        if (-not $seen.Add($fact.Name) -or ($fact.Name -cne '.' -and -not $layout.Contains($fact.Name))) { throw 'unknown_object' }
        if ($fact.FileId -cnotmatch '^[0-9a-f]{16}\z' -or $fact.FileId -ceq ('0' * 16) -or
            $fact.Volume -cnotmatch '^[0-9a-f]{8}\z' -or $fact.FileSystem -cne 'NTFS' -or
            $fact.DriveType -ne 3 -or $fact.ReparseTag -ne 0 -or ($fact.Attributes -band 0x400) -ne 0) { throw 'identity_or_volume' }
        if ($null -eq $volume) { $volume = $fact.Volume }
        if ($fact.Volume -cne $volume) { throw 'volume_drift' }
        if (-not $identities.Add($fact.Volume + ':' + $fact.FileId)) { throw 'aliased_object' }
        if ($fact.OwnerSid -isnot [string] -or $fact.Dacl -isnot [string] -or
            $fact.OwnerMatches -isnot [bool] -or $fact.RecipeMatches -isnot [bool] -or
            [string]::IsNullOrEmpty($fact.OwnerSid) -or [string]::IsNullOrEmpty($fact.Dacl)) { throw 'security_missing' }
        $kind = if ($fact.Name -ceq '.') { 'directory' } else { $layout[$fact.Name] }
        if ([bool]($fact.Attributes -band 0x10) -ne ($kind -ceq 'directory')) { throw 'type_drift' }
        if ($null -eq $fact.Streams) { throw 'streams_missing' }
        $streams = @($fact.Streams)
        if ($kind -ceq 'directory') {
            if ($streams.Count -ne 0) { throw 'unknown_directory_stream' }
        } elseif ($streams.Count -ne 1 -or $streams[0].Name -cne '::$DATA' -or
            $streams[0].Length -ne $fact.Length -or $streams[0].Allocation -lt 0) { throw 'unknown_or_invalid_stream' }
        if ($fact.Name -cne '.' -and (-not $fact.OwnerMatches -or
            ($fact.Name -cne 'Shiroha' -and -not $fact.RecipeMatches))) { throw 'security_recipe' }
        if ($kind -cne 'directory' -and $fact.Links -ne 1) { throw 'hard_link' }
        if ($kind -ceq 'lock' -and $fact.Length -ne 0) { throw 'lock_length' }
        if ($kind -ceq 'history') {
            $expected = @($Scope.History | Where-Object { ('Shiroha/external/app/state/' + $_.Name) -ceq $fact.Name })
            if ($expected.Count -ne 1 -or $fact.Length -ne $expected[0].ExpectedLength) { throw 'history_length' }
        }
    }
    if (-not $seen.Contains('.')) { throw 'missing_parent' }
    foreach ($path in $layout.Keys) { if (-not $seen.Contains($path)) { throw 'missing_object' } }
}

function Assert-Batch3SameSnapshot {
    param([Parameter(Mandatory)]$Scope, [Parameter(Mandatory)][object[]]$Expected,
          [Parameter(Mandatory)][object[]]$Observed)
    Assert-Batch3Metadata $Scope $Expected
    Assert-Batch3Metadata $Scope $Observed
    # This is a comparison at ONE checkpoint, never a durable runtime grant.
    $fields = @('FileId', 'Volume', 'FileSystem', 'DriveType', 'OwnerSid', 'Dacl',
        'Attributes', 'ReparseTag', 'Links', 'Length', 'Created', 'LastWrite', 'Changed')
    foreach ($before in $Expected) {
        $after = @($Observed | Where-Object { $_.Name -ceq $before.Name })[0]
        foreach ($field in $fields) {
            if ([string]$before.$field -cne [string]$after.$field) { throw 'snapshot_drift' }
        }
        if (@($before.Streams).Count -ne @($after.Streams).Count) { throw 'stream_drift' }
        for ($i = 0; $i -lt @($before.Streams).Count; ++$i) {
            foreach ($field in @('Name','Length','Allocation')) {
                if ([string]$before.Streams[$i].$field -cne [string]$after.Streams[$i].$field) { throw 'stream_drift' }
            }
        }
    }
}
