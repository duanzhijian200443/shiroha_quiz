[CmdletBinding()]
param([ValidateSet('Debug', 'Release')][string]$Configuration = 'Debug')

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
$build = Join-Path $root 'build/p23-native'
$cmakeCommand = Get-Command cmake -ErrorAction SilentlyContinue
$vswhere = Join-Path ${env:ProgramFiles(x86)} 'Microsoft Visual Studio/Installer/vswhere.exe'
$installation = & $vswhere -latest -products '*' -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -property installationPath
if ($LASTEXITCODE -ne 0 -or !$installation) { throw 'MSVC x64 unavailable' }
$cmake = if ($cmakeCommand) { $cmakeCommand.Source } else {
    Join-Path $installation 'Common7/IDE/CommonExtensions/Microsoft/CMake/CMake/bin/cmake.exe'
}
$toolsVersion = (Get-Content (Join-Path $installation 'VC/Auxiliary/Build/Microsoft.VCToolsVersion.default.txt') -Raw).Trim()
$dumpbin = Join-Path $installation "VC/Tools/MSVC/$toolsVersion/bin/Hostx64/x64/dumpbin.exe"
$ctest = Join-Path (Split-Path -Parent $cmake) 'ctest.exe'

# This path is compiled into a diagnostic candidate only; never create/open it.
$p20CompileOnlyRoot = Join-Path $build 'p20-compile-only-root'
& $cmake -S $PSScriptRoot -B $build -G 'Visual Studio 17 2022' -A x64 -DSHIROHA_NATIVE_OFFLINE_TESTS=ON -DSHIROHA_BATCH3_EXISTING_ONLY_BUILD=ON -DSHIROHA_L1_CANDIDATE_BUILD=ON -DSHIROHA_P20_MINIMAL_TEST_BUILD=ON "-DSHIROHA_P20_TEST_ROOT=$p20CompileOnlyRoot"
if ($LASTEXITCODE -ne 0) { throw 'Native configure failed' }
# Incremental Debug linking may retain unused imports from the previous API.
# Rebuild only this tool-managed build tree before inspecting exact artifacts.
& $cmake --build $build --config $Configuration --clean-first
if ($LASTEXITCODE -ne 0) { throw 'Native build failed' }

$dll = Join-Path $build "$Configuration/shiroha_external_native.dll"
$exports = (& $dumpbin /exports $dll | Out-String)
if ($LASTEXITCODE -ne 0) { throw 'DLL export inspection failed' }
$actual = @([regex]::Matches($exports, '(?m)^\s+\d+\s+[0-9A-F]+\s+[0-9A-F]+\s+(\w+)(?:\s+=.*)?\s*$') | ForEach-Object { $_.Groups[1].Value })
$expected = @('shiroha_native_abi_version', 'shiroha_native_buffer_alloc', 'shiroha_native_buffer_free',
    'shiroha_native_local_app_data', 'shiroha_native_dpapi_protect', 'shiroha_native_dpapi_unprotect',
    'shiroha_native_owner_acquire', 'shiroha_native_owner_validate', 'shiroha_native_owner_close',
    'shiroha_native_association_begin', 'shiroha_native_association_commit', 'shiroha_native_association_abort',
    'shiroha_native_ecdsa_generate_key', 'shiroha_native_ecdsa_sign_digest', 'shiroha_native_ecdsa_verify_digest',
    'shiroha_native_credential_begin', 'shiroha_native_credential_commit', 'shiroha_native_credential_abort',
    'shiroha_native_exchange_create', 'shiroha_native_exchange_read', 'shiroha_native_exchange_cleanup')
