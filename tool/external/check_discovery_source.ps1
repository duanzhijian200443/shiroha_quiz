[CmdletBinding()]
param()
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
$allowed = @('windows_discovery.dart', 'windows_credential_initialization.dart')
foreach ($file in Get-ChildItem -LiteralPath (Join-Path $root 'lib') -Filter '*.dart' -File -Recurse) {
    if ($file.FullName -eq (Join-Path $root 'lib/composition/mcp_vnext_windows_startup.dart')) { continue }
    $code = [IO.File]::ReadAllText($file.FullName)
    $owned = $file.DirectoryName -eq [IO.Path]::GetFullPath((Join-Path $root 'lib/data/external')) -and $file.Name -in $allowed
    $tlsConsumer = $file.DirectoryName -eq [IO.Path]::GetFullPath((Join-Path $root 'lib/data/external')) -and $file.Name -in @('windows_tls_transport.dart', 'windows_tls_credentials.dart', 'windows_tls_bridge.dart')
    if (!$owned -and !$tlsConsumer -and $code -match 'windows_discovery|WindowsDiscoveryPublisher|WindowsDiscoveryReader') {
        throw 'P26 production composition is active'
    }
    if ($owned) {
        foreach ($token in @('dart:io', 'dart:ffi', 'PairingProof(', 'ExternalPrincipal(', 'Session(',
            'ExternalCredentialBoundary', 'LocalHostDispatchCore', 'ServerSocket', 'SecureSocket',
            'SecurityContext', 'Process.', 'Timer(', 'File(', 'Directory(', 'print(', 'debugPrint(')) {
            if ($code.Contains($token)) { throw 'P26 inactive boundary escaped' }
        }
    }
}
$core = [IO.File]::ReadAllText((Join-Path $root 'windows/external_native/discovery_files.cpp'))
foreach ($token in @('exchange_delete(', 'DeleteFile', 'MoveFileEx', 'FILE_DELETE_ON_CLOSE')) {
    if ($core.Contains($token)) { throw 'P26 unowned cleanup/path fallback' }
}
if (!$core.Contains('L"discovery", true, false') -or !$core.Contains('SHIROHA_NATIVE_COMMIT_UNKNOWN')) {
    throw 'P26 parent/unknown-result guard missing'
}
Write-Output 'PASS: P26 inactive Discovery and fixed Native capability source boundary'
