Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot '../diagnostics/host_a_policy.ps1')
. (Join-Path $PSScriptRoot '../diagnostics/bounded_wait.ps1')
function Check($condition) { if (-not $condition) { throw 'fake assertion' } }
function Reject([scriptblock]$action) {
    $denied = $false
    try { & $action } catch { $denied = $true }
    Check $denied
}
# Synthetic expectations ONLY; these names, sizes and identities describe no host.
$scope = [pscustomobject]@{ Schema = 'batch3-host-a-metadata-v1'; History = @(
    [pscustomobject]@{ Name = '~tmp-0123456789abcdef-01234567'; ExpectedLength = 128 },
    [pscustomobject]@{ Name = '~tmp-0123456789abcdef-89abcdef'; ExpectedLength = 160 }) }
$layout = Get-Batch3Layout $scope
$script:fakeId = 0L
$facts = @(@('.') + @($layout.Keys) | ForEach-Object {
    $name = $_; $kind = if ($name -ceq '.') { 'directory' } else { $layout[$name] }
    $length = 0
    foreach ($h in $scope.History) { if ($name.EndsWith($h.Name)) { $length = $h.ExpectedLength } }
    ++$script:fakeId
    $streams = @()
    if ($kind -cne 'directory') { $streams = @([pscustomobject]@{ Name = '::$DATA'; Length = $length; Allocation = 4096L }) }
    [pscustomobject]@{ Name = $name; FileId = $script:fakeId.ToString('x16'); Volume = '0000002a'; FileSystem = 'NTFS'
        DriveType = 3; Attributes = $(if ($kind -ceq 'directory') { 16 } else { 0 }); ReparseTag = 0
        Links = 1; OwnerSid = 'synthetic'; Dacl = 'synthetic'; OwnerMatches = $true; RecipeMatches = $true
        Length = $length; Created = 1L; LastWrite = 2L; Changed = 3L
        Streams = $streams }
})
Assert-Batch3Metadata $scope $facts
Assert-Batch3SameSnapshot $scope $facts $facts
foreach ($field in @('FileId','Volume','FileSystem','DriveType','Attributes','ReparseTag','Links','OwnerSid','Dacl','Length','Created','LastWrite','Changed','OwnerMatches','RecipeMatches')) {
    $copy = @($facts | ForEach-Object { $_.PSObject.Copy() })
    switch ($field) {
        FileId { $copy[-1].$field = '0000000000000002' }
        Volume { $copy[-1].$field = '0000002b' }
        Attributes { $copy[-1].$field = 0x400 }
        FileSystem { $copy[-1].$field = 'FAT' }
        OwnerSid { $copy[-1].$field = 'other' }
        Dacl { $copy[-1].$field = 'other' }
        OwnerMatches { $copy[-1].$field = $false }
        RecipeMatches { $copy[-1].$field = $false }
        default { $copy[-1].$field = 99 }
    }
    Reject { Assert-Batch3SameSnapshot $scope $facts $copy }
}
Reject { Assert-Batch3Metadata $scope @($facts[0..11]) }
Reject { Assert-Batch3Metadata $scope @($facts + $facts[-1]) }
$unknown = @($facts | ForEach-Object { $_.PSObject.Copy() }); $unknown[-1].Name = 'Shiroha/external/app/state/associations.bin'
Reject { Assert-Batch3Metadata $scope $unknown }
foreach ($name in @('../escape', '~tmp-*', 'ASSOCIATIONS.BIN', '~tmp-0123456789ABCDEF-01234567', "~tmp-0123456789abcdef-01234567`n")) {
    $bad = [pscustomobject]@{ Schema = $scope.Schema; History = @($scope.History[0].PSObject.Copy(), $scope.History[1].PSObject.Copy()) }
    $bad.History[0].Name = $name
    Reject { Get-Batch3Layout $bad }
}
Reject { Get-Batch3Layout ([pscustomobject]@{ Schema = $scope.Schema; History = @() }) }
$bad = [pscustomobject]@{ Schema = $scope.Schema; History = @($scope.History[0], $scope.History[0]) }
Reject { Get-Batch3Layout $bad }
# A second observation changes after an accepted snapshot: first PASS is not a lease.
Reject { Assert-Batch3SameSnapshot $scope $facts $unknown }
foreach ($mutation in @('missing','unknown','size','allocation')) {
    $copy = @($facts | ForEach-Object { $_.PSObject.Copy() })
    $copy[-1].Streams = @([pscustomobject]@{ Name = '::$DATA'; Length = $copy[-1].Length; Allocation = 4096L })
    switch ($mutation) {
        missing { $copy[-1].Streams = $null }
        unknown { $copy[-1].Streams[0].Name = ':unknown:$DATA' }
        size { $copy[-1].Streams[0].Length++ }
        allocation { $copy[-1].Streams[0].Allocation++ }
    }
    Reject { Assert-Batch3SameSnapshot $scope $facts $copy }
}

