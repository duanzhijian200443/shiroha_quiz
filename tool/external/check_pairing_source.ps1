[CmdletBinding()]
param()
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
$candidate = [IO.Path]::GetFullPath((Join-Path $root 'lib/data/external/windows_pairing.dart'))
foreach ($file in Get-ChildItem -LiteralPath (Join-Path $root 'lib') -Filter '*.dart' -File -Recurse) {
    $code = [IO.File]::ReadAllText($file.FullName)
    if ($file.FullName -eq $candidate) {
        foreach ($token in @('dart:io', 'dart:ffi', 'PairingProof(', 'AuthenticatedPeerEvidence(',
            'SecurityContext', 'Socket', 'Process.', 'Timer(', 'engine.', 'print(', 'debugPrint(',
            '.cleanup(', '.write(', '.enable(', 'openSession(', 'createProfile(')) {
            if ($code.Contains($token)) { throw "P27 candidate escaped bounded Pairing: $token" }
        }
    } elseif ($file.FullName -in @((Join-Path $root 'lib/data/external/windows_tls_transport.dart'), (Join-Path $root 'lib/data/external/windows_tls_host.dart'))) {
        # Exact inactive Package 3 consumer; its own hard-failing gate rejects
        # production wiring and alternate authorization/persistence.
    } elseif ($code -match 'windows_pairing|WindowsAppPairing|WindowsBridgePairing|WindowsPairingVerification') {
        throw 'P27 production composition is active'
    }
}
Write-Output 'PASS: P27 inactive Pairing, no business/channel authority or alternate persistence'
