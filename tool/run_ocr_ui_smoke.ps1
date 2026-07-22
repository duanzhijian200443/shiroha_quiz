[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [ValidateNotNullOrEmpty()]
    [string]$Pdf,

    [switch]$Commit,

    [ValidateRange(1, 100000)]
    [int]$ExpectedQuestionCount,

    [string]$ExpectedNumbers,

    # Compatibility switch. Automatic mode already closes after success;
    # in interactive mode this switch opts back into automatic closing.
    [switch]$CloseOnSuccess,

    [switch]$SkipBuild,

    [ValidateRange(1, 86400)]
    [int]$BuildTimeoutSeconds = 600,

    [ValidateRange(1, 86400)]
    [int]$RunTimeoutSeconds = 900,

    [switch]$Interactive
)

$ErrorActionPreference = 'Stop'
$scriptDirectory = Split-Path -Parent $MyInvocation.MyCommand.Path
$repositoryRoot = [System.IO.Path]::GetFullPath((Join-Path $scriptDirectory '..'))
$privatePdfRoot = [System.IO.Path]::GetFullPath(
    (Join-Path $repositoryRoot 'scratch\test_pdfs')
)
$runtimeRoot = [System.IO.Path]::GetFullPath(
    (Join-Path ([System.IO.Path]::GetTempPath()) 'shiroha-ocr-ui-smoke')
)
$runtimeDirectory = Join-Path $runtimeRoot ([Guid]::NewGuid().ToString('N'))
$buildProcess = $null
$process = $null
$secureKey = $null
$keyPointer = [IntPtr]::Zero
$plainKey = $null

function Write-SafeStatus {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Stage,

        [Parameter(Mandatory = $true)]
        [string]$Status,

        [long]$DurationMs = -1
    )

    $safe = [ordered]@{
        stage = $Stage
        status = $Status
    }
    if ($DurationMs -ge 0) {
        $safe['durationMs'] = $DurationMs
    }
    Write-Output ($safe | ConvertTo-Json -Compress)
}

function Stop-OwnedProcessTree {
    param(
        [System.Diagnostics.Process]$OwnedProcess
    )

    if ($null -eq $OwnedProcess) { return }

    try {
        if ($OwnedProcess.HasExited) { return }

        $taskkillPath = Join-Path $env:SystemRoot 'System32\taskkill.exe'
        if ([System.IO.File]::Exists($taskkillPath)) {
            $taskkillArguments = @(
                '/PID',
                [string]$OwnedProcess.Id,
                '/T',
                '/F'
            )
            $taskkillStartInfo = [System.Diagnostics.ProcessStartInfo]::new()
            $taskkillStartInfo.FileName = $taskkillPath
            $taskkillStartInfo.Arguments = [string]::Join(' ', $taskkillArguments)
            $taskkillStartInfo.UseShellExecute = $false
            $taskkillStartInfo.CreateNoWindow = $true
            $taskkillStartInfo.RedirectStandardOutput = $true
            $taskkillStartInfo.RedirectStandardError = $true

            $taskkillProcess = [System.Diagnostics.Process]::new()
            try {
                $taskkillProcess.StartInfo = $taskkillStartInfo
                if ($taskkillProcess.Start()) {
                    $taskkillOutput = $taskkillProcess.StandardOutput.ReadToEndAsync()
                    $taskkillError = $taskkillProcess.StandardError.ReadToEndAsync()
                    if (-not $taskkillProcess.WaitForExit(5000)) {
                        $taskkillProcess.Kill()
                        $null = $taskkillProcess.WaitForExit(2000)
                    }
                    # Keep both redirected streams drained without forwarding them.
                    $null = $taskkillOutput
                    $null = $taskkillError
                }
            }
            finally {
                $taskkillProcess.Dispose()
            }
        }

        if (-not $OwnedProcess.HasExited) {
            # Exact-root fallback only; taskkill above is responsible for the tree.
            $OwnedProcess.Kill()
            $null = $OwnedProcess.WaitForExit(2000)
        }
    }
    catch {
        # Cleanup must not expose process or environment details.
    }
}