if ($actual.Count -ne 21 -or @(Compare-Object $expected $actual).Count -ne 0) { throw 'Unexpected DLL ABI exports' }
$headers = (& $dumpbin /headers $dll | Out-String)
if ($LASTEXITCODE -ne 0 -or $headers -notmatch '8664 machine \(x64\)') { throw 'DLL is not x64' }
foreach ($flag in @('Dynamic base', 'NX compatible', 'Control Flow Guard')) {
    if ($headers -notmatch [regex]::Escape($flag)) { throw "Missing DLL hardening: $flag" }
}
$imports = (& $dumpbin /imports $dll | Out-String)
if ($LASTEXITCODE -ne 0) { throw 'DLL import inspection failed' }
foreach ($name in @('CryptProtectData', 'CryptUnprotectData', 'SHGetKnownFolderPath',
    'GetSecurityInfo', 'GetTokenInformation', 'GetVolumeInformationByHandleW', 'CloseHandle', 'GetProcAddress',
    'ReadFile', 'WriteFile', 'FlushFileBuffers', 'GetFileInformationByHandleEx', 'BCryptGenRandom',
    'BCryptOpenAlgorithmProvider', 'BCryptGenerateKeyPair', 'BCryptFinalizeKeyPair', 'BCryptExportKey',
    'BCryptImportKeyPair', 'BCryptSignHash', 'BCryptVerifySignature', 'BCryptDestroyKey',
    'BCryptCloseAlgorithmProvider', 'SetFileInformationByHandle', 'CreateMutexExW', 'WaitForSingleObject', 'ReleaseMutex')) {
    if ($imports -notmatch "\b$name\b") { throw "Missing production system import: $name" }
}
# P20 resolves NtSetInformationFile; P23 uses the documented Win32 relative rename.
# No kernel linkage or path-based publication fallback is allowed.
if ($imports -match 'ntoskrnl|MoveFileEx[AW]') { throw 'Unexpected publication fallback/kernel import' }
$wrapper = Get-Content (Join-Path $PSScriptRoot 'protected_windows.cpp') -Raw
if ($wrapper -notmatch 'GetProcAddress\(module, "NtSetInformationFile"\)') { throw 'Missing user-mode publication entry' }
# Inspect before executing. These executables link only production pure cores +
# fakes. The production DLL is neither loaded nor called by this check helper.
foreach ($name in @('shiroha_native_offline_test', 'shiroha_objects_offline_test', 'shiroha_exchange_offline_test', 'shiroha_probe_offline_test', 'shiroha_rename_layout_test', 'shiroha_crypto_offline_test', 'shiroha_p20_root_production_test', 'shiroha_p20_root_diagnostic_test')) {
    $imports = (& $dumpbin /imports (Join-Path $build "$Configuration/$name.exe") | Out-String)
    # GetProcAddress alone is used by the MSVC CRT even in the layout-only
    # executable. Reject direct loaders/security operations, not CRT machinery.
    if ($LASTEXITCODE -ne 0 -or $imports -match 'CryptProtectData|CryptUnprotectData|SHGetKnownFolderPath|NtCreateFile|NtSetInformationFile|GetSecurityInfo|GetTokenInformation|GetVolumeInformationByHandleW|CreateFile[AW]|CreateDirectory[AW]|ReadFile|WriteFile|FlushFileBuffers|SetFileInformationByHandle|GetFileInformationByHandleEx|BCryptGenRandom|BCryptOpenAlgorithmProvider|BCryptGenerateKeyPair|BCryptFinalizeKeyPair|BCryptExportKey|BCryptImportKeyPair|BCryptSignHash|BCryptVerifySignature|\bLoadLibrary[AW]\b|shiroha_external_native\.dll') {
        throw 'Offline executable includes a real security/file operation'
    }
}
# The real P20 driver is compile-only; inspect registration before execution.
$testList = (& $ctest --test-dir $build -C $Configuration -N | Out-String)
if ($LASTEXITCODE -ne 0 -or $testList -match '\bshiroha_p20_minimal_test\b') { throw 'Real P20 driver registered with CTest' }
if ($testList -notmatch '\bshiroha_p20_root_production_offline\b' -or
    $testList -notmatch '\bshiroha_p20_root_diagnostic_offline\b') { throw 'P20 root Fake coverage missing' }
