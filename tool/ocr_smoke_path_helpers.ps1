# Pure path-resolution helpers for the OCR smoke launcher.
#
# This file must stay free of side effects: no environment-secret reads, no
# provider/process/report calls, no main flow, and no output when dot-sourced.
# Compatible with Windows PowerShell 5.1 and PowerShell Core on Windows/Linux.

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
        $normalizedAllowed = [System.IO.Path]::GetFullPath($AllowedRoot).TrimEnd(
            [System.IO.Path]::DirectorySeparatorChar,
            [System.IO.Path]::AltDirectorySeparatorChar
        )
        $resolved = if ([System.IO.Path]::IsPathRooted($trimmed)) {
            [System.IO.Path]::GetFullPath($trimmed)
        }
        elseif ($trimmed -match '^scratch[/\\]') {
            # Repository-relative path: resolve against the repository root.
            [System.IO.Path]::GetFullPath((Join-Path $RepositoryRoot $trimmed))
        }
        else {
            # Plain relative path: resolve against the allowed PDF root.
            [System.IO.Path]::GetFullPath((Join-Path $normalizedAllowed $trimmed))
        }
    }
    catch {
        return @{
            Success = $false
            Status = 'invalid_pdf_argument'
            CauseType = 'InvalidPdfArgument'
        }
    }

    $prefix = $normalizedAllowed + [System.IO.Path]::DirectorySeparatorChar
    if (-not $resolved.StartsWith($prefix, [StringComparison]::OrdinalIgnoreCase) -and
        -not ($resolved -eq $normalizedAllowed)) {
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
