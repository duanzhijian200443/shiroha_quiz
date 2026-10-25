# Test-only holder of one caller-created temporary file. No process discovery.
param([Parameter(Mandatory = $true)][string]$TargetFile)
$ErrorActionPreference = 'Stop'
$taskFile = [IO.File]::Open($TargetFile, [IO.FileMode]::Open,
    [IO.FileAccess]::Read, [IO.FileShare]::Read)
try {
    [Console]::Out.WriteLine('held')
    [Console]::Out.Flush()
    if ([Console]::In.ReadLine() -ne 'release') { throw 'Release not received' }
} finally {
    $taskFile.Dispose()
}
