[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Assert-True {
    param(
        [Parameter(Mandatory)]
        [bool]$Condition,
        [Parameter(Mandatory)]
        [string]$Message
    )

    if (-not $Condition) {
        throw "Assertion failed: $Message"
    }
}

function Invoke-VerifyChanged {
    param(
        [string[]]$ScriptArguments = @()
    )

    $hostExecutable = (Get-Process -Id $PID).Path
    $arguments = @(
        '-NoProfile',
        '-ExecutionPolicy',
        'Bypass',
        '-File',
        $script:verifyScript
    )
    $arguments += $ScriptArguments

    $commandOutput = @(& $hostExecutable @arguments 2>&1)
    [pscustomobject]@{
        ExitCode = $LASTEXITCODE
        Output = $commandOutput -join "`n"
    }
}

function Reset-InvocationLog {
    Set-Content -LiteralPath $script:toolLog -Value '' -Encoding ASCII
}

$repositoryRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
$script:verifyScript = Join-Path $repositoryRoot 'tool\verify_changed.ps1'
$skillFile = Join-Path $repositoryRoot '.agents\skills\shiroha-import-audit\SKILL.md'

Assert-True -Condition (Test-Path -LiteralPath $script:verifyScript -PathType Leaf) `
    -Message 'verify_changed.ps1 must exist'
Assert-True -Condition (Test-Path -LiteralPath $skillFile -PathType Leaf) `
    -Message 'shiroha-import-audit SKILL.md must exist'

$parseTokens = $null
$parseErrors = $null
$null = [System.Management.Automation.Language.Parser]::ParseFile(
    $script:verifyScript,
    [ref]$parseTokens,
    [ref]$parseErrors
)
Assert-True -Condition ($parseErrors.Count -eq 0) `
    -Message 'verify_changed.ps1 must parse without PowerShell AST errors'

$verifySource = Get-Content -LiteralPath $script:verifyScript -Raw -Encoding UTF8
Assert-True -Condition ($verifySource.Contains('dart format --output=none --set-exit-if-changed')) `
    -Message 'format invocation must be read-only'
Assert-True -Condition ($verifySource.Contains('git diff --cached --name-only --diff-filter=ACMRT --')) `
    -Message 'cached tracked changes must be collected'
Assert-True -Condition ($verifySource -match "'diff',\s*'--name-only',\s*'--diff-filter=ACMRT'") `
    -Message 'working-tree tracked changes must be collected'
Assert-True -Condition ($verifySource -notmatch '(?im)^\s*&?\s*git\s+(add|commit|push)\b') `
    -Message 'verification script must not mutate Git history or index'
Assert-True -Condition ($verifySource -notmatch '(?im)^\s*&?\s*flutter\s+build\b') `
    -Message 'verification script must not build applications'
Assert-True -Condition ($verifySource -notmatch '(?i)run_ocr|savedkey|refreshocr|writereplay') `
    -Message 'verification script must not expose OCR, saved-key, or replay-write paths'

$skillSource = Get-Content -LiteralPath $skillFile -Raw -Encoding UTF8
Assert-True -Condition ($skillSource -match '(?ms)\A---\s*name:\s*shiroha-import-audit\s*description:\s*.+?\s*---') `
    -Message 'skill frontmatter must expose the expected name and description'
Assert-True -Condition ($skillSource -notmatch '(?i)[A-Z]:\\Users\\') `
    -Message 'skill must not contain a private absolute user path'
Assert-True -Condition ($skillSource -notmatch '(?i)Authorization\s*:\s*Bearer\s+\S+') `
    -Message 'skill must not contain an authorization value'

$tempBase = [System.IO.Path]::GetFullPath([System.IO.Path]::GetTempPath())
$tempRoot = [System.IO.Path]::GetFullPath(
    (Join-Path $tempBase ("shiroha-verify-contract-" + [Guid]::NewGuid().ToString('N')))
)
$fakeRepository = Join-Path $tempRoot 'repo'
$shimDirectory = Join-Path $tempRoot 'bin'
$unstagedFile = Join-Path $tempRoot 'unstaged.txt'
$cachedFile = Join-Path $tempRoot 'cached.txt'
$statusFile = Join-Path $tempRoot 'status.txt'
$script:toolLog = Join-Path $tempRoot 'tools.log'
$originalPath = $env:PATH

try {
    $null = New-Item -ItemType Directory -Path $fakeRepository -Force
    $null = New-Item -ItemType Directory -Path $shimDirectory -Force
    $null = New-Item -ItemType Directory -Path (Join-Path $fakeRepository 'test') -Force

    Set-Content -LiteralPath (Join-Path $fakeRepository 'test\untracked.dart') `
        -Value 'sentinel content that must never reach a tool invocation' -Encoding UTF8
    Set-Content -LiteralPath $unstagedFile -Value '' -Encoding ASCII
    Set-Content -LiteralPath $cachedFile -Value '' -Encoding ASCII
    Set-Content -LiteralPath $statusFile -Value '?? test/untracked.dart' -Encoding ASCII
    Reset-InvocationLog

    Set-Content -LiteralPath (Join-Path $shimDirectory 'git.cmd') -Encoding ASCII -Value @'
@echo off
echo git %*>>"%VERIFY_CHANGED_TOOL_LOG%"
if "%1"=="rev-parse" (
  echo %VERIFY_CHANGED_REPO_ROOT%
  exit /b 0
)
if "%1"=="diff" (
  echo %*| findstr /C:"--check" >nul
  if not errorlevel 1 exit /b %VERIFY_CHANGED_DIFF_EXIT%
  echo %*| findstr /C:"--cached" >nul
  if not errorlevel 1 (
    if exist "%VERIFY_CHANGED_CACHED_FILE%" type "%VERIFY_CHANGED_CACHED_FILE%"
    exit /b 0
  )
  if exist "%VERIFY_CHANGED_UNSTAGED_FILE%" type "%VERIFY_CHANGED_UNSTAGED_FILE%"
  exit /b 0
)
if "%1"=="status" (
  if exist "%VERIFY_CHANGED_STATUS_FILE%" type "%VERIFY_CHANGED_STATUS_FILE%
  exit /b %VERIFY_CHANGED_STATUS_EXIT%
)
exit /b 0
'@

    Set-Content -LiteralPath (Join-Path $shimDirectory 'dart.cmd') -Encoding ASCII -Value @'
@echo off
echo dart %*>>"%VERIFY_CHANGED_TOOL_LOG%"
exit /b %VERIFY_CHANGED_DART_EXIT%
'@

    Set-Content -LiteralPath (Join-Path $shimDirectory 'flutter.cmd') -Encoding ASCII -Value @'
@echo off
echo flutter %*>>"%VERIFY_CHANGED_TOOL_LOG%"
if /I "%1"=="analyze" exit /b %VERIFY_CHANGED_ANALYZE_EXIT%
if /I "%1"=="test" exit /b %VERIFY_CHANGED_TEST_EXIT%
exit /b 0
'@

    $env:PATH = "$shimDirectory;$originalPath"
    $env:VERIFY_CHANGED_REPO_ROOT = $fakeRepository
    $env:VERIFY_CHANGED_TOOL_LOG = $script:toolLog
    $env:VERIFY_CHANGED_UNSTAGED_FILE = $unstagedFile
    $env:VERIFY_CHANGED_CACHED_FILE = $cachedFile
    $env:VERIFY_CHANGED_STATUS_FILE = $statusFile
    $env:VERIFY_CHANGED_DIFF_EXIT = '0'
    $env:VERIFY_CHANGED_STATUS_EXIT = '0'
    $env:VERIFY_CHANGED_DART_EXIT = '0'
    $env:VERIFY_CHANGED_ANALYZE_EXIT = '0'
    $env:VERIFY_CHANGED_TEST_EXIT = '0'

    $nothingResult = Invoke-VerifyChanged -ScriptArguments @('-SkipAnalyze', '-SkipFormatCheck')
    $nothingLog = Get-Content -LiteralPath $script:toolLog -Raw
    Assert-True -Condition ($nothingResult.ExitCode -eq 0) `
        -Message 'empty tracked changes must exit successfully'
    Assert-True -Condition ($nothingResult.Output -match 'Tests: NOT RUN') `
        -Message 'omitted TestPath must report NOT RUN'
    Assert-True -Condition ($nothingResult.Output -match '(?m)^NOTHING_TO_VERIFY$') `
        -Message 'empty tracked changes must return NOTHING_TO_VERIFY'
    Assert-True -Condition ($nothingLog -notmatch '(?m)^(dart|flutter) ') `
        -Message 'untracked status entries must not trigger Dart or Flutter'

    Set-Content -LiteralPath $unstagedFile -Value @('lib/sample.dart', 'README.md') -Encoding ASCII
    Set-Content -LiteralPath $cachedFile -Value 'tool/helper.dart' -Encoding ASCII
    Reset-InvocationLog
    $changedResult = Invoke-VerifyChanged
    $changedLog = Get-Content -LiteralPath $script:toolLog -Raw
    Assert-True -Condition ($changedResult.ExitCode -eq 0) `
        -Message 'successful focused checks must exit successfully'
    Assert-True -Condition ($changedResult.Output -match '(?m)^PASS$') `
        -Message 'successful focused checks must return PASS'
    Assert-True -Condition ($changedLog -match '(?m)^dart format --output=none --set-exit-if-changed .*lib/sample\.dart') `
        -Message 'tracked lib Dart file must receive read-only format checking'
    Assert-True -Condition ($changedLog -match '(?m)^flutter analyze .*lib/sample\.dart') `
        -Message 'tracked lib Dart file must receive focused analyze'
    Assert-True -Condition ($changedLog -match 'tool/helper\.dart') `
        -Message 'cached tracked Dart file must be included'
    Assert-True -Condition ($changedLog -notmatch 'untracked\.dart|sentinel content') `
        -Message 'untracked file must not be passed to tools or read'
    Assert-True -Condition ($changedLog -notmatch '(?m)^flutter test ') `
        -Message 'tests must not be inferred from changed files'

    Set-Content -LiteralPath $unstagedFile -Value '' -Encoding ASCII
    Set-Content -LiteralPath $cachedFile -Value '' -Encoding ASCII
    Reset-InvocationLog
    $explicitTestResult = Invoke-VerifyChanged -ScriptArguments @(
        '-SkipAnalyze',
        '-SkipFormatCheck',
        '-TestPath',
        'test/sample_test.dart'
    )
    $explicitTestLog = Get-Content -LiteralPath $script:toolLog -Raw
    Assert-True -Condition ($explicitTestResult.ExitCode -eq 0) `
        -Message 'explicit successful test must exit successfully'
    Assert-True -Condition ($explicitTestLog -match '(?m)^flutter test --concurrency=1 test/sample_test\.dart\r?$') `
        -Message 'only an explicit TestPath may invoke flutter test'

    Reset-InvocationLog
    $supportFileResult = Invoke-VerifyChanged -ScriptArguments @(
        '-SkipAnalyze',
        '-SkipFormatCheck',
        '-TestPath',
        'test/sample_test_support.dart'
    )
    $supportFileLog = Get-Content -LiteralPath $script:toolLog -Raw
    Assert-True -Condition ($supportFileResult.ExitCode -eq 1) `
        -Message 'test support/helper Dart files must be rejected as standalone test entrypoints'
    Assert-True -Condition ($supportFileResult.Output -match 'Tests: FAIL \(invalid explicit test path\)') `
        -Message 'invalid helper TestPath must report an explicit validation failure'
    Assert-True -Condition ($supportFileLog -notmatch '(?m)^flutter test ') `
        -Message 'invalid helper TestPath must never reach flutter test'

    $env:VERIFY_CHANGED_TEST_EXIT = '7'
    Reset-InvocationLog
    $failedTestResult = Invoke-VerifyChanged -ScriptArguments @(
        '-SkipAnalyze',
        '-SkipFormatCheck',
        '-TestPath',
        'test/sample_test.dart'
    )
    $failedTestLog = Get-Content -LiteralPath $script:toolLog -Raw
    Assert-True -Condition ($failedTestResult.ExitCode -eq 1) `
        -Message 'a failed command must propagate a failing process exit'
    Assert-True -Condition ($failedTestResult.Output -match 'Tests: FAIL \(exit 7\)') `
        -Message 'a failed test must preserve its exit code in the summary'
    Assert-True -Condition ($failedTestResult.Output -match '(?m)^FAIL$') `
        -Message 'a failed command must produce FAIL'
    Assert-True -Condition (([regex]::Matches($failedTestLog, '(?m)^flutter test ')).Count -eq 1) `
        -Message 'a failed command must not be retried'

    Write-Output 'verify_changed contract tests: PASS'
} finally {
    $env:PATH = $originalPath
    Remove-Item Env:VERIFY_CHANGED_REPO_ROOT -ErrorAction SilentlyContinue
    Remove-Item Env:VERIFY_CHANGED_TOOL_LOG -ErrorAction SilentlyContinue
    Remove-Item Env:VERIFY_CHANGED_UNSTAGED_FILE -ErrorAction SilentlyContinue
    Remove-Item Env:VERIFY_CHANGED_CACHED_FILE -ErrorAction SilentlyContinue
    Remove-Item Env:VERIFY_CHANGED_STATUS_FILE -ErrorAction SilentlyContinue
    Remove-Item Env:VERIFY_CHANGED_DIFF_EXIT -ErrorAction SilentlyContinue
    Remove-Item Env:VERIFY_CHANGED_STATUS_EXIT -ErrorAction SilentlyContinue
    Remove-Item Env:VERIFY_CHANGED_DART_EXIT -ErrorAction SilentlyContinue
    Remove-Item Env:VERIFY_CHANGED_ANALYZE_EXIT -ErrorAction SilentlyContinue
    Remove-Item Env:VERIFY_CHANGED_TEST_EXIT -ErrorAction SilentlyContinue

    if ($tempRoot.StartsWith($tempBase, [System.StringComparison]::OrdinalIgnoreCase) -and
        (Test-Path -LiteralPath $tempRoot)) {
        Remove-Item -LiteralPath $tempRoot -Recurse -Force
    }
}
