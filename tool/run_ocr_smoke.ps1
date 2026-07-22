[CmdletBinding()]
param(
    [Parameter(Mandatory = $true, Position = 0)]
    [ValidateCount(1, 2)]
    [string[]]$Pdf
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Write-SafeJson {
    param(
        [Parameter(Mandatory = $true)]
        [hashtable]$Value
    )

    Write-Output ($Value | ConvertTo-Json -Compress)
}

$repoRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$executablePath = Join-Path $repoRoot 'build\windows\x64\runner\Release\shiroha_quiz.exe'
$secureApiKey = $null
$apiKeyPointer = [IntPtr]::Zero
$apiKey = $null
$startInfo = $null
$process = $null
$locationPushed = $false

try {
    $toolArguments = @()
    foreach ($relativePdf in $Pdf) {
        if ([string]::IsNullOrWhiteSpace($relativePdf) -or
            [System.IO.Path]::IsPathRooted($relativePdf) -or
            $relativePdf.Contains('"') -or
            -not $relativePdf.EndsWith('.pdf', [System.StringComparison]::OrdinalIgnoreCase)) {
            Write-SafeJson @{
                stage = 'launcher'
                status = 'failed'
                causeType = 'InvalidPdfArgument'
            }
            exit 2
        }
        $toolArguments += "--pdf=$relativePdf"
    }

    Push-Location -LiteralPath $repoRoot
    $locationPushed = $true

    flutter build windows --release -t tool/ocr_smoke.dart
    $buildExitCode = $LASTEXITCODE
    if ($buildExitCode -ne 0) {
        Write-SafeJson @{
            stage = 'launcher'
            status = 'failed'
            causeType = 'BuildFailed'
        }
        exit $buildExitCode
    }
    if (-not (Test-Path -LiteralPath $executablePath -PathType Leaf)) {
        Write-SafeJson @{
            stage = 'launcher'
            status = 'failed'
            causeType = 'ExecutableNotFound'
        }
        exit 1
    }

    $secureApiKey = Read-Host -Prompt 'SHIROHA_OCR_API_KEY' -AsSecureString
    $apiKeyPointer = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($secureApiKey)
    $apiKey = [Runtime.InteropServices.Marshal]::PtrToStringBSTR($apiKeyPointer)
    if ([string]::IsNullOrWhiteSpace($apiKey)) {
        Write-SafeJson @{
            stage = 'launcher'
            status = 'failed'
            causeType = 'MissingApiKey'
        }
        exit 2
    }

    $startInfo = New-Object System.Diagnostics.ProcessStartInfo
    $startInfo.FileName = $executablePath
    $startInfo.UseShellExecute = $false
    $startInfo.CreateNoWindow = $true
    $startInfo.RedirectStandardOutput = $true
    $startInfo.RedirectStandardError = $true
    $startInfo.EnvironmentVariables['SHIROHA_OCR_API_KEY'] = $apiKey
    $startInfo.Arguments = (($toolArguments | ForEach-Object { '"' + $_ + '"' }) -join ' ')

    $process = [System.Diagnostics.Process]::Start($startInfo)
    $startInfo.EnvironmentVariables.Remove('SHIROHA_OCR_API_KEY')
    [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($apiKeyPointer)
    $apiKeyPointer = [IntPtr]::Zero
    $apiKey = $null
    $secureApiKey.Dispose()
    $secureApiKey = $null

    $stdoutTask = $process.StandardOutput.ReadToEndAsync()
    $stderrTask = $process.StandardError.ReadToEndAsync()
    $process.WaitForExit()
    $standardOutput = $stdoutTask.Result
    $null = $stderrTask.Result
    $nativeExitCode = $process.ExitCode

    $safeStages = @(
        'preflight',
        'independent_parse',
        'combined_merge',
        'completed',
        'failed'
    )
    $lastStructuredStatus = $null
    foreach ($line in ($standardOutput -split "`r?`n")) {
        if ([string]::IsNullOrWhiteSpace($line)) {
            continue
        }
        try {
            $parsed = $line | ConvertFrom-Json -ErrorAction Stop
            if ($null -ne $parsed.stage -and $safeStages -contains [string]$parsed.stage) {
                Write-Output $line
                $lastStructuredStatus = $parsed
            }
        }
        catch {
            # Suppress non-contract output so provider diagnostics cannot leak.
        }
    }

    if ($null -eq $lastStructuredStatus) {
        Write-SafeJson @{
            stage = 'launcher'
            status = 'failed'
            causeType = 'MissingStructuredOutput'
        }
        exit $(if ($nativeExitCode -eq 0) { 1 } else { $nativeExitCode })
    }

    $reportedSuccess =
        $lastStructuredStatus.stage -eq 'completed' -and
        $lastStructuredStatus.status -eq 'success'
    if ($nativeExitCode -eq 0 -and -not $reportedSuccess) {
        exit 1
    }
    exit $nativeExitCode
}
catch {
    Write-SafeJson @{
        stage = 'launcher'
        status = 'failed'
        causeType = $_.Exception.GetType().Name
    }
    exit 1
}
finally {
    if ($null -ne $startInfo) {
        $startInfo.EnvironmentVariables.Remove('SHIROHA_OCR_API_KEY')
    }
    if ($null -ne $process) {
        try {
            if (-not $process.HasExited) {
                $process.Kill()
                $process.WaitForExit()
            }
        }
        catch {
            # Preserve the original safe failure result during cleanup.
        }
        $process.Dispose()
    }
    $apiKey = $null
    if ($apiKeyPointer -ne [IntPtr]::Zero) {
        [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($apiKeyPointer)
    }
    if ($null -ne $secureApiKey) {
        $secureApiKey.Dispose()
    }
    if ($locationPushed) {
        Pop-Location
    }
}
