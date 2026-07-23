[CmdletBinding()]
param(
    [Parameter(Position = 0)]
    [string[]]$Pdf,
    [switch]$UseSavedAppKey,
    [switch]$SkipBuild,
    [ValidateRange(30, 600)]
    [int]$BuildTimeoutSeconds = 180,
    [ValidateRange(60, 1200)]
    [int]$OcrTimeoutSeconds = 600
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

function ConvertTo-WindowsCommandLineArgument {
    param(
        [AllowEmptyString()]
        [string]$Argument
    )

    if ($null -eq $Argument -or $Argument.Length -eq 0) {
        return '""'
    }
    if ($Argument -notmatch '[\s"]') {
        return $Argument
    }

    $builder = [System.Text.StringBuilder]::new()
    $null = $builder.Append('"')
    $backslashCount = 0
    foreach ($character in $Argument.ToCharArray()) {
        if ($character -eq '\') {
            $backslashCount++
            continue
        }
        if ($character -eq '"') {
            $null = $builder.Append(('\' * (($backslashCount * 2) + 1)))
            $null = $builder.Append('"')
            $backslashCount = 0
            continue
        }
        if ($backslashCount -gt 0) {
            $null = $builder.Append(('\' * $backslashCount))
            $backslashCount = 0
        }
        $null = $builder.Append($character)
    }
    if ($backslashCount -gt 0) {
        $null = $builder.Append(('\' * ($backslashCount * 2)))
    }
    $null = $builder.Append('"')
    return $builder.ToString()
}

function Join-WindowsCommandLine {
    param(
        [Parameter(Mandatory = $true)]
        [string[]]$Argument
    )

    return (($Argument | ForEach-Object {
                ConvertTo-WindowsCommandLineArgument -Argument $_
            }) -join ' ')
}

function Stop-OwnedProcessTree {
    param(
        [Parameter(Mandatory = $true)]
        [System.Diagnostics.Process]$OwnedProcess
    )

    if ($OwnedProcess.HasExited) {
        return
    }

    $taskkillPath = Join-Path ([Environment]::GetFolderPath('System')) 'taskkill.exe'
    if (-not (Test-Path -LiteralPath $taskkillPath -PathType Leaf)) {
        throw [System.ComponentModel.Win32Exception]::new('taskkill.exe unavailable.')
    }

    $killStartInfo = [System.Diagnostics.ProcessStartInfo]::new()
    $killStartInfo.FileName = $taskkillPath
    $killStartInfo.UseShellExecute = $false
    $killStartInfo.CreateNoWindow = $true
    $killStartInfo.RedirectStandardOutput = $true
    $killStartInfo.RedirectStandardError = $true
    $killStartInfo.Environment.Remove('SHIROHA_OCR_API_KEY')
    $killStartInfo.Arguments = Join-WindowsCommandLine -Argument @(
        '/PID',
        $OwnedProcess.Id.ToString(),
        '/T',
        '/F'
    )

    $killProcess = [System.Diagnostics.Process]::Start($killStartInfo)
    try {
        $killStdout = $killProcess.StandardOutput.ReadToEndAsync()
        $killStderr = $killProcess.StandardError.ReadToEndAsync()
        if (-not $killProcess.WaitForExit(30000)) {
            $killProcess.Kill()
            $killProcess.WaitForExit()
        }
        $null = $killStdout.Result
        $null = $killStderr.Result
    }
    finally {
        $killProcess.Dispose()
    }
    if (-not $OwnedProcess.WaitForExit(30000)) {
        throw [System.TimeoutException]::new('Owned process tree did not exit.')
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

    if ([string]::IsNullOrWhiteSpace($PdfArgument) -or
        $PdfArgument.Contains('"') -or
        -not $PdfArgument.EndsWith('.pdf', [System.StringComparison]::OrdinalIgnoreCase)) {
        return [pscustomobject]@{
            Success = $false
            Status = 'invalid_pdf_argument'
            CauseType = 'InvalidPdfArgument'
            Path = $null
        }
    }

    $segments = $PdfArgument -split '[\\/]'
    if ($segments -contains '..') {
        return [pscustomobject]@{
            Success = $false
            Status = 'pdf_outside_allowed_root'
            CauseType = 'PdfOutsideAllowedRoot'
            Path = $null
        }
    }

    $isRepositoryRelative =
        $segments.Count -ge 2 -and
        $segments[0].Equals('scratch', [System.StringComparison]::OrdinalIgnoreCase) -and
        $segments[1].Equals('test_pdfs', [System.StringComparison]::OrdinalIgnoreCase)
    if ([System.IO.Path]::IsPathRooted($PdfArgument)) {
        $candidatePath = [System.IO.Path]::GetFullPath($PdfArgument)
    }
    elseif ($isRepositoryRelative) {
        $candidatePath = [System.IO.Path]::GetFullPath((Join-Path $RepositoryRoot $PdfArgument))
    }
    else {
        $candidatePath = [System.IO.Path]::GetFullPath((Join-Path $AllowedRoot $PdfArgument))
    }

    $rootPrefix = $AllowedRoot.TrimEnd([System.IO.Path]::DirectorySeparatorChar) +
        [System.IO.Path]::DirectorySeparatorChar
    if (-not $candidatePath.StartsWith($rootPrefix, [System.StringComparison]::OrdinalIgnoreCase)) {
        return [pscustomobject]@{
            Success = $false
            Status = 'pdf_outside_allowed_root'
            CauseType = 'PdfOutsideAllowedRoot'
            Path = $null
        }
    }
    if (-not (Test-Path -LiteralPath $candidatePath)) {
        return [pscustomobject]@{
            Success = $false
            Status = 'pdf_not_found'
            CauseType = 'FileSystemException'
            Path = $null
        }
    }

    try {
        $resolvedPdfPath = (Resolve-Path -LiteralPath $candidatePath).ProviderPath
        if (-not $resolvedPdfPath.StartsWith($rootPrefix, [System.StringComparison]::OrdinalIgnoreCase)) {
            return [pscustomobject]@{
                Success = $false
                Status = 'pdf_outside_allowed_root'
                CauseType = 'PdfOutsideAllowedRoot'
                Path = $null
            }
        }
        $item = Get-Item -LiteralPath $resolvedPdfPath
        if ($item.PSIsContainer -or $item.Length -le 0) {
            throw [System.IO.IOException]::new('Unreadable PDF fixture.')
        }
        $stream = [System.IO.File]::Open(
            $resolvedPdfPath,
            [System.IO.FileMode]::Open,
            [System.IO.FileAccess]::Read,
            [System.IO.FileShare]::Read
        )
        $stream.Dispose()
        return [pscustomobject]@{
            Success = $true
            Status = 'success'
            CauseType = $null
            Path = $resolvedPdfPath
        }
    }
    catch {
        return [pscustomobject]@{
            Success = $false
            Status = 'file_read_error'
            CauseType = 'FileSystemException'
            Path = $null
        }
    }
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
        $appLibraryHash = (Get-FileHash -LiteralPath $AppLibraryPath -Algorithm SHA256).Hash
        return $manifest.sourceFingerprint -eq $SourceFingerprint -and
            $manifest.appLibraryHash -eq $appLibraryHash
    }
    catch {
        return $false
    }
}

function Invoke-SmokeBuild {
    param(
        [Parameter(Mandatory = $true)]
        [string]$RepositoryRoot,
        [Parameter(Mandatory = $true)]
        [int]$TimeoutSeconds
    )

    $flutterCommand = Get-Command flutter -ErrorAction Stop
    $flutterBin = Split-Path -Parent $flutterCommand.Source
    $flutterRoot = Split-Path -Parent $flutterBin
    $dartExecutable = Join-Path $flutterRoot 'bin\cache\dart-sdk\bin\dart.exe'
    $flutterTools = Join-Path $flutterRoot 'packages\flutter_tools\bin\flutter_tools.dart'
    if (-not (Test-Path -LiteralPath $dartExecutable -PathType Leaf) -or
        -not (Test-Path -LiteralPath $flutterTools -PathType Leaf)) {
        return [pscustomobject]@{ Success = $false; Status = 'build_tool_unavailable' }
    }

    $buildStartInfo = [System.Diagnostics.ProcessStartInfo]::new()
    $buildStartInfo.FileName = $dartExecutable
    $buildStartInfo.WorkingDirectory = $RepositoryRoot
    $buildStartInfo.UseShellExecute = $false
    $buildStartInfo.CreateNoWindow = $true
    $buildStartInfo.RedirectStandardOutput = $true
    $buildStartInfo.RedirectStandardError = $true
    $buildStartInfo.Environment.Remove('SHIROHA_OCR_API_KEY')
    $buildStartInfo.Arguments = Join-WindowsCommandLine -Argument @(
        $flutterTools,
        'build',
        'windows',
        '--release',
        '-t',
        'tool/ocr_smoke.dart'
    )

    $buildProcess = [System.Diagnostics.Process]::Start($buildStartInfo)
    try {
        $stdoutTask = $buildProcess.StandardOutput.ReadToEndAsync()
        $stderrTask = $buildProcess.StandardError.ReadToEndAsync()
        if (-not $buildProcess.WaitForExit($TimeoutSeconds * 1000)) {
            Stop-OwnedProcessTree -OwnedProcess $buildProcess
            $null = $stdoutTask.Result
            $null = $stderrTask.Result
            return [pscustomobject]@{ Success = $false; Status = 'build_timeout' }
        }
        $null = $stdoutTask.Result
        $null = $stderrTask.Result
        return [pscustomobject]@{
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

try {
    if ($null -eq $Pdf -or $Pdf.Count -lt 1 -or $Pdf.Count -gt 2) {
        Write-SafeJson @{
            stage = 'launcher'
            status = 'invalid_pdf_argument'
            causeType = 'InvalidPdfArgument'
        }
        exit 2
    }

    $resolvedPdfPaths = @()
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

    $environmentApiKey = $env:SHIROHA_OCR_API_KEY
    if (-not [string]::IsNullOrWhiteSpace($environmentApiKey)) {
        $apiKey = $environmentApiKey
    }
    elseif ($UseSavedAppKey) {
        Write-SafeJson @{
            stage = 'launcher'
            status = 'saved_api_key_unavailable'
            causeType = 'SavedApiKeyUnavailable'
        }
        exit 2
    }
    else {
        $secureApiKey = Read-Host -Prompt 'SHIROHA_OCR_API_KEY' -AsSecureString
        $apiKeyPointer = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($secureApiKey)
        $apiKey = [Runtime.InteropServices.Marshal]::PtrToStringBSTR($apiKeyPointer)
    }
    if ([string]::IsNullOrWhiteSpace($apiKey)) {
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
    $startInfo.Environment['SHIROHA_OCR_API_KEY'] = $apiKey
    $toolArguments = @()
    foreach ($resolvedPdfPath in $resolvedPdfPaths) {
        $toolArguments += '--pdf'
        $toolArguments += $resolvedPdfPath
    }
    $startInfo.Arguments = Join-WindowsCommandLine -Argument $toolArguments

    $process = [System.Diagnostics.Process]::Start($startInfo)
    $startInfo.Environment.Remove('SHIROHA_OCR_API_KEY')
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
            status = 'missing_structured_output'
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
        $startInfo.Environment.Remove('SHIROHA_OCR_API_KEY')
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
