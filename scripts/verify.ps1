$ErrorActionPreference = "Stop"

function Invoke-CheckedCommand {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Name,

        [Parameter(Mandatory = $true)]
        [scriptblock]$Command
    )

    Write-Host ""
    Write-Host "============================================================"
    Write-Host $Name
    Write-Host "============================================================"

    $stopwatch = [System.Diagnostics.Stopwatch]::StartNew()

    & $Command

    $exitCode = $LASTEXITCODE
    $stopwatch.Stop()

    if ($null -eq $exitCode) {
        $exitCode = 0
    }

    Write-Host ""
    Write-Host "Duration: $($stopwatch.Elapsed)"
    Write-Host "Exit code: $exitCode"

    if ($exitCode -ne 0) {
        throw "$Name failed with exit code $exitCode."
    }
}

$repositoryRoot = Split-Path -Parent $PSScriptRoot
Set-Location $repositoryRoot

Write-Host "Repository: $repositoryRoot"

Invoke-CheckedCommand `
    -Name "Checking Dart formatting" `
    -Command {
        dart format --output=none --set-exit-if-changed .
    }

Invoke-CheckedCommand `
    -Name "Running Flutter static analysis" `
    -Command {
        $oldEap = $ErrorActionPreference
        $ErrorActionPreference = "SilentlyContinue"
        $analysisText = (cmd.exe /c "flutter analyze 2>&1" | Out-String)
        $ErrorActionPreference = $oldEap
        Write-Host $analysisText
        $hasErrors = $analysisText -split "`r?\n" | Where-Object { $_ -match '^\s*error\s*-' }
        if ($hasErrors.Count -gt 0) {
            Write-Host "Static analysis errors found!" -ForegroundColor Red
            $global:LASTEXITCODE = 1
        } else {
            Write-Host "No static analysis errors found." -ForegroundColor Green
            $global:LASTEXITCODE = 0
        }
    }

Invoke-CheckedCommand `
    -Name "Running full Flutter test suite (serial)" `
    -Command {
        flutter test -j 1 --reporter expanded
    }

Write-Host ""
Write-Host "============================================================"
Write-Host "Verification completed successfully."
Write-Host "============================================================"
