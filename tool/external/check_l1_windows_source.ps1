[CmdletBinding()]
param([switch]$SelfTest)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
$native = Join-Path $root 'windows/external_native'
$sources = @{}
foreach ($path in @('CMakeLists.txt', 'diagnostics/l1_crypto_probe.h',
    'diagnostics/l1_crypto_admission.h', 'diagnostics/l1_windows_admission.h',
    'diagnostics/l1_windows_operations.cpp')) {
    $sources[$path] = [IO.File]::ReadAllText((Join-Path $native $path))
}
function Assert-Isolation([hashtable]$Text) {
    $cmake = $Text['CMakeLists.txt']
    $ops = $Text['diagnostics/l1_windows_operations.cpp']
    if ($cmake -notmatch 'add_library\(shiroha_l1_windows_operations OBJECT diagnostics/l1_windows_operations.cpp\)' -or
        $cmake -match '(?s)add_executable\([^)]*l1_windows_operations' -or
        $cmake -match '(?s)target_link_libraries\([^)]*shiroha_l1_windows_operations' -or
        $cmake -match '(?s)add_test\([^)]*(?:shiroha_l1_windows_operations|shiroha_l1_crypto_candidate)\b') {
        throw 'E3 Windows leaves must remain compile-only and unlinked'
    }
    if ($cmake -notmatch 'add_executable\(shiroha_l1_windows_admission_test tests/l1_windows_admission_test.cpp\)' -or
        $cmake -notmatch 'add_test\(NAME shiroha_l1_windows_admission_offline COMMAND shiroha_l1_windows_admission_test\)') {
        throw 'E3 Fake test registration missing'
    }
    if ($Text['diagnostics/l1_crypto_admission.h'] -notmatch 'kRealExecutionAuthorized = false;' -or
        $Text['diagnostics/l1_crypto_probe.h'] -notmatch 'l1_crypto_execution_not_authorized') {
        throw 'Default rejection missing'
    }
    # Inspect exact backend methods, not comments mentioning STOP.
    foreach ($method in @('trusted_approval', 'inspect')) {
        if ($ops -notmatch "(?s)Win32AdmissionOperations::$method\([^)]*\) noexcept\s*\{(?:(?!\}).)*return false;\s*\}") {
            throw 'Windows trust/process STOP changed'
        }
    }
    if ($ops -notmatch '(?s)Win32AdmissionOperations::start_worker\([^)]*\) noexcept\s*\{(?:(?!\}).)*return WorkerState::kStartFailed;\s*\}') {
        throw 'Windows Worker creation STOP changed'
    }
    if ($ops -match '\b(?:CreateProcess[AW]|ResumeThread|TerminateProcess|CreateJobObject[AW]|CryptProtectData|BCrypt\w+|CertOpenStore)\s*\(' -or
        ($Text.Values -join "`n") -match '\b(?:getenv|GetEnvironmentVariable[AW])\s*\(|--(?:enable-l1|unsafe|run-once)') {
        throw 'Unapproved activation/crypto/process path'
    }
    if ($ops -notmatch 'result.state = GrantState::kUnknown;' -or
        $ops -match '\bresult.confirmed\s*=\s*true') { throw 'Windows leaf cannot claim durable permission' }
}
Assert-Isolation $sources
if ($SelfTest) {
    $cases = @(
        @{ path='CMakeLists.txt'; before='add_library(shiroha_l1_windows_operations OBJECT diagnostics/l1_windows_operations.cpp)'; after='add_executable(shiroha_l1_windows_operations diagnostics/l1_windows_operations.cpp)' },
        @{ path='CMakeLists.txt'; before='COMMAND shiroha_l1_windows_admission_test)'; after='COMMAND shiroha_l1_windows_operations)' },
        @{ path='diagnostics/l1_crypto_admission.h'; before='kRealExecutionAuthorized = false;'; after='kRealExecutionAuthorized = true;' },
        @{ path='diagnostics/l1_windows_operations.cpp'; before='return false;'; after='return true;' },
        @{ path='diagnostics/l1_windows_operations.cpp'; before='result.unknown = true;'; after='result.confirmed = true;' }
    )
    foreach ($case in $cases) {
        $copy = $sources.Clone()
        $copy[$case.path] = $copy[$case.path].Replace($case.before, $case.after)
        $rejected = $false
        try { Assert-Isolation $copy } catch { $rejected = $true }
        if (!$rejected) { throw 'Source guard mutation escaped rejection' }
    }
    Write-Output "PASS: E3 source guard; $($cases.Count) in-memory mutation rejections"
}
Write-Output 'PASS: E3 compile-only Windows leaves, Fake-only registration, unconditional real STOP (STATIC)'
