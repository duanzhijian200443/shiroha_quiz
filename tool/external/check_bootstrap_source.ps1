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
# consumer outside these four files. The exact dormant startup/acquisition roots
# are separately token-checked by check_tls_source.ps1; Application/P15 remain
# prohibited. The trusted Bootstrap root gets no composition exemption.
$startupPath = 'lib/composition/mcp_vnext_windows_startup.dart'
$acquisitionPath = 'lib/composition/mcp_vnext_windows_acquisition.dart'
$bootstrapPath = 'lib/composition/mcp_vnext_windows_bootstrap.dart'
$developmentBridgePath = 'lib/composition/mcp_vnext_development_bridge.dart'
# The one admitted P22 reference is the immutable DiscoveryExpectations trust
# input type; no codec class, operation, second codec file or P24 store is.
$bootstrapCodecImport = "import '../data/external/discovery_descriptor_codec.dart';"
$p22Consumers = 'pairing_transcript_codec|exchange_message_codec|discovery_descriptor_codec|external_bootstrap_bytes'
$p22Operations = 'DiscoveryDescriptorCodec|PairingTranscriptCodec|ExchangeMessageCodec|ExternalBootstrapBytes'
function Assert-P22Consumer([string]$Path, [string]$Code) {
    # The pre-existing dormant roots keep their own hard-failing gates.
    if ($Path -in @($startupPath, $acquisitionPath)) { return }
    if ([IO.Path]::GetDirectoryName($Path).Replace('\', '/') -eq 'lib/data/external') {
        $name = [IO.Path]::GetFileName($Path)
        # P22 codecs themselves, plus the exact inactive P24/P26/P27/TLS owners.
        if ($files -contains $name) { return }
        if ($name -eq 'windows_exchange_file_store.dart') { return }
        if ($name -in @('windows_discovery.dart', 'windows_credential_initialization.dart', 'windows_pairing.dart', 'windows_tls_transport.dart', 'windows_tls_credentials.dart', 'windows_tls_channel.dart')) { return }
    }
    if ($Path -in @($bootstrapPath, $developmentBridgePath)) {
        # Trusted Bootstrap: strip exactly one type-only import, then apply the
        # same P22 prohibition as every other production consumer.
        if (([regex]::Matches($Code, [regex]::Escape($bootstrapCodecImport))).Count -gt 1) {
            throw 'P22 trusted bootstrap duplicated a codec import'
        }
        $body = $Code.Replace($bootstrapCodecImport, '')
        if ($body -match $p22Consumers -or $body -match $p22Operations) {
            throw 'P22 trusted bootstrap acquired codec authority'
        }
        return
    }
    if ($Code -match $p22Consumers) {
        throw 'P22 production composition is active'
    }
}
# P24 is the inactive file-I/O consumer of the P22 Exchange codec. The durable
# startup/acquisition roots are separately checked by check_tls_source.ps1.
function Assert-P24Consumer([string]$Path, [string]$Code) {
    if ($Path -in @($startupPath, $acquisitionPath,
        'lib/composition/mcp_vnext_development_pairing.dart',
        'lib/data/external/windows_exchange_file_store.dart',
        'lib/data/external/windows_pairing.dart')) { return }
    if ($Code -match 'windows_exchange_file_store|WindowsExchangeFileStore') {
        throw 'P24 production composition is active'
    }
}
$sources = @{}
foreach ($file in Get-ChildItem -LiteralPath (Join-Path $root 'lib') -Filter '*.dart' -File -Recurse) {
    $path = [IO.Path]::GetRelativePath($root, $file.FullName).Replace('\', '/')
    $sources[$path] = [IO.File]::ReadAllText($file.FullName)
    Assert-P22Consumer $path $sources[$path]
    Assert-P24Consumer $path $sources[$path]
}
# In-memory mutation proof that the narrowed Bootstrap allowance really rejects
# an unauthorized codec reference or P24 store use in that privileged root.
function Assert-MutationRejected([string]$Path, [string]$Code, [string]$Expected) {
    $failure = $null
    try {
        Assert-P22Consumer $Path $Code
        Assert-P24Consumer $Path $Code
    } catch { $failure = $_.Exception.Message }
    if (!$failure -or !$failure.StartsWith($Expected)) {
        throw "P22/P24 source mutation was not rejected: $Expected"
    }
}
$bootstrapSource = $sources[$bootstrapPath]
foreach ($case in @(
        @{path = $bootstrapPath; code = "$bootstrapSource`nimport '../data/external/exchange_message_codec.dart';"; expected = 'P22 trusted bootstrap acquired codec authority'},
        @{path = $bootstrapPath; code = "$bootstrapSource`nfinal descriptor = DiscoveryDescriptorCodec.decode(bytes);"; expected = 'P22 trusted bootstrap acquired codec authority'},
        @{path = $bootstrapPath; code = "$bootstrapSource`nfinal bytes = ExternalBootstrapBytes;"; expected = 'P22 trusted bootstrap acquired codec authority'},
        @{path = $bootstrapPath; code = "$bootstrapSource`nWindowsExchangeFileStore(owner);"; expected = 'P24 production composition is active'},
        @{path = 'lib/main.dart'; code = "import '../data/external/pairing_transcript_codec.dart';"; expected = 'P22 production composition is active'})) {
    if ($case.code -ceq $sources[$case.path]) { throw 'P22/P24 source mutation did not apply' }
    Assert-MutationRejected $case.path $case.code $case.expected
}
Write-Output 'PASS: P22/P24 source mutation rejections (5 cases)'
$exchange = [IO.File]::ReadAllText((Join-Path $root 'lib/data/external/windows_exchange_file_store.dart'))
foreach ($token in @('dart:io', 'dart:ffi', 'PairingProof(', 'AuthenticatedPeerEvidence(',
    'ExternalCredentialBoundary', 'LocalHostDispatchCore', 'ServerSocket', 'Timer(',
    'DiscoveryDescriptorCodec', 'PairingTranscriptCodec', 'print(', 'debugPrint(')) {
    if ($exchange.Contains($token)) { throw 'P24 file adapter escaped its bounded responsibility' }
}
foreach ($file in Get-ChildItem -LiteralPath (Join-Path $root 'lib') -Filter '*.dart' -File -Recurse) {
    if ($file.FullName -in @((Join-Path $root 'lib/composition/mcp_vnext_windows_startup.dart'), (Join-Path $root 'lib/composition/mcp_vnext_windows_acquisition.dart'), (Join-Path $root 'lib/composition/mcp_vnext_windows_bootstrap.dart'), (Join-Path $root 'lib/composition/mcp_vnext_development_pairing.dart'))) { continue }
    if ($file.FullName -eq [IO.Path]::GetFullPath((Join-Path $root 'lib/data/external/windows_exchange_file_store.dart'))) { continue }
    if ($file.FullName -eq [IO.Path]::GetFullPath((Join-Path $root 'lib/data/external/windows_pairing.dart'))) { continue }
    if ([IO.File]::ReadAllText($file.FullName) -match 'windows_exchange_file_store|WindowsExchangeFileStore') {
        throw 'P24 production composition is active'
    }
}
& (Join-Path $PSScriptRoot 'check_discovery_source.ps1')
& (Join-Path $PSScriptRoot 'check_pairing_source.ps1') -SelfTest
& (Join-Path $PSScriptRoot 'check_tls_source.ps1')
Write-Output 'PASS: P22 source/import isolation and inactive production composition'
exit 0
