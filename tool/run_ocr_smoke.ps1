[CmdletBinding()]
param(
    [Parameter(Position = 0)]
    [string[]]$Pdf,
    [switch]$UseSavedAppKey,
    [switch]$SkipBuild,
    [ValidateRange(30, 600)]
    [int]$BuildTimeoutSeconds = 180,
    [ValidateRange(60, 1200)]
    [int]$OcrTimeoutSeconds = 600,
    [switch]$WriteReplayCache,
    [string]$CaseId = '',
    [switch]$SavedKeyProbe
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$script:reportReady = $false
$script:reportWriteFailureEmitted = $false
$script:reportDirectory = $null
$script:reportRelativeDirectory = $null
$script:reportRunId = $null
$script:reportTraceId = $null
$script:launcherEvents = @()

function Write-SafeJson {
    param(
        [Parameter(Mandatory = $true)]
        [hashtable]$Value
    )

    Write-Output ($Value | ConvertTo-Json -Compress)
    if ($Value.ContainsKey('status') -and $null -ne $Value.status) {
        $summaryPath = Join-Path $script:reportDirectory 'summary.json'
        if (Test-Path -LiteralPath $summaryPath -PathType Leaf) {
            try {
                $summaryJson = Get-Content -LiteralPath $summaryPath -Raw | ConvertFrom-Json
                $summaryJson.stage = $Value.stage
                $summaryJson.status = $Value.status
                Write-OcrSmokeReportJson -FileName 'summary.json' -Value $summaryJson
            }
            catch {}
        }
    }
    Update-OcrSmokeLauncherReport -Value $Value
}

function Write-ReportFailureStatus {
    param(
        [Parameter(Mandatory = $true)]
        [string]$CauseType
    )

    if ($script:reportWriteFailureEmitted) {
        return
    }
    $script:reportWriteFailureEmitted = $true
    Write-Output (@{
            stage = 'report'
            status = 'report_write_failed'
            causeType = $CauseType
        } | ConvertTo-Json -Compress)
}

function Write-OcrSmokeReportJson {
    param(
        [Parameter(Mandatory = $true)]
        [string]$FileName,
        [Parameter(Mandatory = $true)]
        [object]$Value
    )

    if (-not $script:reportReady) {
        return
    }
    try {
        $path = Join-Path $script:reportDirectory $FileName
        ConvertTo-Json -InputObject $Value -Depth 8 |
            Set-Content -LiteralPath $path -Encoding utf8
    }
    catch {
        $script:reportReady = $false
        Write-ReportFailureStatus -CauseType $_.Exception.GetType().Name
    }
}

function New-OcrSmokeReportContext {
    param(
        [Parameter(Mandatory = $true)]
        [string]$RepositoryRoot
    )

    $timestamp = [DateTime]::UtcNow.ToString('yyyyMMdd-HHmmss')
    $shortId = [Guid]::NewGuid().ToString('N').Substring(0, 8)
    $runId = "ocr-run-$timestamp-$shortId"
    $script:reportDirectory = Join-Path $RepositoryRoot "scratch\ocr_reports\$runId"
    $script:reportRelativeDirectory = "scratch/ocr_reports/$runId"
    $script:reportRunId = $runId
    $script:reportTraceId = "trace-$timestamp-$shortId"
    $script:launcherEvents = @()

    try {
        $null = New-Item -ItemType Directory -Path $script:reportDirectory -Force
        $script:reportReady = $true
        Write-OcrSmokeReportJson -FileName 'summary.json' -Value ([ordered]@{
                schemaVersion = 1
                runId = $script:reportRunId
                traceId = $script:reportTraceId
                stage = 'launcher'
                status = $null
                durationMs = $null
                ocrBlockCount = $null
                questionCandidateCount = $null
                acceptedNumbers = @()
                rejectedCandidateCount = $null
                duplicateNumbers = @()
                missingNumbers = @()
                regionCount = $null
                assembledQuestionCount = $null
                finalQuestionCount = $null
                referenceSectionDetected = $null
                referenceSectionCandidateCount = $null
                questionCandidateTraceTruncated = $null
                markerProbeCount = $null
                markerProbeTraceTruncated = $null
                firstAnomaly = $null
                requiresReview = $null
                blocked = $null
            })
        Write-OcrSmokeReportJson -FileName 'candidate_trace.json' -Value @()
        Write-OcrSmokeReportJson -FileName 'rejected_candidates.json' -Value @()
    }
    catch {
        $script:reportReady = $false
        Write-ReportFailureStatus -CauseType $_.Exception.GetType().Name
    }
}

function Update-OcrSmokeLauncherReport {
    param(
        [Parameter(Mandatory = $true)]
        [hashtable]$Value
    )

    $eventCopy = [ordered]@{}
    foreach ($key in $Value.Keys) {
        $eventCopy[$key] = $Value[$key]
    }
    $script:launcherEvents += $eventCopy
    Write-OcrSmokeReportJson -FileName 'launcher.log' -Value $script:launcherEvents
}

function Get-SmokeSourceFingerprint {
    param(
        [Parameter(Mandatory = $true)]
        [string]$RepositoryRoot
    )

    $sourceFiles = @(
        Get-ChildItem -LiteralPath (Join-Path $RepositoryRoot 'lib') -Recurse -File -Filter '*.dart'
        Get-ChildItem -LiteralPath (Join-Path $RepositoryRoot 'windows') -Recurse -File
        Get-Item -LiteralPath (Join-Path $RepositoryRoot 'tool\ocr_smoke.dart')
        Get-Item -LiteralPath (Join-Path $RepositoryRoot 'tool\ocr_smoke_report.dart')
        Get-Item -LiteralPath (Join-Path $RepositoryRoot 'pubspec.yaml')
        Get-Item -LiteralPath (Join-Path $RepositoryRoot 'pubspec.lock')
    ) | Sort-Object -Property FullName
    $fileHashes = foreach ($file in $sourceFiles) {
        (Get-FileHash -LiteralPath $file.FullName -Algorithm SHA256).Hash
    }
    $bytes = [System.Text.Encoding]::UTF8.GetBytes(($fileHashes -join '|'))
    $sha256 = [System.Security.Cryptography.SHA256]::Create()
    try {
        return ([System.BitConverter]::ToString(
                $sha256.ComputeHash($bytes)
            )).Replace('-', '')
    }
    finally {
        $sha256.Dispose()
    }
}

function Test-SmokeArtifact {
    param(
        [Parameter(Mandatory = $true)]
        [string]$ExecutablePath,
        [Parameter(Mandatory = $true)]
        [string]$AppLibraryPath,
        [Parameter(Mandatory = $true)]
        [string]$ManifestPath,
        [Parameter(Mandatory = $true)]
        [string]$SourceFingerprint
    )

    if (-not (Test-Path -LiteralPath $ExecutablePath -PathType Leaf) -or
        -not (Test-Path -LiteralPath $AppLibraryPath -PathType Leaf) -or
        -not (Test-Path -LiteralPath $ManifestPath -PathType Leaf)) {
        return $false
    }
    try {
        $manifest = Get-Content -LiteralPath $ManifestPath -Raw | ConvertFrom-Json
        if ($manifest.sourceFingerprint -ne $SourceFingerprint) {
            return $false
        }
        $appLibraryHash = (Get-FileHash -LiteralPath $AppLibraryPath -Algorithm SHA256).Hash
        return $manifest.appLibraryHash -eq $appLibraryHash
    }
    catch {
        return $false
    }
}

function Resolve-SmokePdfPath {
    param(
        [Parameter(Mandatory = $true)]
        [string]$PdfArgument,
        [Parameter(Mandatory = $true)]
        [string]$RepositoryRoot,
        [Parameter(Mandatory = $true)]
        [string]$AllowedRoot
    )

    $trimmed = $PdfArgument.Trim()
    if ([string]::IsNullOrWhiteSpace($trimmed)) {
        return @{
            Success = $false
            Status = 'invalid_pdf_argument'
            CauseType = 'InvalidPdfArgument'
        }
    }

    $extension = [System.IO.Path]::GetExtension($trimmed).ToLowerInvariant()
    if ($extension -ne '.pdf') {
        return @{
            Success = $false
            Status = 'invalid_pdf_extension'
            CauseType = 'InvalidPdfExtension'
        }
    }

    try {
        $resolved = if ([System.IO.Path]::IsPathRooted($trimmed)) {
            [System.IO.Path]::GetFullPath($trimmed)
        }
        else {
            [System.IO.Path]::GetFullPath((Join-Path $RepositoryRoot $trimmed))
        }
    }
    catch {
        return @{
            Success = $false
            Status = 'invalid_pdf_argument'
            CauseType = 'InvalidPdfArgument'
        }
    }

    $normalizedAllowed = $AllowedRoot.TrimEnd('\') + '\'
    $normalizedResolved = $resolved
    if (-not $normalizedResolved.StartsWith($normalizedAllowed, [StringComparison]::OrdinalIgnoreCase) -and
        -not ($normalizedResolved -eq $AllowedRoot)) {
        return @{
            Success = $false
            Status = 'path_outside_repository_root'
            CauseType = 'PathOutsideRepositoryRoot'
        }
    }

    if (-not (Test-Path -LiteralPath $resolved -PathType Leaf)) {
        return @{
            Success = $false
            Status = 'pdf_not_found'
            CauseType = 'PdfNotFound'
        }
    }

    return @{
        Success = $true
        Path = $resolved
    }
}

function Join-WindowsCommandLine {
    param(
        [Parameter(Mandatory = $true)]
        [string[]]$Argument
    )

    $escaped = foreach ($arg in $Argument) {
        if ([string]::IsNullOrEmpty($arg)) {
            '""'
        }
        elseif ($arg -match '[\s"]') {
            '"' + ($arg -replace '(\\+)("|$)', '$1$1$2' -replace '"', '\"') + '"'
        }
        else {
            $arg
        }
    }
    return $escaped -join ' '
}

function Stop-OwnedProcessTree {
    param(
        [Parameter(Mandatory = $true)]
        [System.Diagnostics.Process]$OwnedProcess
    )

    try {
        $pidToKill = $OwnedProcess.Id
        $null = & taskkill.exe /F /T /PID $pidToKill 2>&1
    }
    catch {
        # Preserve original failure state if process cleanup fails.
    }
}

function Write-OcrSmokeTerminalSummary {
    param(
        [Parameter(Mandatory = $true)]
        [PSCustomObject]$Report
    )

    Write-Output ("OCR: {0}" -f $(if ($null -ne $Report.status) { $Report.status } elseif ($null -ne $Report.ocrStatus) { $Report.ocrStatus } else { '' }))
    Write-Output ("Trace ID: {0}" -f $(if ($null -ne $Report.traceId) { $Report.traceId } else { $script:reportTraceId }))
    Write-Output ("Duration: {0}" -f $(if ($null -ne $Report.durationMs) { "$($Report.durationMs) ms" } else { '' }))
    Write-Output ("OCR Blocks: {0}" -f $(if ($null -ne $Report.ocrBlockCount) { $Report.ocrBlockCount } else { '' }))
    Write-Output ("Candidates: {0}" -f $(if ($null -ne $Report.questionCandidateCount) { $Report.questionCandidateCount } else { '' }))
    Write-Output ("Accepted Numbers: {0}" -f $(if ($null -ne $Report.acceptedNumbers) { ($Report.acceptedNumbers -join ',') } else { 'unavailable' }))
    Write-Output ("Missing Numbers: {0}" -f $(if ($null -ne $Report.missingNumbers) { if ($Report.missingNumbers.Count -gt 0) { ($Report.missingNumbers -join ',') } else { 'none' } } else { 'unavailable' }))
    Write-Output ("Duplicate Count: {0}" -f $(if ($null -ne $Report.duplicateNumbers) { $Report.duplicateNumbers.Count } else { 'unavailable' }))
    $firstAnomalyStr = 'none'
    if ($null -ne $Report.firstAnomaly) {
        $num = 0
        $reason = [string]$Report.firstAnomaly.reason
        if ([int]::TryParse([string]$Report.firstAnomaly.number, [ref]$num) -and $reason -match '^[a-z_]+$') {
            $firstAnomalyStr = "$num / $reason"
        }
        else {
            $firstAnomalyStr = $Report.firstAnomaly | ConvertTo-Json -Compress
        }
    }
    Write-Output ("First Anomaly: {0}" -f $firstAnomalyStr)
    Write-Output ("Report Directory: {0}" -f $(if ($null -ne $Report.reportDirectory) { $Report.reportDirectory } else { $script:reportRelativeDirectory }))
}

function Invoke-SmokeBuild {
    param(
        [Parameter(Mandatory = $true)]
        [string]$RepositoryRoot,
        [Parameter(Mandatory = $true)]
        [int]$TimeoutSeconds
    )

    $flutterCmd = Get-Command 'flutter' -ErrorAction SilentlyContinue
    if (-not $flutterCmd) {
        return @{
            Success = $false
            Status = 'flutter_tools_unavailable'
        }
    }
    $startInfo = [System.Diagnostics.ProcessStartInfo]::new()
    $startInfo.FileName = $flutterCmd.Source
    $startInfo.WorkingDirectory = $RepositoryRoot
    $startInfo.UseShellExecute = $false
    $startInfo.CreateNoWindow = $true
    $startInfo.RedirectStandardOutput = $true
    $startInfo.RedirectStandardError = $true
    $null = $startInfo.EnvironmentVariables.Remove('SHIROHA_OCR_API_KEY')
    $null = $startInfo.EnvironmentVariables.Remove('SHIROHA_OCR_USE_SAVED_APP_KEY')
    $null = $startInfo.EnvironmentVariables.Remove('SHIROHA_OCR_RUN_ID')
    $null = $startInfo.EnvironmentVariables.Remove('SHIROHA_OCR_BUILD_CACHE_HIT')
    $null = $startInfo.EnvironmentVariables.Remove('SHIROHA_WRITE_REPLAY_CACHE')
    $null = $startInfo.EnvironmentVariables.Remove('SHIROHA_REPLAY_CASE_ID')
    $startInfo.Arguments = 'build windows --release -t tool/ocr_smoke.dart'

    $buildProcess = [System.Diagnostics.Process]::Start($startInfo)
    try {
        $stdoutTask = $buildProcess.StandardOutput.ReadToEndAsync()
        $stderrTask = $buildProcess.StandardError.ReadToEndAsync()
        if (-not $buildProcess.WaitForExit($TimeoutSeconds * 1000)) {
            Stop-OwnedProcessTree -OwnedProcess $buildProcess
            $null = $stdoutTask.Result
            $null = $stderrTask.Result
            return @{
                Success = $false
                Status = 'build_timeout'
            }
        }
        $null = $stdoutTask.Result
        $null = $stderrTask.Result
        return @{
            Success = $buildProcess.ExitCode -eq 0
            Status = $(if ($buildProcess.ExitCode -eq 0) { 'success' } else { 'build_failed' })
        }
    }
    finally {
        $buildProcess.Dispose()
    }
}

$repoRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$allowedRoot = (Resolve-Path -LiteralPath (Join-Path $repoRoot 'scratch\test_pdfs')).ProviderPath
$executablePath = Join-Path $repoRoot 'build\windows\x64\runner\Release\shiroha_quiz.exe'
$appLibraryPath = Join-Path $repoRoot 'build\windows\x64\runner\Release\data\app.so'
$manifestPath = Join-Path $repoRoot 'build\windows\x64\runner\Release\.ocr-smoke-manifest.json'
$secureApiKey = $null
$apiKeyPointer = [IntPtr]::Zero
$apiKey = $null
$startInfo = $null
$process = $null
$buildCacheHit = $null
$useSavedAppKeyInChild = $false

New-OcrSmokeReportContext -RepositoryRoot $repoRoot

try {
    if ($SavedKeyProbe -and $WriteReplayCache) {
        Write-SafeJson @{
            stage = 'launcher'
            status = 'invalid_arguments'
            causeType = 'InvalidArguments'
        }
        exit 2
    }

    if ($WriteReplayCache) {
        if ($null -eq $Pdf -or $Pdf.Count -ne 1) {
            Write-SafeJson @{
                stage = 'launcher'
                status = 'replay_cache_requires_single_pdf'
                causeType = 'InvalidReplayCacheRequest'
            }
            exit 2
        }
        if ([string]::IsNullOrWhiteSpace($CaseId)) {
            Write-SafeJson @{
                stage = 'launcher'
                status = 'replay_case_id_required'
                causeType = 'InvalidReplayCacheRequest'
            }
            exit 2
        }
        if ($CaseId -notmatch '^[A-Za-z0-9_-]+$') {
            Write-SafeJson @{
                stage = 'launcher'
                status = 'invalid_replay_case_id'
                causeType = 'InvalidReplayCaseId'
            }
            exit 2
        }
    }

    $resolvedPdfPaths = @()
    if (-not $SavedKeyProbe) {
        if ($null -eq $Pdf -or $Pdf.Count -lt 1 -or $Pdf.Count -gt 2) {
            Write-SafeJson @{
                stage = 'launcher'
                status = 'invalid_pdf_argument'
                causeType = 'InvalidPdfArgument'
            }
            exit 2
        }

        foreach ($pdfArgument in $Pdf) {
            $resolution = Resolve-SmokePdfPath `
                -PdfArgument $pdfArgument `
                -RepositoryRoot $repoRoot `
                -AllowedRoot $allowedRoot
            if (-not $resolution.Success) {
                Write-SafeJson @{
                    stage = $(if ($resolution.Status -eq 'invalid_pdf_argument') {
                            'launcher'
                        }
                        else {
                            'preflight'
                        })
                    status = $resolution.Status
                    causeType = $resolution.CauseType
                }
                exit 2
            }
            $resolvedPdfPaths += $resolution.Path
        }
    }

    $environmentApiKey = $env:SHIROHA_OCR_API_KEY
    if (-not [string]::IsNullOrWhiteSpace($environmentApiKey)) {
        $apiKey = $environmentApiKey
    }
    elseif ($UseSavedAppKey -or $SavedKeyProbe) {
        $useSavedAppKeyInChild = $true
    }
    else {
        $secureApiKey = Read-Host -Prompt 'SHIROHA_OCR_API_KEY' -AsSecureString
        $apiKeyPointer = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($secureApiKey)
        $apiKey = [Runtime.InteropServices.Marshal]::PtrToStringBSTR($apiKeyPointer)
    }
    if (-not $SavedKeyProbe -and -not $useSavedAppKeyInChild -and [string]::IsNullOrWhiteSpace($apiKey)) {
        Write-SafeJson @{
            stage = 'launcher'
            status = 'missing_api_key'
            causeType = 'MissingApiKey'
        }
        exit 2
    }
    $environmentApiKey = $null

    $sourceFingerprint = Get-SmokeSourceFingerprint -RepositoryRoot $repoRoot
    $artifactReady = Test-SmokeArtifact `
        -ExecutablePath $executablePath `
        -AppLibraryPath $appLibraryPath `
        -ManifestPath $manifestPath `
        -SourceFingerprint $sourceFingerprint
    $buildCacheHit = $artifactReady
    if (-not $artifactReady) {
        if ($SkipBuild) {
            Write-SafeJson @{
                stage = 'launcher'
                status = 'smoke_artifact_unavailable'
                causeType = 'ExecutableNotFound'
            }
            exit 2
        }
        $build = Invoke-SmokeBuild `
            -RepositoryRoot $repoRoot `
            -TimeoutSeconds $BuildTimeoutSeconds
        if (-not $build.Success) {
            Write-SafeJson @{
                stage = 'launcher'
                status = $build.Status
                causeType = 'BuildFailed'
            }
            exit 1
        }
        if (-not (Test-Path -LiteralPath $executablePath -PathType Leaf) -or
            -not (Test-Path -LiteralPath $appLibraryPath -PathType Leaf)) {
            Write-SafeJson @{
                stage = 'launcher'
                status = 'smoke_artifact_unavailable'
                causeType = 'ExecutableNotFound'
            }
            exit 1
        }
        @{
            sourceFingerprint = $sourceFingerprint
            appLibraryHash = (Get-FileHash -LiteralPath $appLibraryPath -Algorithm SHA256).Hash
        } | ConvertTo-Json -Compress | Set-Content -LiteralPath $manifestPath -Encoding utf8
    }

    $startInfo = [System.Diagnostics.ProcessStartInfo]::new()
    $startInfo.FileName = $executablePath
    $startInfo.WorkingDirectory = $repoRoot
    $startInfo.UseShellExecute = $false
    $startInfo.CreateNoWindow = $true
    $startInfo.RedirectStandardOutput = $true
    $startInfo.RedirectStandardError = $true
    $null = $startInfo.EnvironmentVariables.Remove('SHIROHA_OCR_API_KEY')
    $null = $startInfo.EnvironmentVariables.Remove('SHIROHA_OCR_USE_SAVED_APP_KEY')
    $null = $startInfo.EnvironmentVariables.Remove('SHIROHA_SAVED_KEY_PROBE')
    if ($useSavedAppKeyInChild) {
        $startInfo.EnvironmentVariables['SHIROHA_OCR_USE_SAVED_APP_KEY'] = 'true'
    }
    else {
        $startInfo.EnvironmentVariables['SHIROHA_OCR_API_KEY'] = $apiKey
    }
    $startInfo.EnvironmentVariables['SHIROHA_OCR_RUN_ID'] = $script:reportRunId
    $startInfo.EnvironmentVariables['SHIROHA_OCR_BUILD_CACHE_HIT'] =
        $buildCacheHit.ToString().ToLowerInvariant()
    $startInfo.EnvironmentVariables['SHIROHA_REPOSITORY_ROOT'] = $repoRoot

    $toolArguments = @(
        "--repository-root=$repoRoot"
    )
    if ($SavedKeyProbe) {
        $startInfo.EnvironmentVariables['SHIROHA_SAVED_KEY_PROBE'] = 'true'
        $toolArguments += '--saved-key-probe'
    }
    if ($WriteReplayCache) {
        $startInfo.EnvironmentVariables['SHIROHA_WRITE_REPLAY_CACHE'] = 'true'
        $startInfo.EnvironmentVariables['SHIROHA_REPLAY_CASE_ID'] = $CaseId
        $toolArguments += '--write-replay-cache'
        $toolArguments += "--case-id=$CaseId"
    }
    foreach ($resolvedPdfPath in $resolvedPdfPaths) {
        $toolArguments += '--pdf'
        $toolArguments += $resolvedPdfPath
    }
    $startInfo.Arguments = Join-WindowsCommandLine -Argument $toolArguments

    $process = [System.Diagnostics.Process]::Start($startInfo)
    $null = $startInfo.EnvironmentVariables.Remove('SHIROHA_OCR_API_KEY')
    $null = $startInfo.EnvironmentVariables.Remove('SHIROHA_OCR_USE_SAVED_APP_KEY')
    $null = $startInfo.EnvironmentVariables.Remove('SHIROHA_OCR_RUN_ID')
    $null = $startInfo.EnvironmentVariables.Remove('SHIROHA_OCR_BUILD_CACHE_HIT')
    $null = $startInfo.EnvironmentVariables.Remove('SHIROHA_WRITE_REPLAY_CACHE')
    $null = $startInfo.EnvironmentVariables.Remove('SHIROHA_REPLAY_CASE_ID')
    $null = $startInfo.EnvironmentVariables.Remove('SHIROHA_SAVED_KEY_PROBE')
    $null = $startInfo.EnvironmentVariables.Remove('SHIROHA_REPOSITORY_ROOT')
    if ($apiKeyPointer -ne [IntPtr]::Zero) {
        [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($apiKeyPointer)
        $apiKeyPointer = [IntPtr]::Zero
    }
    $apiKey = $null
    if ($null -ne $secureApiKey) {
        $secureApiKey.Dispose()
        $secureApiKey = $null
    }

    $stdoutTask = $process.StandardOutput.ReadToEndAsync()
    $stderrTask = $process.StandardError.ReadToEndAsync()
    if (-not $process.WaitForExit($OcrTimeoutSeconds * 1000)) {
        Stop-OwnedProcessTree -OwnedProcess $process
        $null = $stdoutTask.Result
        $null = $stderrTask.Result
        Write-SafeJson @{
            stage = 'launcher'
            status = 'ocr_timeout'
            causeType = 'TimeoutException'
        }
        exit 1
    }
    $standardOutput = $stdoutTask.Result
    $null = $stderrTask.Result
    $nativeExitCode = $process.ExitCode

    $safeStages = @(
        'launcher',
        'preflight',
        'provider',
        'regionizer',
        'independent_parse',
        'combined_merge',
        'report',
        'completed',
        'failed',
        'replay_cache',
        'credential_probe'
    )
    $lastStructuredStatus = $null
    $reportedSuccess = $false
    $replayCacheWritten = $false

    foreach ($line in ($standardOutput -split "`r?`n")) {
        if ([string]::IsNullOrWhiteSpace($line)) {
            continue
        }
        try {
            $parsed = $line | ConvertFrom-Json -ErrorAction Stop
            if ($null -ne $parsed.stage -and $safeStages -contains [string]$parsed.stage) {
                $lastStructuredStatus = $parsed
                if ($parsed.stage -eq 'replay_cache' -and $parsed.status -eq 'written') {
                    $replayCacheWritten = $true
                }
                if ($parsed.stage -eq 'completed' -and $parsed.status -eq 'success') {
                    $reportedSuccess = $true
                    Write-Output $line
                }
                elseif ($parsed.stage -eq 'report' -and $parsed.status -eq 'success') {
                    Write-OcrSmokeTerminalSummary -Report $parsed
                }
                elseif ($parsed.stage -ne 'independent_parse') {
                    Write-Output $line
                }
            }
        }
        catch {
            # Suppress non-contract output so provider diagnostics cannot leak.
        }
    }

    if ($null -eq $lastStructuredStatus) {
        Write-SafeJson @{
            stage = 'launcher'
            status = 'missing_structured_output'
            causeType = 'MissingStructuredOutput'
        }
        exit $(if ($nativeExitCode -eq 0) { 1 } else { $nativeExitCode })
    }

    if ($WriteReplayCache -and -not $replayCacheWritten) {
        exit 1
    }

    if ($nativeExitCode -eq 0 -and -not $reportedSuccess -and -not $SavedKeyProbe) {
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
        $null = $startInfo.EnvironmentVariables.Remove('SHIROHA_OCR_API_KEY')
        $null = $startInfo.EnvironmentVariables.Remove('SHIROHA_OCR_USE_SAVED_APP_KEY')
        $null = $startInfo.EnvironmentVariables.Remove('SHIROHA_OCR_RUN_ID')
        $null = $startInfo.EnvironmentVariables.Remove('SHIROHA_OCR_BUILD_CACHE_HIT')
        $null = $startInfo.EnvironmentVariables.Remove('SHIROHA_WRITE_REPLAY_CACHE')
        $null = $startInfo.EnvironmentVariables.Remove('SHIROHA_REPLAY_CASE_ID')
        $null = $startInfo.EnvironmentVariables.Remove('SHIROHA_SAVED_KEY_PROBE')
        $null = $startInfo.EnvironmentVariables.Remove('SHIROHA_REPOSITORY_ROOT')
    }
    if ($null -ne $process) {
        try {
            if (-not $process.HasExited) {
                Stop-OwnedProcessTree -OwnedProcess $process
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
}