# Compile metadata reader without loading it or invoking any P/Invoke method.
$csc = Join-Path $env:WINDIR 'Microsoft.NET/Framework64/v4.0.30319/csc.exe'
& $csc /nologo /target:library /platform:x64 /warnaserror "/out:$build/$Configuration/host_a_metadata.dll" (Join-Path $PSScriptRoot 'diagnostics/host_a_metadata.cs') (Join-Path $PSScriptRoot 'diagnostics/metadata_contract.cs')
if ($LASTEXITCODE -ne 0) { throw 'Metadata-reader compile failed' }
# Compile only the shared pure ownership slice; no MetadataReader/P/Invoke exists
# in this fake executable, and no metadata assembly is loaded by the test.
$pinTest = Join-Path $build "$Configuration/host_a_pin_owner_test.exe"
& $csc /nologo /target:exe /platform:x64 /warnaserror /define:SHIROHA_METADATA_FAKE_ONLY "/out:$pinTest" (Join-Path $PSScriptRoot 'diagnostics/host_a_metadata.cs') (Join-Path $PSScriptRoot 'diagnostics/metadata_contract.cs') (Join-Path $PSScriptRoot 'tests/host_a_pin_owner_test.cs')
if ($LASTEXITCODE -ne 0) { throw 'Fake pin-owner compile failed' }
$readerTest = Join-Path $build "$Configuration/host_a_reader_test.exe"
& $csc /nologo /target:exe /platform:x64 /warnaserror /define:SHIROHA_METADATA_FAKE_ONLY "/out:$readerTest" (Join-Path $PSScriptRoot 'diagnostics/host_a_metadata.cs') (Join-Path $PSScriptRoot 'diagnostics/metadata_contract.cs') (Join-Path $PSScriptRoot 'tests/host_a_reader_test.cs')
if ($LASTEXITCODE -ne 0) { throw 'Fake reader compile failed' }
foreach ($name in @('shiroha_batch3_existing_only.dll', 'shiroha_assoc_candidate.exe', 'shiroha_p20_minimal_test.exe')) {
    $file = Join-Path $build "$Configuration/$name"
    $candidateHeaders = (& $dumpbin /headers $file | Out-String)
    if ($LASTEXITCODE -ne 0 -or $candidateHeaders -notmatch '8664 machine \(x64\)') { throw 'Candidate is not x64' }
    foreach ($flag in @('Dynamic base', 'NX compatible', 'Control Flow Guard')) {
        if ($candidateHeaders -notmatch [regex]::Escape($flag)) { throw 'Candidate hardening absent' }
    }
}
$candidateExports = (& $dumpbin /exports (Join-Path $build "$Configuration/shiroha_batch3_existing_only.dll") | Out-String)
if ($LASTEXITCODE -ne 0) { throw 'Existing-only export inspection failed' }
$candidateNames = @([regex]::Matches($candidateExports, '(?m)^\s+\d+\s+[0-9A-F]+\s+[0-9A-F]+\s+(\w+)(?:\s+=.*)?\s*$') | ForEach-Object { $_.Groups[1].Value })
if ($candidateNames.Count -ne 21 -or @(Compare-Object $expected $candidateNames).Count -ne 0) { throw 'Existing-only ABI drift' }
# Assert the three targets remain separate even when both diagnostic options
# are enabled. Configure dependencies are not compiler definitions/includes.
foreach ($target in @('shiroha_external_native', 'shiroha_batch3_existing_only', 'shiroha_p20_minimal_test')) {
    [xml]$project = Get-Content (Join-Path $build "$target.vcxproj") -Raw
    $defines = (@($project.SelectNodes("//*[local-name()='PreprocessorDefinitions']") | ForEach-Object InnerText) -join ';')
    $includes = (@($project.SelectNodes("//*[local-name()='AdditionalIncludeDirectories']") | ForEach-Object InnerText) -join ';')
    $expectedRootOverride = $target -ceq 'shiroha_p20_minimal_test'
    $expectedExistingOnly = $target -ceq 'shiroha_batch3_existing_only'
    if (($defines -match '\bSHIROHA_P20_DIAGNOSTIC_BUILD\b') -ne $expectedRootOverride -or
        ($defines -match '\bSHIROHA_BATCH3_EXISTING_ONLY\b') -ne $expectedExistingOnly -or
        ($includes -match '[\\/]p20(?:;|$)') -ne $expectedRootOverride) { throw 'Diagnostic target configuration isolation failed' }
}
# All build/import/export/hardening/isolation gates above must pass before
# any offline executable runs. Every failure throws under Stop policy.
& $ctest --test-dir $build -C $Configuration --output-on-failure
if ($LASTEXITCODE -ne 0) { throw 'Fake-only native contracts failed' }
& (Join-Path $PSScriptRoot 'tests/runner_stop_test.ps1')
& (Join-Path $PSScriptRoot 'tests/frozen_source_test.ps1')
& (Join-Path $PSScriptRoot 'tests/host_a_policy_test.ps1')
& (Join-Path $PSScriptRoot 'tests/worker_supervision_test.ps1')
& $pinTest
if ($LASTEXITCODE -ne 0) { throw 'Fake pin-owner contracts failed' }
& $readerTest
if ($LASTEXITCODE -ne 0) { throw 'Fake reader contracts failed' }
Write-Output 'PASS: MSVC x64, twenty-one ABI exports, hardening, production imports and fake-only native contracts (no LOCAL-L1 acceptance)'
