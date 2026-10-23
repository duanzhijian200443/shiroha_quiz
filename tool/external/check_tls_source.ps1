[CmdletBinding()]
param()
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
$owned = @('windows_tls_transport.dart', 'windows_tls_resources.dart', 'windows_tls_credentials.dart',
    'windows_tls_channel.dart', 'windows_tls_host.dart', 'windows_tls_io.dart', 'windows_tls_bridge.dart')
$external = [IO.Path]::GetFullPath((Join-Path $root 'lib/data/external'))
foreach ($file in Get-ChildItem -LiteralPath (Join-Path $root 'lib') -Filter '*.dart' -File -Recurse) {
    $code = [IO.File]::ReadAllText($file.FullName)
    if ($file.DirectoryName -eq $external -and $file.Name -in $owned) {
        foreach ($token in @('defaultContext', 'withTrustedRoots: true', 'onBadCertificate',
            'keyLog:', 'tls1_2', 'allowLegacyUnsafeRenegotiation = true', 'InternetAddress.lookup',
            'InternetAddress.any', 'loopbackIPv6', 'SecureServerSocket.bind', 'shared: true',
            'PairingProof(', 'AuthenticatedPeerEvidence(', 'ExternalTrustCore(',
            'ExternalAuthorizationManagement(', 'DatabaseHelper', 'rawQuery(', 'rawInsert(',
            'Process.', 'File(', 'Directory(', 'print(', 'debugPrint(')) {
            if ($code.Contains($token)) { throw "TLS source escaped frozen boundary: $token" }
        }
        if ($file.Name -ne 'windows_tls_io.dart' -and $code -match 'RawServerSocket\.bind|RawSecureSocket\.(connect|secureServer)') {
            throw 'TLS I/O escaped explicit adapter'
        }
    } elseif ($file.FullName -eq (Join-Path $root 'lib/mcp/vnext_mcp_bridge_port.dart')) {
        foreach ($token in @('.connect(', 'WindowsTlsBridge(', 'ExternalTrustCore', '.openSession(',
            '.bindSession(', '.openRead(', '.openStage(', '.openReconciliation(',
            '.openProposalLifecycle(', '.approveTarget(', 'IpcTrustedContextBinding',
            'ExternalPrincipal', 'ExternalSession(', 'ExternalExecutionContext',
            'AuthenticatedPeerEvidence(', 'PairingProof(', 'DatabaseHelper', 'dart:io', 'dart:ffi')) {
            if ($code.Contains($token)) { throw "Inactive Bridge projection gained authority: $token" }
        }
        if (!$code.Contains('!bridge.enableStageApprovalWait') -or
            !$code.Contains('requestStageApproval(')) { throw 'Default Bridge STAGE refusal or explicit bounded path missing' }
        $projection = [IO.File]::ReadAllText((Join-Path $root 'lib/mcp/vnext_mcp_protocol_projection.dart'))
        if (!$projection.Contains("'schemaVersion': 3") -or
            !$projection.Contains('bridgeStageBlocked => contextKind == VnextMcpContextKind.stage') -or
            !$projection.Contains("decoded['schemaVersion'] != 3")) {
            throw 'Bridge v3 selection/response or STAGE classification missing'
        }
    } elseif ($file.FullName -eq (Join-Path $root 'lib/composition/mcp_vnext_windows_startup.dart')) {
        foreach ($token in @('dart:io', 'dart:ffi', 'Process.', 'Platform.environment',
            'DatabaseHelper', 'ExternalTrustCore(', 'ExternalSession(', 'ExternalPrincipal(',
            'PairingProof(', 'AuthenticatedPeerEvidence(', '.initialize(', '.recoverServer(',
            '.acquireAppObjects(', '.acquireBridgeObjects(', 'DartLoopbackTlsIo',
            'DartLoopbackBridgeIo', 'jsonDecode', 'print(', 'debugPrint(',
            'DiscoveryDescriptorCodec', 'PairingTranscriptCodec',
            'ExchangeMessageCodec', 'ExternalBootstrapBytes',
            'readSubmission', 'readChallenge', 'readProof', 'ExchangeFileRead',
            'ExchangePublication', 'createCaptured', '.consume(', '.release(',
            'AppPairingRequest', 'createChallenge', 'initialDisplay',
            'completionDisplay')) {
            if ($code.Contains($token)) { throw "Dormant startup escaped trusted handoff: $token" }
        }
    } elseif ($file.FullName -in @((Join-Path $root 'lib/composition/mcp_vnext_windows_transport.dart'),
            (Join-Path $root 'lib/composition/mcp_vnext_windows_bridge.dart'))) {
        foreach ($token in @('ExternalTrustCore', 'ExternalSession', 'ExternalPrincipal',
            'DatabaseHelper', 'dart:io', 'dart:ffi', '.approveTarget(', '.openSession(',
            'DartLoopbackTlsIo', 'DartLoopbackBridgeIo', 'P26TlsStartup', 'RawServerSocket')) {
            if ($code.Contains($token)) { throw "Inactive transport composition gained authority: $token" }
        }
    } elseif ($code -match 'windows_tls_|WindowsTlsHost|WindowsChannelVerification|DartLoopbackTlsIo|DartLoopbackBridgeIo|P26TlsStartup') {
        throw 'TLS production wiring is active'
    }
    if ($file.FullName -notin @((Join-Path $root 'lib/mcp/vnext_mcp_bridge_port.dart'),
            (Join-Path $root 'lib/composition/mcp_vnext_windows_bridge.dart')) -and
        $code -match 'vnext_mcp_bridge_port|VnextMcpBridgePort') { throw 'Bridge projection startup consumer is active' }
    if ($file.FullName -ne (Join-Path $root 'lib/composition/mcp_vnext_windows_startup.dart') -and $code -match "(?:import|export).*mcp_vnext_windows_(?:transport|bridge|startup)" ) {
        throw 'Inactive Windows composition acquired a production consumer'
    }
}
$bridgeSource = [IO.File]::ReadAllText((Join-Path $external 'windows_tls_bridge.dart'))
foreach ($required in @('this.enableStageApprovalWait = false', 'if (!enableStageApprovalWait)',
    'FirstPartyStageLimits.bridgeResponse', 'FirstPartyStageLimits.bridgeExchange', 'stagePayload!()')) {
    if (!$bridgeSource.Contains($required)) { throw "Explicit bounded STAGE profile missing: $required" }
}
$config = [IO.File]::ReadAllText((Join-Path $external 'windows_tls_credentials.dart'))
foreach ($required in @('SecurityContext(withTrustedRoots: false)', 'TlsProtocolVersion.tls1_3',
    'allowLegacyUnsafeRenegotiation = false', 'setClientAuthoritiesBytes', 'setTrustedCertificatesBytes')) {
    if (!(($config -replace '\s', '').Contains(($required -replace '\s', '')))) { throw "TLS configuration missing: $required" }
}
$io = [IO.File]::ReadAllText((Join-Path $external 'windows_tls_io.dart'))
foreach ($required in @('RawServerSocket.bind(InternetAddress.loopbackIPv4', 'shared: false',
    "raw.address.address != '127.0.0.1'", 'RawSecureSocket.secureServer',
    'requestClientCertificate: true', 'requireClientCertificate: true',
    'RawSecureSocket.connect(InternetAddress.loopbackIPv4')) {
    if (!(($io -replace '\s', '').Contains(($required -replace '\s', '')))) { throw "TLS I/O guard missing: $required" }
}
$native = [IO.File]::ReadAllText((Join-Path $root 'windows/external_native/peer_policy_windows.cpp'))
foreach ($required in @('CertCreateCertificateContext', 'CryptDecodeObjectEx', 'CertVerifyTimeValidity',
    'CertFreeCertificateContext', 'X509_BASIC_CONSTRAINTS2', 'X509_KEY_USAGE', 'X509_ENHANCED_KEY_USAGE',
    'X509_ALTERNATE_NAME', 'X509_OBJECT_IDENTIFIER', 'szOID_ECDSA_SHA256', 'szOID_ECC_CURVE_P256')) {
    if (!$native.Contains($required)) { throw "Native Peer policy missing: $required" }
}
foreach ($forbidden in @('CertOpenStore', 'CertGetCertificateChain', 'CertAddCertificate', 'BCrypt',
    'CreateFile', 'LoadLibrary', 'GetEnvironmentVariable', 'SHGetKnownFolderPath')) {
    if ($native.Contains($forbidden)) { throw 'Peer-only Native ABI gained unrelated access' }
}
Write-Output 'PASS: inactive TLS candidate, explicit Raw I/O, isolated TLS13 contexts and crypt32-only peer policy (WINDOWS_PENDING)'