function Test-RelativePdfArgument {
    param([string]$Value)

    if ([System.IO.Path]::IsPathRooted($Value)) { return $false }
    if ($Value.Contains('..') -or $Value.Contains('"')) { return $false }
    if ([System.IO.Path]::GetExtension($Value) -ne '.pdf') { return $false }

    $resolved = [System.IO.Path]::GetFullPath((Join-Path $privatePdfRoot $Value))
    $rootWithSeparator = $privatePdfRoot.TrimEnd('\') + '\'
    return $resolved.StartsWith(
        $rootWithSeparator,
        [System.StringComparison]::OrdinalIgnoreCase
    ) -and [System.IO.File]::Exists($resolved)
}

function ConvertTo-ProcessArgument {
    param([string]$Value)
    if ($Value.Contains('"')) {
        throw 'Arguments containing quotation marks are not supported.'
    }
    return '"' + $Value + '"'
}

try {
    if (-not (Test-RelativePdfArgument -Value $Pdf)) {
        throw 'Pdf must name one existing PDF below scratch/test_pdfs.'
    }
    if ($ExpectedNumbers -and
        $ExpectedNumbers -notmatch '^\d+(?:-\d+)?(?:,\d+(?:-\d+)?)*$') {
        throw 'ExpectedNumbers must use a form such as 1-22 or 1-3,5.'
    }

    [System.IO.Directory]::CreateDirectory($runtimeDirectory) | Out-Null
    $executable = Join-Path $repositoryRoot 'build\windows\x64\runner\Release\shiroha_quiz.exe'

    if (-not $SkipBuild) {
        $flutterCommand = Get-Command flutter -CommandType Application -ErrorAction Stop
        $commandInterpreter = $env:ComSpec
        if ([string]::IsNullOrWhiteSpace($commandInterpreter)) {
            throw 'The Windows command interpreter is unavailable.'
        }

        $buildStartInfo = [System.Diagnostics.ProcessStartInfo]::new()
        $buildStartInfo.FileName = $commandInterpreter
        $buildStartInfo.WorkingDirectory = $repositoryRoot
        $buildStartInfo.Arguments = '/d /s /c ""' + $flutterCommand.Source +
            '" build windows --release -t lib/main_ocr_ui_smoke.dart"'
        $buildStartInfo.UseShellExecute = $false
        $buildStartInfo.CreateNoWindow = $true
        $buildStartInfo.RedirectStandardOutput = $true
        $buildStartInfo.RedirectStandardError = $true

        $buildProcess = [System.Diagnostics.Process]::new()
        $buildProcess.StartInfo = $buildStartInfo
        if (-not $buildProcess.Start()) {
            throw 'Failed to start the Windows build process.'
        }

        $buildStdoutClosed = $false
        $buildStderrClosed = $false
        $buildStdoutRead = $buildProcess.StandardOutput.ReadLineAsync()
        $buildStderrRead = $buildProcess.StandardError.ReadLineAsync()
        $buildStopwatch = [System.Diagnostics.Stopwatch]::StartNew()
        $nextBuildHeartbeatMs = 30000L
        $buildTimeoutMs = [long]$BuildTimeoutSeconds * 1000L
        Write-SafeStatus -Stage 'build' -Status 'running' -DurationMs 0

        while (-not $buildProcess.HasExited) {
            $buildStdoutDrainCount = 0
            while (-not $buildStdoutClosed -and
                $buildStdoutRead.IsCompleted -and
                $buildStdoutDrainCount -lt 256) {
                $buildStdoutDrainCount++
                try {
                    $buildLine = $buildStdoutRead.GetAwaiter().GetResult()
                }
                catch {
                    $buildLine = $null
                }
                if ($null -eq $buildLine) {
                    $buildStdoutClosed = $true
                }
                else {
                    # Build output may contain paths or configuration; drain only.
                    $buildStdoutRead = $buildProcess.StandardOutput.ReadLineAsync()
                }
            }
            $buildStderrDrainCount = 0
            while (-not $buildStderrClosed -and
                $buildStderrRead.IsCompleted -and
                $buildStderrDrainCount -lt 256) {
                $buildStderrDrainCount++
                try {
                    $buildErrorLine = $buildStderrRead.GetAwaiter().GetResult()
                }
                catch {
                    $buildErrorLine = $null
                }
                if ($null -eq $buildErrorLine) {
                    $buildStderrClosed = $true
                }
                else {
                    # Never forward raw build stderr to structured stdout.
                    $buildStderrRead = $buildProcess.StandardError.ReadLineAsync()
                }
            }

            if ($buildStopwatch.ElapsedMilliseconds -ge $buildTimeoutMs) {
                Write-SafeStatus -Stage 'build' -Status 'timeout'
                Stop-OwnedProcessTree -OwnedProcess $buildProcess
                exit 1
            }
            if ($buildStopwatch.ElapsedMilliseconds -ge $nextBuildHeartbeatMs) {
                Write-SafeStatus `
                    -Stage 'build' `
                    -Status 'running' `
                    -DurationMs $buildStopwatch.ElapsedMilliseconds
                $nextBuildHeartbeatMs += 30000L
            }
            Start-Sleep -Milliseconds 50
        }

        $buildStopwatch.Stop()
        $buildExitCode = $buildProcess.ExitCode
        $buildProcess.Dispose()
        $buildProcess = $null
        if ($buildExitCode -ne 0) {
            Write-SafeStatus -Stage 'build' -Status 'failed'
            exit 1
        }
        Write-SafeStatus `
            -Stage 'build' `
            -Status 'success' `
            -DurationMs $buildStopwatch.ElapsedMilliseconds
    }
    else {
        Write-SafeStatus -Stage 'build' -Status 'skipped'
    }

    if (-not [System.IO.File]::Exists($executable)) {
        Write-SafeStatus -Stage 'build' -Status 'executable_missing'
        exit 1
    }

    $plainKey = [Environment]::GetEnvironmentVariable(
        'SHIROHA_OCR_API_KEY',
        [System.EnvironmentVariableTarget]::Process
    )
    if ([string]::IsNullOrWhiteSpace($plainKey)) {
        $plainKey = $null
        if (-not $Interactive) {
            Write-SafeStatus -Stage 'failed' -Status 'missing_api_key'
            exit 1
        }

        $secureKey = Read-Host 'SHIROHA_OCR_API_KEY' -AsSecureString
        $keyPointer = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($secureKey)
        $plainKey = [Runtime.InteropServices.Marshal]::PtrToStringBSTR($keyPointer)
        if ([string]::IsNullOrWhiteSpace($plainKey)) {
            Write-SafeStatus -Stage 'failed' -Status 'missing_api_key'
            exit 1
        }
    }

    $arguments = [System.Collections.Generic.List[string]]::new()
    $arguments.Add((ConvertTo-ProcessArgument "--pdf=$Pdf"))
    if ($Commit) { $arguments.Add('"--commit"') }
    if ($PSBoundParameters.ContainsKey('ExpectedQuestionCount')) {
        $arguments.Add((ConvertTo-ProcessArgument "--expected-question-count=$ExpectedQuestionCount"))
    }
    if ($ExpectedNumbers) {
        $arguments.Add((ConvertTo-ProcessArgument "--expected-numbers=$ExpectedNumbers"))
    }
    if ($CloseOnSuccess) { $arguments.Add('"--close-on-success"') }

    $startInfo = [System.Diagnostics.ProcessStartInfo]::new()
    $startInfo.FileName = $executable
    $startInfo.WorkingDirectory = $repositoryRoot
    $startInfo.Arguments = [string]::Join(' ', $arguments)
    $startInfo.UseShellExecute = $false
    $startInfo.CreateNoWindow = $false
    $startInfo.RedirectStandardOutput = $true
    $startInfo.RedirectStandardError = $true
    $startInfo.EnvironmentVariables['SHIROHA_OCR_API_KEY'] = $plainKey
    $startInfo.EnvironmentVariables['SHIROHA_UI_SMOKE_RUNTIME_DIR'] = $runtimeDirectory

    $process = [System.Diagnostics.Process]::new()
    $process.StartInfo = $startInfo
    if (-not $process.Start()) {
        throw 'Failed to start the Windows OCR UI smoke executable.'
    }

    $startInfo.EnvironmentVariables.Remove('SHIROHA_OCR_API_KEY')
    $plainKey = $null
    if ($keyPointer -ne [IntPtr]::Zero) {
        [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($keyPointer)
        $keyPointer = [IntPtr]::Zero
    }

    $stdoutClosed = $false
    $stderrClosed = $false
    $stdoutRead = $process.StandardOutput.ReadLineAsync()
    $stderrRead = $process.StandardError.ReadLineAsync()
    $runStopwatch = [System.Diagnostics.Stopwatch]::StartNew()
    $runTimeoutMs = [long]$RunTimeoutSeconds * 1000L
    $terminalOutcome = $null
    $explicitFailureStatuses = @(
        'missing_api_key',
        'invalid_arguments',
        'pdf_not_found',
        'pdf_outside_private_root',
        'pdf_resolution_failed',
        'missing_runtime_directory',
        'quality_gate_blocked',
        'duplicate_question_numbers',
        'expected_question_count_mismatch',
        'unexpected_question_numbers'
    )

    while ($true) {
        $stdoutDrainCount = 0
        while (-not $stdoutClosed -and
            $stdoutRead.IsCompleted -and
            $stdoutDrainCount -lt 256) {
            $stdoutDrainCount++
            try {
                $line = $stdoutRead.GetAwaiter().GetResult()
            }
            catch {
                $line = $null
            }
            if ($null -eq $line) {
                $stdoutClosed = $true
                break
            }
            $stdoutRead = $process.StandardOutput.ReadLineAsync()
            if ([string]::IsNullOrWhiteSpace($line)) { continue }

            try {
                $event = $line | ConvertFrom-Json -ErrorAction Stop
            }
            catch {
                continue
            }
            if (-not $event.stage -or -not $event.status) { continue }

            $safe = [ordered]@{}
            foreach ($name in @(
                'stage', 'status', 'apiKeyPresent', 'fileName', 'traceId',
                'taskId', 'screen', 'questionCount', 'importMode',
                'databaseProfile', 'durationMs', 'rawQuestionNumberCount',
                'finalQuestionCount', 'duplicateQuestionNumberCount',
                'missingQuestionNumberCount', 'unexpectedQuestionNumberCount',
                'qualityGateBlocked', 'warningCount', 'causeType'
            )) {
                if ($event.PSObject.Properties.Name -contains $name) {
                    $safe[$name] = $event.$name
                }
            }

            $stage = [string]$event.stage
            $status = [string]$event.status
            Write-Output ($safe | ConvertTo-Json -Compress)

            if ($null -eq $terminalOutcome) {
                if ($stage -eq 'ui_ready' -and $status -eq 'success') {
                    $terminalOutcome = 'success'
                }
                elseif ($stage -eq 'failed' -or
                    $explicitFailureStatuses -contains $status) {
                    $terminalOutcome = 'failure'
                }
            }
        }

        $stderrDrainCount = 0
        while (-not $stderrClosed -and
            $stderrRead.IsCompleted -and
            $stderrDrainCount -lt 256) {
            $stderrDrainCount++
            try {
                $errorLine = $stderrRead.GetAwaiter().GetResult()
            }
            catch {
                $errorLine = $null
            }
            if ($null -eq $errorLine) {
                $stderrClosed = $true
            }
            else {
                # Application stderr may contain private paths or OCR content.
                $stderrRead = $process.StandardError.ReadLineAsync()
            }
        }

        if ($terminalOutcome -eq 'failure') {
            Stop-OwnedProcessTree -OwnedProcess $process
            exit 1
        }
        if ($terminalOutcome -eq 'success') {
            if (-not $Interactive -or $CloseOnSuccess) {
                Stop-OwnedProcessTree -OwnedProcess $process
                exit 0
            }
        }

        if ($runStopwatch.ElapsedMilliseconds -ge $runTimeoutMs) {
            Write-SafeStatus -Stage 'run' -Status 'timeout'
            Stop-OwnedProcessTree -OwnedProcess $process
            exit 1
        }

        if ($process.HasExited -and $stdoutClosed) {
            if ($terminalOutcome -eq 'success') {
                exit 0
            }
            Write-SafeStatus -Stage 'run' -Status 'missing_terminal_event'
            exit 1
        }

        Start-Sleep -Milliseconds 50
    }
}
catch {
    Write-SafeStatus -Stage 'failed' -Status 'launcher_failed'
    exit 1
}
finally {
    Stop-OwnedProcessTree -OwnedProcess $buildProcess
    Stop-OwnedProcessTree -OwnedProcess $process

    if ($buildProcess) { $buildProcess.Dispose() }
    if ($process) { $process.Dispose() }
    if ($keyPointer -ne [IntPtr]::Zero) {
        [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($keyPointer)
    }
    $plainKey = $null
    $secureKey = $null

    try {
        $resolvedRuntimeRoot = [System.IO.Path]::GetFullPath($runtimeRoot).TrimEnd('\') + '\'
        $resolvedRuntimeDirectory = [System.IO.Path]::GetFullPath($runtimeDirectory)
        if ($resolvedRuntimeDirectory.StartsWith(
                $resolvedRuntimeRoot,
                [System.StringComparison]::OrdinalIgnoreCase
            ) -and (Test-Path -LiteralPath $resolvedRuntimeDirectory)) {
            Remove-Item -LiteralPath $resolvedRuntimeDirectory -Recurse -Force
        }
    }
    catch {
        # Runtime cleanup failures must remain redacted.
    }
}
