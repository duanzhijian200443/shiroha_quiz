[CmdletBinding()]
param()
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
$allowed = @('windows_discovery.dart', 'windows_credential_initialization.dart')
$startupPath = 'lib/composition/mcp_vnext_windows_startup.dart'
$bootstrapPath = 'lib/composition/mcp_vnext_windows_bootstrap.dart'
# The one admitted P26 reference is the original ownership type; the only
# admitted call is the original same-trust advance, never publication.
$bootstrapImport = "import '../data/external/windows_discovery.dart';"
function Assert-DiscoveryConsumer([string]$Path, [string]$Code) {
    # The dormant startup root publishes by design and keeps its own TLS gate.
    if ($Path -eq $startupPath) { return }
    $directory = [IO.Path]::GetDirectoryName($Path).Replace('\', '/')
    $name = [IO.Path]::GetFileName($Path)
    if ($Path -eq $bootstrapPath) {
        if (([regex]::Matches($Code, [regex]::Escape($bootstrapImport))).Count -gt 1) {
            throw 'P26 trusted bootstrap duplicated a Discovery import'
        }
        $body = $Code.Replace($bootstrapImport, '')
        if ($body -match 'windows_discovery|WindowsDiscoveryPublisher|publishDiscovery|readDiscovery') {
            throw 'P26 trusted bootstrap acquired Discovery publication'
        }
        if ([regex]::Matches($body, 'WindowsDiscoveryReader').Count -ne 1 -or
            $body -notmatch 'WindowsDiscoveryReader\((?s:.*?)\)\s*\.\s*readAndAdvanceExistingPin\(') {
            throw 'P26 trusted bootstrap acquired a non-reader Discovery path'
        }
        return
    }
    $owned = $directory -eq 'lib/data/external' -and $name -in $allowed
    $tlsConsumer = $directory -eq 'lib/data/external' -and $name -in @('windows_tls_transport.dart', 'windows_tls_credentials.dart', 'windows_tls_bridge.dart')
    if (!$owned -and !$tlsConsumer -and $Code -match 'windows_discovery|WindowsDiscoveryPublisher|WindowsDiscoveryReader') {
        throw 'P26 production composition is active'
    }
    if ($owned) {
        foreach ($token in @('dart:io', 'dart:ffi', 'PairingProof(', 'ExternalPrincipal(', 'Session(',
            'ExternalCredentialBoundary', 'LocalHostDispatchCore', 'ServerSocket', 'SecureSocket',
            'SecurityContext', 'Process.', 'Timer(', 'File(', 'Directory(', 'print(', 'debugPrint(')) {
            if ($Code.Contains($token)) { throw 'P26 inactive boundary escaped' }
        }
    }
}
$sources = @{}
foreach ($file in Get-ChildItem -LiteralPath (Join-Path $root 'lib') -Filter '*.dart' -File -Recurse) {
    $path = [IO.Path]::GetRelativePath($root, $file.FullName).Replace('\', '/')
    $sources[$path] = [IO.File]::ReadAllText($file.FullName)
    Assert-DiscoveryConsumer $path $sources[$path]
}
# In-memory mutation proof that the privileged Bootstrap root cannot publish or
# bypass the original Reader path without failing this gate.
function Assert-MutationRejected([string]$Path, [string]$Code, [string]$Expected) {
    $failure = $null
    try { Assert-DiscoveryConsumer $Path $Code } catch { $failure = $_.Exception.Message }
    if (!$failure -or !$failure.StartsWith($Expected)) {
        throw "P26 source mutation was not rejected: $Expected"
    }
}
$bootstrapSource = $sources[$bootstrapPath]
foreach ($case in @(
        @{code = "$bootstrapSource`nWindowsDiscoveryPublisher(owner: owner, credentials: credentials);"; expected = 'P26 trusted bootstrap acquired Discovery publication'},
        @{code = "$bootstrapSource`nowner.publishDiscovery(1, bytes);"; expected = 'P26 trusted bootstrap acquired Discovery publication'},
        @{code = "$bootstrapSource`nowner.readDiscovery(1);"; expected = 'P26 trusted bootstrap acquired Discovery publication'},
        @{code = "$bootstrapSource`nfinal reader = WindowsDiscoveryReader(owner);"; expected = 'P26 trusted bootstrap acquired a non-reader Discovery path'},
        @{code = $bootstrapSource.Replace('readAndAdvanceExistingPin(d.trusted)', 'read(d.trusted)'); expected = 'P26 trusted bootstrap acquired a non-reader Discovery path'})) {
    if ($case.code -ceq $bootstrapSource) { throw 'P26 source mutation did not apply' }
    Assert-MutationRejected $bootstrapPath $case.code $case.expected
}
Write-Output 'PASS: P26 trusted Bootstrap source mutation rejections (5 cases)'
$core = [IO.File]::ReadAllText((Join-Path $root 'windows/external_native/discovery_files.cpp'))
foreach ($token in @('exchange_delete(', 'DeleteFile', 'MoveFileEx', 'FILE_DELETE_ON_CLOSE')) {
    if ($core.Contains($token)) { throw 'P26 unowned cleanup/path fallback' }
}
if (!$core.Contains('L"discovery", true, false') -or !$core.Contains('SHIROHA_NATIVE_COMMIT_UNKNOWN')) {
    throw 'P26 parent/unknown-result guard missing'
}
Write-Output 'PASS: P26 inactive Discovery and fixed Native capability source boundary'
