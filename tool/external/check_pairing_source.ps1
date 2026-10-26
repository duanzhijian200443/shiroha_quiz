[CmdletBinding()]
param([switch]$SelfTest)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
$hostPath = 'lib/composition/bridge_ui_host.dart'
function Assert-PairingSource([string]$Path, [string]$Code) {
    # This check also applies to the existing dormant composition exceptions.
    # Only the explicit host may name/import itself; no lib consumer is admitted.
    if ($Path -notin @($hostPath, 'lib/composition/mcp_vnext_development_pairing.dart') -and $Code -match 'bridge_ui_host|BridgeUiHost') {
        throw 'Bridge UI host acquired a production consumer'
    }
    if ($Path -in @('lib/composition/mcp_vnext_windows_startup.dart',
        'lib/composition/mcp_vnext_windows_acquisition.dart',
        'lib/composition/mcp_vnext_development_pairing.dart')) { return }
    if ($Path -eq 'lib/data/external/windows_pairing.dart') {
        foreach ($token in @('dart:io', 'dart:ffi', 'PairingProof(', 'AuthenticatedPeerEvidence(',
            'SecurityContext', 'Socket', 'Process.', 'Timer(', 'engine.', 'print(', 'debugPrint(',
            '.cleanup(', '.write(', '.enable(', 'openSession(', 'createProfile(')) {
            if ($code.Contains($token)) { throw "P27 candidate escaped bounded Pairing: $token" }
        }
    } elseif ($Path -eq $hostPath) {
        # MCP section 17.8: one explicitly supplied P27 owner and local window.
        # This is not a blanket composition exemption or native acquisition.
        $allowedImports = @('dart:io', 'package:flutter/widgets.dart',
            'package:path/path.dart',
            '../application/external/first_party_external_credentials.dart',
            '../application/external/first_party_development_access.dart',
            '../data/external/windows_pairing.dart', '../ui/pages/bridge_host_surface.dart')
        foreach ($import in [regex]::Matches($Code, "(?m)^(?:import|export) '([^']+)'")) {
            if ($allowedImports -notcontains $import.Groups[1].Value) {
                throw 'Bridge UI host acquired an unrelated dependency'
            }
        }
        if ($Code -match '(?m)^part\b|^\s*external\s+|@Native\b|WindowsBridgePairing\s*[.(]') {
            throw 'Bridge UI host acquired a hidden or second owner'
        }
        foreach ($token in @('dart:ffi', 'WindowsExternalNative', 'WindowsExternalCrypto',
            'WindowsAppPairing', 'WindowsPairingVerification', 'ExternalTrustCore',
            'ExternalCredentialBoundary', 'ExternalSession', 'ExternalPrincipal',
            'PairingProof(', 'AuthenticatedPeerEvidence(', 'DatabaseHelper',
            'SecurityContext', 'Socket', 'Process.', 'Platform.environment',
            'String.fromEnvironment', '.acquireAppObjects(', '.acquireBridgeObjects(',
            '.initialize(', '.recoverServer(', '.openSession(', '.approveTarget(',
            '.enable(', '.write', '.delete(', 'Directory(', 'print(', 'debugPrint(')) {
            if ($Code.Contains($token)) { throw "Bridge UI host escaped supplied custody: $token" }
        }
    } elseif ($Path -in @('lib/data/external/windows_tls_transport.dart', 'lib/data/external/windows_tls_host.dart')) {
        # Exact inactive Package 3 consumer; its own hard-failing gate rejects
        # production wiring and alternate authorization/persistence.
    } elseif ($code -match 'windows_pairing|WindowsAppPairing|WindowsBridgePairing|WindowsPairingVerification') {
        throw 'P27 production composition is active'
    }
}
$sources = @{}
foreach ($file in Get-ChildItem -LiteralPath (Join-Path $root 'lib') -Filter '*.dart' -File -Recurse) {
    $path = [IO.Path]::GetRelativePath($root, $file.FullName).Replace('\', '/')
    $sources[$path] = [IO.File]::ReadAllText($file.FullName)
    Assert-PairingSource $path $sources[$path]
}
if ($SelfTest) {
    # Mutate in-memory copies only; check helpers never write tracked inputs.
    function Assert-Rejected([string]$Path, [string]$Code, [string]$Expected) {
        $failure = $null
        try { Assert-PairingSource $Path $Code } catch { $failure = $_.Exception.Message }
        if (!$failure -or !$failure.StartsWith($Expected)) {
            throw "P27 source mutation was not rejected: $Path"
        }
    }
    foreach ($path in @('lib/main.dart', 'lib/composition/mcp_vnext_app_integration.dart',
        'lib/mcp/vnext_mcp_composition_root.dart',
        'lib/composition/mcp_vnext_windows_startup.dart',
        'lib/composition/mcp_vnext_windows_acquisition.dart')) {
        Assert-Rejected $path ($sources[$path] + "`nimport 'bridge_ui_host.dart';") `
            'Bridge UI host acquired a production consumer'
    }
    Assert-Rejected 'lib/ui/host_consumer.dart' 'BridgeUiHost.open(dependencies);' `
        'Bridge UI host acquired a production consumer'
    Assert-Rejected 'lib/composition/other_pairing.dart' "import 'windows_pairing.dart';" `
        'P27 production composition is active'
    Assert-Rejected 'lib/data/external/windows_pairing.dart' `
        ($sources['lib/data/external/windows_pairing.dart'] + "`nProcess.start();") `
        'P27 candidate escaped bounded Pairing'
    Assert-Rejected $hostPath ($sources[$hostPath] + "`nimport 'dart:ffi';") `
        'Bridge UI host acquired an unrelated dependency'
    Assert-Rejected $hostPath ($sources[$hostPath] + "`npart 'hidden.dart';") `
        'Bridge UI host acquired a hidden or second owner'
    Assert-Rejected $hostPath ($sources[$hostPath] + "`nWindowsBridgePairing.withPrimitives();") `
        'Bridge UI host acquired a hidden or second owner'
    Assert-Rejected $hostPath ($sources[$hostPath] + "`nnative.acquireBridgeObjects();") `
        'Bridge UI host escaped supplied custody'
    Write-Output 'PASS: P27/Bridge UI host source mutation rejections (12 cases)'
}
Write-Output 'PASS: P27 inactive Pairing, no business/channel authority or alternate persistence'
