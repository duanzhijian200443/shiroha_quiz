[CmdletBinding()]
param()
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
$files = @('external_bootstrap_bytes.dart', 'pairing_transcript_codec.dart',
    'exchange_message_codec.dart', 'discovery_descriptor_codec.dart')
$allowedImports = @('dart:convert', 'dart:typed_data',
    '../../application/external/external_authorization.dart',
    '../../services/backup/sha256.dart', 'external_certificate_der.dart',
    'external_credential_object_codec.dart') + $files
$forbidden = @('dart:io', 'dart:ffi', 'package:ffi', 'native/',
    'Random.secure', 'WindowsExternalCrypto', 'BCrypt', 'DynamicLibrary',
    'PairingProof(', 'AuthenticatedPeerEvidence(', 'ExternalCredentialBoundary',
    'LocalHostDispatchCore', 'ServerSocket', 'SecureSocket', 'SecurityContext',
    'defaultContext', 'onBadCertificate', 'flutter_secure_storage', 'engine.',
    'Process.', 'Directory(', 'File(', 'print(', 'debugPrint(')
foreach ($name in $files) {
    $path = Join-Path $root "lib/data/external/$name"
    $code = [IO.File]::ReadAllText($path)
    foreach ($token in $forbidden) {
        if ($code.Contains($token)) { throw "P22 forbidden source token: $name ($token)" }
    }
    foreach ($import in [regex]::Matches($code, "(?m)^(?:import|export) '([^']+)'")) {
        if ($allowedImports -notcontains $import.Groups[1].Value) {
            throw "P22 unexpected import: $name"
        }
    }
    if ($code -match '(?m)^part\b|^\s*external\s+|@Native\b') {
        throw "P22 hidden execution surface: $name"
    }
}
# New parsing/signature entry points must stay absent from every production
# consumer outside these four files, including startup and Application/P15.
foreach ($file in Get-ChildItem -LiteralPath (Join-Path $root 'lib') -Filter '*.dart' -File -Recurse) {
    if ($file.DirectoryName -eq [IO.Path]::GetFullPath((Join-Path $root 'lib/data/external')) -and $files -contains $file.Name) { continue }
    $code = [IO.File]::ReadAllText($file.FullName)
    if ($code -match 'pairing_transcript_codec|exchange_message_codec|discovery_descriptor_codec|external_bootstrap_bytes') {
        throw 'P22 production composition is active'
    }
}
Write-Output 'PASS: P22 source/import isolation and inactive production composition'
exit 0
