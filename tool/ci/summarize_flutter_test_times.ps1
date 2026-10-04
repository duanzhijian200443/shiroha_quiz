[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$InputPath,
    [Parameter(Mandatory)][string]$OutputPath,
    [string]$ProjectRoot = (Split-Path -Parent (Split-Path -Parent $PSScriptRoot))
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$root = [IO.Path]::GetFullPath($ProjectRoot)
$suites = @{}
$starts = @{}
$finished = @{}
$done = $null

foreach ($line in Get-Content -LiteralPath $InputPath -Encoding UTF8) {
    if ([string]::IsNullOrWhiteSpace($line)) { continue }
    $event = ConvertFrom-Json -InputObject $line -AsHashtable
    if ($event.type -notin @('suite', 'testStart', 'testDone', 'done')) { continue }
    if ($event.time -isnot [long] -and $event.time -isnot [int]) {
        throw 'Invalid timing event'
    }
    if ($event.time -lt 0) { throw 'Negative timing event' }
    switch ($event.type) {
        'suite' {
            $path = [IO.Path]::GetRelativePath($root, [string]$event.suite.path).Replace('\', '/')
            if ($path -notmatch '^test/[a-zA-Z0-9_./-]+_test\.dart$' -or
                $path.Split('/') -contains '..') {
                throw 'Timing suite must be a repository executable test'
            }
            $key = [string]$event.suite.id
            if ($suites.ContainsKey($key)) { throw 'Duplicate suite event' }
            $suites[$key] = @{path=$path; first=$null; last=$null; sum=0L; completed=0}
        }
        'testStart' {
            $key = [string]$event.test.id
            $suite = [string]$event.test.suiteID
            if ($starts.ContainsKey($key) -or !$suites.ContainsKey($suite)) {
                throw 'Invalid test start event'
            }
            $starts[$key] = @{suite=$suite; time=[long]$event.time}
            $row = $suites[$suite]
            if ($null -eq $row.first -or $event.time -lt $row.first) {
                $row.first = [long]$event.time
            }
        }
        'testDone' {
            $key = [string]$event.testID
            if (!$starts.ContainsKey($key) -or $finished.ContainsKey($key)) {
                throw 'Invalid test completion event'
            }
            $start = $starts[$key]
            $elapsed = [long]$event.time - $start.time
            if ($elapsed -lt 0) { throw 'Timing moved backwards' }
            $row = $suites[$start.suite]
            $row.last = [long]$event.time
            $row.sum += $elapsed
            $row.completed++
            $finished[$key] = $true
        }
        'done' { $done = $event }
    }
}
if ($null -eq $done -or $starts.Count -ne $finished.Count) {
    throw 'Incomplete timing report'
}
$rows = @(foreach ($row in $suites.Values) {
    if ($null -eq $row.first -or $null -eq $row.last) { throw 'Empty timing suite' }
    [ordered]@{
        path=$row.path
        suiteMilliseconds=$row.last - $row.first
        testMilliseconds=$row.sum
        completedEvents=$row.completed
    }
})
$result = [ordered]@{
    version=1
    successful=[bool]$done.success
    elapsedMilliseconds=[long]$done.time
    suites=@($rows | Sort-Object { $_.path })
}
$json = ConvertTo-Json -InputObject $result -Depth 4
[IO.File]::WriteAllText([IO.Path]::GetFullPath($OutputPath), $json, [Text.UTF8Encoding]::new($false))
Write-Output "Timing report: $($rows.Count) suites, $($result.elapsedMilliseconds)ms"
$rows | Sort-Object { $_.suiteMilliseconds } -Descending | Select-Object -First 10 |
    ForEach-Object { Write-Output "$($_.suiteMilliseconds)ms $($_.path)" }
