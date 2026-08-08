[CmdletBinding()]
param(
    [string]$BaseRef,
    [string[]]$TestPath = @(),
    [switch]$SkipAnalyze,
    [switch]$SkipFormatCheck
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Write-Section {
    param(
        [Parameter(Mandatory)]
        [string]$Name
    )

    Write-Output ''
    Write-Output $Name
}

function Write-FailedPreflight {
    param(
        [Parameter(Mandatory)]
        [string]$Reason
    )

    Write-Section -Name 'Changed Dart files'
    Write-Output 'Changed Dart files: NOT RUN'
    Write-Section -Name 'Format check'
    Write-Output 'Format check: NOT RUN'
    Write-Section -Name 'Analyze'
    Write-Output 'Analyze: NOT RUN'
    Write-Section -Name 'Tests'
    Write-Output 'Tests: NOT RUN'
    Write-Section -Name 'Diff check'
    Write-Output 'Diff check: NOT RUN'
    Write-Section -Name 'Git status'
    Write-Output 'Git status: NOT RUN'
    Write-Section -Name 'Final verdict'
    Write-Output "FAIL ($Reason)"
}

function Stop-Verification {
    Write-Section -Name 'Final verdict'
    Write-Output 'FAIL'
    exit 1
}

$repoRootOutput = @(& git rev-parse --show-toplevel 2>$null)
if ($LASTEXITCODE -ne 0 -or $repoRootOutput.Count -eq 0) {
    Write-FailedPreflight -Reason 'repository_unavailable'
    exit 1
}

$repoRoot = $repoRootOutput[-1].Trim()
if ([string]::IsNullOrWhiteSpace($repoRoot) -or -not (Test-Path -LiteralPath $repoRoot -PathType Container)) {
    Write-FailedPreflight -Reason 'repository_root_invalid'
    exit 1
}

Set-Location -LiteralPath $repoRoot

$failed = $false
$changeCollectionFailed = $false
$unstagedArguments = @(
    'diff',
    '--name-only',
    '--diff-filter=ACMRT'
)

if (-not [string]::IsNullOrWhiteSpace($BaseRef)) {
    if ($BaseRef.StartsWith('-')) {
        Write-Output 'BaseRef: INVALID'
        $changeCollectionFailed = $true
        $failed = $true
    } else {
        $unstagedArguments += $BaseRef
    }
}
$unstagedArguments += '--'

$unstagedFiles = @()
if (-not $changeCollectionFailed) {
    $unstagedFiles = @(& git @unstagedArguments)
    if ($LASTEXITCODE -ne 0) {
        $changeCollectionFailed = $true
        $failed = $true
    }
}

$cachedFiles = @(& git diff --cached --name-only --diff-filter=ACMRT --)
if ($LASTEXITCODE -ne 0) {
    $changeCollectionFailed = $true
    $failed = $true
}

$changedDartFiles = @()
if (-not $changeCollectionFailed) {
    $changedDartFiles = @(
        $unstagedFiles + $cachedFiles |
            ForEach-Object { $_.Trim().Replace('\\', '/') } |
            Where-Object { $_ -match '^(lib|test|tool)/.+\.dart$' } |
            Sort-Object -Unique
    )
}

Write-Section -Name 'Changed Dart files'
if ($changeCollectionFailed) {
    Write-Output 'Changed Dart files: FAIL'
} elseif ($changedDartFiles.Count -eq 0) {
    Write-Output 'Changed Dart files: (none)'
} else {
    foreach ($file in $changedDartFiles) {
        Write-Output "  $file"
    }
}

$validatedTestPaths = @()
$testPathInvalid = $false
foreach ($path in $TestPath) {
    if ([string]::IsNullOrWhiteSpace($path)) {
        $testPathInvalid = $true
        continue
    }

    $normalizedPath = $path.Replace('\\', '/')
    $containsParentTraversal = @($normalizedPath.Split('/') | Where-Object { $_ -eq '..' }).Count -gt 0
    if ([System.IO.Path]::IsPathRooted($path) -or
        $containsParentTraversal -or
        $normalizedPath -notmatch '^test/.+_test\.dart$') {
        $testPathInvalid = $true
        continue
    }

    $validatedTestPaths += $normalizedPath
}
$validatedTestPaths = @($validatedTestPaths | Sort-Object -Unique)
$testTargets = @($validatedTestPaths)

Write-Section -Name 'Format check'
if ($changeCollectionFailed) {
    Write-Output 'Format check: NOT RUN (change collection failed)'
} elseif ($SkipFormatCheck) {
    Write-Output 'Format check: SKIPPED'
} elseif ($changedDartFiles.Count -eq 0 -and $validatedTestPaths.Count -eq 0) {
    Write-Output 'Format check: NOT RUN (no changed Dart files or explicit test paths)'
} else {
    $formatTargets = @($changedDartFiles)
    if ($formatTargets.Count -eq 0) {
        $formatTargets = @($validatedTestPaths)
        Write-Output 'Format check: no changed Dart files; checking explicit test paths'
    }
    & dart format --output=none --set-exit-if-changed @formatTargets
    $formatExitCode = $LASTEXITCODE
    if ($formatExitCode -eq 0) {
        Write-Output 'Format check: PASS'
    } else {
        Write-Output "Format check: FAIL (exit $formatExitCode)"
        Stop-Verification
    }
}

Write-Section -Name 'Analyze'
if ($changeCollectionFailed) {
    Write-Output 'Analyze: NOT RUN (change collection failed)'
} elseif ($SkipAnalyze) {
    Write-Output 'Analyze: SKIPPED'
} elseif ($changedDartFiles.Count -eq 0 -and $validatedTestPaths.Count -eq 0) {
    Write-Output 'Analyze: NOT RUN (no changed Dart files or explicit test paths)'
} else {
    $analyzeTargets = @($changedDartFiles)
    if ($analyzeTargets.Count -eq 0) {
        $analyzeTargets = @($validatedTestPaths)
        Write-Output 'Analyze: no changed Dart files; checking explicit test paths'
    }
    & flutter analyze @analyzeTargets
    $analyzeExitCode = $LASTEXITCODE
    if ($analyzeExitCode -eq 0) {
        Write-Output 'Analyze: PASS'
    } else {
        Write-Output "Analyze: FAIL (exit $analyzeExitCode)"
        Stop-Verification
    }
}

Write-Section -Name 'Tests target files'
if ($testTargets.Count -eq 0) {
    Write-Output 'Tests target files: (none)'
} else {
    foreach ($file in $testTargets) {
        Write-Output "  $file"
    }
}

Write-Section -Name 'Tests'
if ($testPathInvalid) {
    Write-Output 'Tests: FAIL (invalid explicit test path)'
    $failed = $true
} elseif ($testTargets.Count -eq 0) {
    Write-Output 'Tests: NOT RUN'
} else {
    & flutter test --concurrency=1 @testTargets
    $testExitCode = $LASTEXITCODE
    if ($testExitCode -eq 0) {
        Write-Output 'Tests: PASS'
    } else {
        Write-Output "Tests: FAIL (exit $testExitCode)"
        $failed = $true
    }
}

Write-Section -Name 'Diff check'
& git diff --check
$workingDiffExitCode = $LASTEXITCODE
& git diff --cached --check
$cachedDiffExitCode = $LASTEXITCODE
if ($workingDiffExitCode -eq 0 -and $cachedDiffExitCode -eq 0) {
    Write-Output 'Diff check: PASS'
} else {
    Write-Output "Diff check: FAIL (working=$workingDiffExitCode, cached=$cachedDiffExitCode)"
    $failed = $true
}

Write-Section -Name 'Git status'
$statusOutput = @(& git status --short)
$statusExitCode = $LASTEXITCODE
if ($statusExitCode -ne 0) {
    Write-Output "Git status: FAIL (exit $statusExitCode)"
    $failed = $true
} elseif ($statusOutput.Count -ne 0) {
    foreach ($line in $statusOutput) {
        Write-Output $line
    }
    Write-Output 'Git status: FAIL (working tree not clean)'
    $failed = $true
} else {
    Write-Output 'Git status: PASS (clean)'
}

if ($failed) {
    $verdict = 'FAIL'
} elseif ($testTargets.Count -eq 0) {
    $verdict = 'NOTHING_TO_VERIFY'
} else {
    $verdict = 'PASS'
}

Write-Section -Name 'Final verdict'
Write-Output $verdict

if ($verdict -eq 'FAIL') {
    exit 1
}
exit 0
