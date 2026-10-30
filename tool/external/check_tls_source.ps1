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
        if (!$projection.Contains("'schemaVersion': profileVersion == 3 ? 4 : 3") -or
            !$projection.Contains('bridgeStageBlocked => contextKind == VnextMcpContextKind.stage') -or
            !$projection.Contains("decoded['schemaVersion'] != (profileVersion == 3 ? 4 : 3)")) {
            throw 'Bridge explicit v3/v4 selection/response or STAGE classification missing'
        }
    } elseif ($file.FullName -eq (Join-Path $root 'lib/composition/mcp_vnext_windows_acquisition.dart')) {
        foreach ($token in @('dart:io', 'dart:ffi', 'Process.', 'Platform.environment',
            'DatabaseHelper', 'ExternalTrustCore(', 'ExternalSession(', 'ExternalPrincipal(',
            'PairingProof(', 'AuthenticatedPeerEvidence(', '.initialize(', '.recoverServer(',
            'jsonDecode', '.start(', '.bind(', '.connect(', 'createSecurityContext(',
            'print(', 'debugPrint(', 'DiscoveryDescriptorCodec', 'ExchangeMessageCodec')) {
            if ($code.Contains($token)) { throw "Protected acquisition escaped custody boundary: $token" }
        }
        foreach ($required in @('listener: listener ?? const DartLoopbackTlsIo()',
            'createIo: createIo ?? () => const DartLoopbackBridgeIo()',
            'native.peerCertificatePolicy.check', 'WindowsAppPublicPairingHandoff(')) {
            if (!$code.Contains($required)) { throw "Concrete dormant dependency assembly missing: $required" }
        }
    } elseif ($file.FullName -in @((Join-Path $root 'lib/composition/mcp_vnext_windows_bootstrap.dart'),
            (Join-Path $root 'lib/composition/mcp_vnext_windows_registration.dart'))) {
        foreach ($token in @('Platform.environment', 'fromEnvironment', 'jsonDecode',
            'Process.start', 'Process.run', 'Process.kill', 'File(', 'Directory(', 'ExternalTrustCore(', 'ExternalSession(',
            'ExternalPrincipal(', 'PairingProof(', 'AuthenticatedPeerEvidence(',
            'DatabaseHelper', '.initialize(', '.recoverServer(', '.enable(',
            '.approveTarget(', '.acquireBridgeObjects(', '.acquireAppObjects(',
            'DiscoveryDescriptorCodec', 'PairingTranscriptCodec', 'ExchangeMessageCodec',
            'ExternalBootstrapBytes', 'WindowsDiscoveryPublisher', 'publishDiscovery',
            'readDiscovery')) {
            if ($code.Contains($token)) { throw "Trusted registration escaped admission boundary: $token" }
        }
        if (!$code.Contains('await requireSecurityAdmission();')) {
            throw 'Trusted registration missing admission check'
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
    } elseif ($file.FullName -eq (Join-Path $root 'lib/composition/mcp_vnext_development_pairing.dart')) {
        foreach ($token in @('.request(', '.requestStageApproval(', 'IpcEnvelopeCodec',
            'ExternalSession(', 'ExternalTrustCore(', '.initialize(', '.recoverServer(')) {
            if ($code.Contains($token)) { throw "Existing credential proof gained business authority: $token" }
        }
        if (!$code.Contains('await connection.waitForProofClosure()') -or
            !$code.Contains('requirePublication: admitted.packet.requireCurrentPublication')) {
            throw 'Existing credential proof lost publication or no-business boundary'
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
    if ($file.FullName -notin @((Join-Path $root 'lib/composition/mcp_vnext_windows_startup.dart'),
            (Join-Path $root 'lib/composition/mcp_vnext_windows_acquisition.dart'),
            (Join-Path $root 'lib/composition/mcp_vnext_windows_bootstrap.dart'),
            (Join-Path $root 'lib/composition/mcp_vnext_windows_registration.dart'),
            (Join-Path $root 'lib/composition/mcp_vnext_development_app.dart'),
            (Join-Path $root 'lib/composition/mcp_vnext_development_bridge.dart')) -and $code -match "(?:import|export).*mcp_vnext_windows_(?:transport|bridge|startup|acquisition)" ) {
        throw 'Inactive Windows composition acquired a production consumer'
    }
    if ($file.FullName -notin @((Join-Path $root 'lib/data/external/windows_bridge_process.dart'),
            (Join-Path $root 'lib/composition/mcp_vnext_app_owned_relay.dart'),
            (Join-Path $root 'lib/composition/mcp_vnext_windows_startup.dart'),
            (Join-Path $root 'lib/composition/mcp_vnext_windows_acquisition.dart'),
            (Join-Path $root 'lib/composition/mcp_vnext_windows_bootstrap.dart'),
            (Join-Path $root 'lib/composition/mcp_vnext_windows_registration.dart')) -and
        $code -match "(?:import|export).*windows_bridge_process") {
        throw 'Inactive process adapter acquired a production consumer'
    }
}
$process = [IO.File]::ReadAllText((Join-Path $external 'windows_bridge_process.dart'))
foreach ($token in @('killPid', '.kill(', '.pid', 'Platform.environment', 'Process.run',
    'runInShell: true', 'includeParentEnvironment: true', 'Timer(', 'jsonDecode',
    'dart:ffi', 'OpenProcess', 'DatabaseHelper', 'windows_tls_')) {
    if ($process.Contains($token)) { throw "Process adapter escaped original child custody: $token" }
}
foreach ($required in @('WindowsExternalReleaseCandidate.inspect(', 'Platform.resolvedExecutable',
    'Process.start(executable,',
    "pairingUi ? const ['--shiroha-bridge-pairing-ui'] : profileVersion == 3 ? const ['--profile=3'] : const []",
    'WindowsAndroidAdapterLayout.resolve(Platform.resolvedExecutable)',
    'if (android && (layout == null || !layout.paired))',
    "recovery ? '--enable-proof' : '--hosted-business'", 'layout!.recordDirectory',
    "if (!recovery) '--profile=3'", "'--current-user-cng-import'",
    'runInShell: false', 'includeParentEnvironment: false',
    'environment: windowsChildEnvironment()',
    '_process.stdin.close()', '_process.exitCode', '_process.stdout.drain',
    'await for (final bytes in _process.stderr)', 'diagnostics.observeStderr(bytes)',
    '.track(FirstPartyChildPart.stderr, _drainError())')) {
    if (!(($process -replace '\s', '').Contains(($required -replace '\s', '')))) { throw "Fixed child process guard missing: $required" }
}
if ([regex]::Matches($process, '_process\.stderr').Count -ne 1) {
    throw 'Original stderr must have exactly one draining consumer'
}
$environment = [IO.File]::ReadAllText((Join-Path $external 'windows_child_environment.dart'))
foreach ($token in @('Platform.environment', 'fromEnvironment', 'GetEnvironmentVariable',
    'Directory.current', 'Process.', 'windows_external_native', 'File(')) {
    if ($environment.Contains($token)) { throw "Child environment gained external input: $token" }
}
foreach ($required in @("'GetSystemWindowsDirectoryW'", "'SystemRoot': directory",
    "'SHIROHA_PROCESS_ENV_PAD': ''", 'release(heap, 0, memory)')) {
    if (!$environment.Contains($required)) { throw "Child OS environment guard missing: $required" }
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
    'X509_ALTERNATE_NAME', 'X509_OBJECT_IDENTIFIER', 'szOID_ECDSA_SHA256', 'szOID_ECC_CURVE_P256',
    'CRYPT_DECODE_NO_SIGNATURE_BYTE_REVERSAL_FLAG', 'Decoded<LPSTR> curve',
    'oid(*curve.value, szOID_ECC_CURVE_P256)')) {
    if (!$native.Contains($required)) { throw "Native Peer policy missing: $required" }
}
foreach ($forbidden in @('CertOpenStore', 'CertGetCertificateChain', 'CertAddCertificate', 'BCrypt',
    'CreateFile', 'LoadLibrary', 'GetEnvironmentVariable', 'SHGetKnownFolderPath')) {
    if ($native.Contains($forbidden)) { throw 'Peer-only Native ABI gained unrelated access' }
}
Write-Output 'PASS: inactive TLS candidate, explicit Raw I/O, isolated TLS13 contexts and crypt32-only peer policy (WINDOWS_PENDING)'

function Assert-AppOwnedRelayBoundary([hashtable]$Sources) {
    # MCP 17.12 admits this one process consumer, with no protected authority.
    $relay = $Sources.relay
    $imports = @('dart:async', 'dart:io', 'package:path/path.dart',
        '../application/external/first_party_external_access.dart',
        '../application/external/first_party_development_access.dart',
        '../application/external/external_device_connection.dart',
        '../data/external/windows_android_adapter_layout.dart',
        '../data/external/windows_development_bootstrap.dart',
        '../data/external/windows_bridge_process.dart',
        '../data/external/windows_local_relay.dart',
        '../data/external/windows_release_candidate.dart',
        '../mcp/vnext_app_owned_client.dart', '../mcp/vnext_mcp_server.dart')
    foreach ($import in [regex]::Matches($relay, "(?m)^(?:import|export) '([^']+)'")) {
        if ($import.Groups[1].Value -notin $imports) { throw 'Local relay gained an unauthorized dependency' }
    }
    if ($relay -cmatch '\bProcess\s*\.') { throw 'Local relay gained authority: Process' }
    foreach ($token in @('killPid', '.kill(', 'Platform.environment',
        'ExternalTrustCore', 'ExternalSession', 'ExternalPrincipal', 'PairingProof',
        'AuthenticatedPeerEvidence', 'DatabaseHelper', 'LocalHostDispatchCore',
        'WindowsTls', 'P26TlsStartup', 'RawServerSocket', 'ServerSocket',
        'SecurityContext', '.approveTarget(', '.openSession(', '.bindSession(',
        '.acquireAppObjects(', '.acquireBridgeObjects(')) {
        if ($relay.Contains($token)) { throw "Local relay gained authority: $token" }
    }
    foreach ($required in @('WindowsBridgeProcess.stdio(', 'await process.stopAndWait();')) {
        if (!$relay.Contains($required)) { throw 'Local relay lost original process custody' }
    }
    $constructor = [regex]::Match($Sources.registration,
        '(?ms)McpVnextWindowsAppRegistration\.appOwnedRelay\(.*?(?=^  McpVnextWindowsAppRegistration\.directClient)')
    if (!$constructor.Success -or
        !(($constructor.Value -replace '\s', '').Contains('_relay=McpVnextAppOwnedRelay(onEvent:onRelayEvent,requireBusinessBootstrap:true,devices:_devices)')) -or
        !$constructor.Value.Contains('requireBusinessBootstrap: true') -or
        $constructor.Value -match '_install|_startup|_acquirer|requireSecurityAdmission') {
        throw 'Local relay registration gained protected startup'
    }
    foreach ($required in @('store: deviceSelectionStore',
        'endConnection: () => _relay!.endCurrentConnection()',
        'verifyRecovery: _recoverAndroid', 'integration.controls.installDeviceConnection(_devices!)')) {
        if (!(($constructor.Value -replace '\s', '').Contains(($required -replace '\s', '')))) {
            throw 'Local relay lost App-owned device custody'
        }
    }
    if (!$Sources.main.Contains('McpVnextWindowsAppRegistration.appOwnedRelay(integration,') -or
        $Sources.main -match 'McpVnextWindowsAppRegistration\.(directClient|hostedClient)') {
        throw 'Normal App registration activated protected startup'
    }
    if (!$Sources.entry.Contains('await serveDevelopmentWindowsBridge(profileVersion: unified ? 3 : 2);') -or
        !$Sources.entry.Contains("arguments.length == 1 && arguments.single == '--profile=3'") -or
        !(($Sources.entry -replace '\s', '').Contains('if(!unified&&!WindowsExternalReleaseCandidate.acceptsArguments(arguments))')) -or
        $Sources.entry -match 'bootstrap\s*:|Platform.environment|fromEnvironment') {
        throw 'Formal AOT acquired a business selector'
    }
}
$relaySources = @{
    relay = [IO.File]::ReadAllText((Join-Path $root 'lib/composition/mcp_vnext_app_owned_relay.dart'))
    registration = [IO.File]::ReadAllText((Join-Path $root 'lib/composition/mcp_vnext_windows_registration.dart'))
    main = [IO.File]::ReadAllText((Join-Path $root 'lib/main.dart'))
    entry = [IO.File]::ReadAllText((Join-Path $root 'tool/external/bridge_candidate.dart'))
}
Assert-AppOwnedRelayBoundary $relaySources
# In-memory only: no source writes, DLL loading or runtime activation.
$mutations = @(
    @{key='relay'; code=$relaySources.relay + "`nimport '../data/external/windows_tls_host.dart';"; expected='Local relay gained an unauthorized dependency'},
    @{key='relay'; code=$relaySources.relay + "`nExternalTrustCore();"; expected='Local relay gained authority'},
    @{key='relay'; code=$relaySources.relay + "`nProcess.killPid(1);"; expected='Local relay gained authority'},
    @{key='relay'; code=$relaySources.relay + "`nProcess.start('tool', []);"; expected='Local relay gained authority'},
    @{key='relay'; code=$relaySources.relay.Replace('await process.stopAndWait();', ''); expected='Local relay lost original process custody'},
    @{key='registration'; code=$relaySources.registration.Replace('requireBusinessBootstrap: true', 'requireBusinessBootstrap: false'); expected='Local relay registration gained protected startup'},
    @{key='registration'; code=$relaySources.registration.Replace('store: deviceSelectionStore', 'store: alternateStore'); expected='Local relay lost App-owned device custody'},
    @{key='registration'; code=$relaySources.registration.Replace('endConnection: () => _relay!.endCurrentConnection()', 'endConnection: () async {}'); expected='Local relay lost App-owned device custody'},
    @{key='registration'; code=$relaySources.registration.Replace('verifyRecovery: _recoverAndroid', 'verifyRecovery: alternateRecovery'); expected='Local relay lost App-owned device custody'},
    @{key='main'; code=$relaySources.main.Replace('.appOwnedRelay(integration,', '.directClient(integration,'); expected='Normal App registration activated protected startup'},
    @{key='main'; code=$relaySources.main.Replace('.appOwnedRelay(integration,', '.hostedClient(integration,'); expected='Normal App registration activated protected startup'},
    @{key='entry'; code=$relaySources.entry.Replace('serveDevelopmentWindowsBridge(profileVersion: unified ? 3 : 2);', 'serveWindowsBridgeStdio(bootstrap: candidate);'); expected='Formal AOT acquired a business selector'},
    @{key='entry'; code=$relaySources.entry.Replace('arguments.length == 1', 'arguments.isNotEmpty'); expected='Formal AOT acquired a business selector'},
    @{key='entry'; code=$relaySources.entry.Replace('WindowsExternalReleaseCandidate.acceptsArguments(arguments)', 'true'); expected='Formal AOT acquired a business selector'}
)
foreach ($case in $mutations) {
    if ($case.code -ceq $relaySources[$case.key]) { throw 'Local relay source mutation did not apply' }
    $mutated = $relaySources.Clone()
    $mutated[$case.key] = $case.code
    $failure = $null
    try { Assert-AppOwnedRelayBoundary $mutated } catch { $failure = $_.Exception.Message }
    if (!$failure -or !$failure.StartsWith($case.expected)) {
        throw "Local relay source mutation was not rejected: $($case.expected)"
    }
}
Write-Output "PASS: App-owned local relay custody/refusal source mutations ($($mutations.Count) cases)"

# Same narrow recovery constraints as development_source_guard.dart. No runtime I/O.
$recoveryTokens = @{
    'lib/composition/mcp_vnext_development_app.dart' = @(
        'associationRecoveryAvailable:()=>_current&&!relay.hasChild&&relay.observation.phase==FirstPartyRelayPhase.listening')
    'lib/composition/mcp_vnext_windows_startup.dart' = @(
        'this.associationRecoveryAvailable,',
        'associationRecovery:associationRecoveryAvailable==null||!enableWithoutRetainedChannel?null:',
        'dependencies.associations.usesOwner(dependencies.owner)',
        'dependencies.associations.read(reference.profileId)',
        'returnstartup._host!.revoke(reference,expectedRevision);')
}
foreach ($path in $recoveryTokens.Keys) {
    $source = [IO.File]::ReadAllText((Join-Path $root $path)) -replace '\s', ''
    foreach ($token in $recoveryTokens[$path]) {
        if (!$source.Contains($token)) { throw 'Development recovery lost original admission or owner' }
        $mutated = $source.Replace($token, 'removed')
        if (@($recoveryTokens[$path] | Where-Object { !$mutated.Contains($_) }).Count -eq 0) {
            throw 'Development recovery source mutation was not rejected'
        }
    }
}
foreach ($file in Get-ChildItem -LiteralPath (Join-Path $root 'lib') -Filter '*.dart' -File -Recurse) {
    if ($file.FullName -eq (Join-Path $root 'lib/composition/mcp_vnext_development_app.dart')) { continue }
    if ([IO.File]::ReadAllText($file.FullName).Contains('associationRecoveryAvailable:')) {
        throw 'Association recovery installed outside the development root'
    }
}
Write-Output 'PASS: development recovery same-owner/original-Host source mutations (6 cases)'