$script:tick = 0L; $script:waits = 0
$ok = Wait-Batch3Process -Clock { [long]$script:tick } -WaitForExit { param($ms); ++$script:waits; $script:tick += $ms; $true } -GetExitCode { [int]0 }
Check ($ok.Code -eq 0 -and -not $ok.SettlementUnknown -and $script:waits -eq 1)
$script:tick = 0L; $script:waits = 0; $script:exitReads = 0
$timeout = Wait-Batch3Process -DeadlineMilliseconds 150 -Clock { [long]$script:tick } -WaitForExit { param($ms); ++$script:waits; $script:tick += $ms; $false } -GetExitCode { ++$script:exitReads; [int]0 }
Check ($timeout.Code -eq 10 -and $timeout.Reason -ceq 'deadline' -and $timeout.SettlementUnknown -and $script:exitReads -eq 0 -and $script:waits -eq 2)
$script:tick = 0L
$lateExit = Wait-Batch3Process -DeadlineMilliseconds 100 -Clock { [long]$script:tick } -WaitForExit { param($ms); $script:tick = 100L; $true } -GetExitCode { throw 'late success must not be read' }
Check ($lateExit.Code -eq 10 -and $lateExit.SettlementUnknown)
# Exit-code retrieval is part of the bounded observation, including its clock.
foreach ($ending in @(99L, 100L, 200L, -1L)) {
    $script:tick = 0L; $script:exitReads = 0
    $result = Wait-Batch3Process -DeadlineMilliseconds 100 -Clock { [long]$script:tick } -WaitForExit {
        param($ms); $script:tick = 1L; $true
    } -GetExitCode { ++$script:exitReads; $script:tick = $ending; [int]0 }
    Check ($script:exitReads -eq 1 -and $result.Polls -eq 1)
    if ($ending -eq 99L) { Check ($result.Code -eq 0 -and -not $result.SettlementUnknown) }
    else { Check ($result.Code -eq 10 -and $result.SettlementUnknown) }
    if ($ending -ge 100L) { Check ($result.Reason -ceq 'deadline') }
}
$script:tick = 0L; $script:exitReads = 0
$badFinalClock = Wait-Batch3Process -Clock {
    if ($script:exitReads) { throw 'synthetic final clock failure' }; [long]$script:tick
} -WaitForExit { param($ms); $true } -GetExitCode { ++$script:exitReads; [int]0 }
Check ($badFinalClock.Code -eq 10 -and $badFinalClock.SettlementUnknown)
$nonzero = Wait-Batch3Process -Clock { [long]0 } -WaitForExit { param($ms); $true } -GetExitCode { [int]7 }
Check ($nonzero.Code -eq 7 -and -not $nonzero.SettlementUnknown)
$script:tick = 3L
$backwards = Wait-Batch3Process -Clock { [long]($script:tick--) } -WaitForExit { throw 'clock must fail before wait' } -GetExitCode { [int]0 }
Check ($backwards.Code -eq 10 -and $backwards.Polls -eq 0)
$frozen = Wait-Batch3Process -Clock { [long]0 } -WaitForExit { param($ms); $false } -GetExitCode { throw 'must not read' }
Check ($frozen.Reason -ceq 'poll_budget' -and $frozen.Polls -eq 301)
foreach ($wait in @({ param($ms); throw 'synthetic' }, { param($ms); 'true' }, { param($ms); @($true,$false) })) {
    $result = Wait-Batch3Process -Clock { [long]0 } -WaitForExit $wait -GetExitCode { [int]0 }
    Check ($result.Code -eq 10 -and $result.SettlementUnknown -and $result.Polls -eq 1)
}
# Source guards: no probe admission, broad permissions, content read or cleanup.
$reader = Get-Content (Join-Path $PSScriptRoot '../diagnostics/host_a_metadata.cs') -Raw
Check ($reader -notmatch '\b(ReadFile|WriteFile|CreateDirectory|SetSecurityInfo|DeleteFile|MoveFile|CryptProtectData|CryptUnprotectData)\s*\(')
Check ($reader -match 'history \? 1u : 3u, 1, 0x200020u')
$runner = Get-Content (Join-Path $PSScriptRoot '../diagnostics/run_candidate.ps1') -Raw
Check ($runner -match "host_a_runtime_binding_pending" -and $runner -notmatch 'GetFolderPath|Get-ChildItem')
$dry = & (Join-Path $PSScriptRoot '../diagnostics/host_a_preflight.ps1')
Check ($dry -match '^DRY RUN:')
Write-Output 'PASS: synthetic Host A scope/identity drift, unknown objects, bounded timeout/unknown settlement, no live operations'
