[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Assert-True {
    param([bool]$Condition, [string]$Message)
    if (-not $Condition) { throw "Assertion failed: $Message" }
}

$repositoryRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
$verifyScript = Join-Path $repositoryRoot 'tool\verify_changed.ps1'
$fixtureBase = [System.IO.Path]::GetFullPath(
    (Join-Path $repositoryRoot '.dart_tool\verify-read-only-tests')
)
$fixtureRoot = [System.IO.Path]::GetFullPath(
    (Join-Path $fixtureBase ([Guid]::NewGuid().ToString('N')))
)
$fixtureRepository = Join-Path $fixtureRoot 'repo'
$shimDirectory = Join-Path $fixtureRoot 'bin'
$toolLog = Join-Path $fixtureRoot 'tools.log'
$originalPath = $env:PATH
$fixtureVariables = @(
    'VERIFY_READ_ONLY_REPO', 'VERIFY_READ_ONLY_LOG', 'VERIFY_READ_ONLY_UNSTAGED',
    'VERIFY_READ_ONLY_STAGED', 'VERIFY_READ_ONLY_FORMAT_EXIT'
)
$originalVariables = @{}
foreach ($name in $fixtureVariables) {
    $originalVariables[$name] = [Environment]::GetEnvironmentVariable($name, 'Process')
}

try {
    $null = New-Item -ItemType Directory -Path (Join-Path $fixtureRepository 'lib') -Force
    $null = New-Item -ItemType Directory -Path $shimDirectory -Force
    $unstagedSource = Join-Path $fixtureRepository 'lib\sample.dart'
    $stagedSource = Join-Path $fixtureRepository 'lib\staged.dart'
    Set-Content -LiteralPath $unstagedSource -Value 'synthetic unstaged implementation' -Encoding UTF8
    Set-Content -LiteralPath $stagedSource -Value 'synthetic staged implementation' -Encoding UTF8
    $originalUnstagedHash = (Get-FileHash -LiteralPath $unstagedSource).Hash
    $originalStagedHash = (Get-FileHash -LiteralPath $stagedSource).Hash

    Set-Content -LiteralPath (Join-Path $shimDirectory 'git.cmd') -Encoding ASCII -Value @'
@echo off
echo git %*>>"%VERIFY_READ_ONLY_LOG%"
if "%1"=="rev-parse" (
  echo %VERIFY_READ_ONLY_REPO%
  exit /b 0
)
if "%1"=="diff" (
  echo %*| findstr /C:"--check" >nul
  if not errorlevel 1 exit /b 0
  echo %*| findstr /C:"--cached" >nul
  if not errorlevel 1 (
    echo lib/staged.dart
    exit /b 0
  )
  echo lib/sample.dart
  exit /b 0
)
if "%1"=="restore" (
  echo synthetic index version>"%VERIFY_READ_ONLY_UNSTAGED%"
  echo synthetic index version>"%VERIFY_READ_ONLY_STAGED%"
)
exit /b 0
'@

    Set-Content -LiteralPath (Join-Path $shimDirectory 'dart.cmd') -Encoding ASCII -Value @'
@echo off
echo dart %*>>"%VERIFY_READ_ONLY_LOG%"
echo %*| findstr /C:"--output=none" >nul
if not errorlevel 1 exit /b %VERIFY_READ_ONLY_FORMAT_EXIT%
echo synthetic formatted version>"%VERIFY_READ_ONLY_UNSTAGED%"
echo synthetic formatted version>"%VERIFY_READ_ONLY_STAGED%"
exit /b 0
'@

    Set-Content -LiteralPath (Join-Path $shimDirectory 'flutter.cmd') -Encoding ASCII -Value @'
@echo off
echo flutter %*>>"%VERIFY_READ_ONLY_LOG%"
exit /b 0
'@

    $env:PATH = "$shimDirectory;$originalPath"
    $env:VERIFY_READ_ONLY_REPO = $fixtureRepository
    $env:VERIFY_READ_ONLY_LOG = $toolLog
    $env:VERIFY_READ_ONLY_UNSTAGED = $unstagedSource
    $env:VERIFY_READ_ONLY_STAGED = $stagedSource
    $hostExecutable = (Get-Process -Id $PID).Path

    foreach ($formatExit in @('1', '2')) {
        $env:VERIFY_READ_ONLY_FORMAT_EXIT = $formatExit
        Set-Content -LiteralPath $toolLog -Value '' -Encoding ASCII
        $output = @(& $hostExecutable -NoProfile -ExecutionPolicy Bypass -File $verifyScript 2>&1)
        $exitCode = $LASTEXITCODE
        $log = Get-Content -LiteralPath $toolLog -Raw
        $summary = $output -join "`n"

        Assert-True ($exitCode -eq 1) 'format rejection/tool failure must fail verification'
        Assert-True ($summary -match "Format check: FAIL \(exit $formatExit\)") `
            'the formatter exit code must be reported'
        Assert-True ($summary -match '(?m)^FAIL$') 'format failure must not produce acceptance'
        Assert-True (((Get-FileHash -LiteralPath $unstagedSource).Hash) -eq $originalUnstagedHash) `
            'format failure must preserve unstaged implementation bytes'
        Assert-True (((Get-FileHash -LiteralPath $stagedSource).Hash) -eq $originalStagedHash) `
            'format failure must preserve staged implementation bytes'
        Assert-True (([regex]::Matches($log, '(?m)^dart ')).Count -eq 1) `
            'format failure must not retry or run a writing formatter'
        Assert-True ($log -match '(?m)^dart format --output=none --set-exit-if-changed ') `
            'only read-only format checking is permitted'
        Assert-True ($log -notmatch '(?m)^git (restore|checkout|reset|clean|add|commit|push)\b') `
            'verification must not mutate the worktree, index or history'
        Assert-True ($log -notmatch '(?m)^flutter ') 'later gates must not run after format failure'
    }

    Write-Output 'verify_changed read-only regression: PASS'
} finally {
    $env:PATH = $originalPath
    foreach ($name in $fixtureVariables) {
        [Environment]::SetEnvironmentVariable($name, $originalVariables[$name], 'Process')
    }
    $expectedParent = $fixtureBase.TrimEnd('\') + '\'
    if (-not $fixtureRoot.StartsWith($expectedParent, [StringComparison]::OrdinalIgnoreCase)) {
        throw 'Fixture cleanup target is outside the intended directory'
    }
    if (Test-Path -LiteralPath $fixtureRoot) {
        Remove-Item -LiteralPath $fixtureRoot -Recurse -Force
    }
}
