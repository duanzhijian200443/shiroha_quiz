[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [ValidateNotNullOrEmpty()]
    [string]$Pdf,

    [switch]$Commit,

    [ValidateRange(1, 100000)]
    [int]$ExpectedQuestionCount,

    [string]$ExpectedNumbers,

    [switch]$CloseOnSuccess
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
$process = $null
$secureKey = $null
$keyPointer = [IntPtr]::Zero
$plainKey = $null
$lastStructuredStatus = $null
$lastStructuredStage = $null

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

    Push-Location $repositoryRoot
    try {
        & flutter build windows --release -t lib/main_ocr_ui_smoke.dart *> $null
        if ($LASTEXITCODE -ne 0) {
            Write-Output '{"stage":"failed","status":"build_failed"}'
            exit $LASTEXITCODE
        }
    }
    finally {
        Pop-Location
    }

    $secureKey = Read-Host 'SHIROHA_OCR_API_KEY' -AsSecureString
    $keyPointer = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($secureKey)
    $plainKey = [Runtime.InteropServices.Marshal]::PtrToStringBSTR($keyPointer)
    if ([string]::IsNullOrWhiteSpace($plainKey)) {
        throw 'A non-empty OCR API key is required.'
    }

    [System.IO.Directory]::CreateDirectory($runtimeDirectory) | Out-Null
    $executable = Join-Path $repositoryRoot 'build\windows\x64\runner\Release\shiroha_quiz.exe'
    if (-not [System.IO.File]::Exists($executable)) {
        throw 'The Windows release executable was not produced.'
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
    $process.EnableRaisingEvents = $true
    $process.add_ErrorDataReceived({ param($sender, $eventArgs) })
    if (-not $process.Start()) {
        throw 'Failed to start the Windows OCR UI smoke executable.'
    }
    $process.BeginErrorReadLine()

    $startInfo.EnvironmentVariables.Remove('SHIROHA_OCR_API_KEY')
    $plainKey = $null
    if ($keyPointer -ne [IntPtr]::Zero) {
        [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($keyPointer)
        $keyPointer = [IntPtr]::Zero
    }

    while (-not $process.StandardOutput.EndOfStream) {
        $line = $process.StandardOutput.ReadLine()
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
            'databaseProfile', 'durationMs', 'duplicateQuestionNumberCount',
            'missingQuestionNumberCount', 'warningCount', 'causeType'
        )) {
            if ($event.PSObject.Properties.Name -contains $name) {
                $safe[$name] = $event.$name
            }
        }
        $lastStructuredStage = [string]$event.stage
        $lastStructuredStatus = [string]$event.status
        Write-Output ($safe | ConvertTo-Json -Compress)
    }

    $process.WaitForExit()
    if ($lastStructuredStage -eq 'failed' -or
        $lastStructuredStatus -ne 'success') {
        exit 1
    }
    exit $process.ExitCode
}
catch {
    Write-Output '{"stage":"failed","status":"launcher_failed"}'
    exit 1
}
finally {
    if ($process) {
        try {
            if (-not $process.HasExited) {
                $process.Kill()
                $process.WaitForExit()
            }
        }
        catch {
            # Cleanup must not expose process or environment details.
        }
    }
    if ($process) { $process.Dispose() }
    if ($keyPointer -ne [IntPtr]::Zero) {
        [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($keyPointer)
    }
    $plainKey = $null
    $secureKey = $null

    $resolvedRuntimeRoot = [System.IO.Path]::GetFullPath($runtimeRoot).TrimEnd('\') + '\'
    $resolvedRuntimeDirectory = [System.IO.Path]::GetFullPath($runtimeDirectory)
    if ($resolvedRuntimeDirectory.StartsWith(
            $resolvedRuntimeRoot,
            [System.StringComparison]::OrdinalIgnoreCase
        ) -and (Test-Path -LiteralPath $resolvedRuntimeDirectory)) {
        Remove-Item -LiteralPath $resolvedRuntimeDirectory -Recurse -Force
    }
}
