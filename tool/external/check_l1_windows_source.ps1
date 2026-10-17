[CmdletBinding()]
param([switch]$SelfTest)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
$native = Join-Path $root 'windows/external_native'
$sources = @{}
foreach ($path in @('CMakeLists.txt', 'diagnostics/l1_crypto_probe.h',
    'diagnostics/l1_crypto_admission.h', 'diagnostics/l1_windows_admission.h',
    'diagnostics/l1_windows_operations.cpp', 'diagnostics/l1_e4_admission.h',
    'diagnostics/l1_e4_protocol.h', 'diagnostics/l1_windows_operations.h')) {
    $sources[$path] = [IO.File]::ReadAllText((Join-Path $native $path))
}
function Assert-Isolation([hashtable]$Text) {
    $cmake = $Text['CMakeLists.txt']
    $ops = $Text['diagnostics/l1_windows_operations.cpp']
    if ($cmake -notmatch 'add_library\(shiroha_l1_windows_operations OBJECT diagnostics/l1_windows_operations.cpp\)' -or
        $cmake -match '(?s)add_executable\([^)]*l1_windows_operations' -or
        $cmake -match '(?s)target_link_libraries\([^)]*shiroha_l1_windows_operations|TARGET_OBJECTS:shiroha_l1_windows_operations' -or
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
    # E4 explicitly authorizes dormant suspended-create/resume leaves in this
    # unlinked OBJECT only. The integrated start_worker STOP above is unchanged.
    if ($ops -match '\b(?:TerminateProcess|CreateJobObject[AW]|CryptProtectData|BCrypt\w+|CertOpenStore)\s*\(' -or
        ($Text.Values -join "`n") -match '\b(?:getenv|GetEnvironmentVariable[AW])\s*\(|--(?:enable-l1|unsafe|run-once)') {
        throw 'Unapproved activation/crypto/process path'
    }
    if ($ops -notmatch 'result.state = GrantState::kUnknown;' -or
        $ops -match '\bresult.confirmed\s*=\s*true') { throw 'Windows leaf cannot claim durable permission' }
    if ($ops -notmatch 'CREATE_SUSPENDED\s*\|\s*CREATE_UNICODE_ENVIRONMENT\s*\|\s*CREATE_NO_WINDOW\s*\|\s*EXTENDED_STARTUPINFO_PRESENT' -or
        $ops -notmatch 'PROC_THREAD_ATTRIBUTE_HANDLE_LIST' -or
        $ops -notmatch '!c.token_checked' -or $ops -notmatch '!c.dependencies_checked' -or
        $cmake -notmatch 'add_test\(NAME shiroha_l1_e4_offline COMMAND shiroha_l1_e4_test\)' -or
        $cmake -match '(?s)target_link_libraries\(shiroha_l1_e4_test') { throw 'E4 suspended/Fake isolation missing' }
    $protocol = $Text['diagnostics/l1_e4_protocol.h']
    if ($protocol -notmatch 'sizeof\(Frame\) == 64' -or $protocol -notmatch '0x314c4853u' -or
        $protocol -notmatch 'std::array<uint8_t,\s*768>' -or $protocol -notmatch 'l.handle_limit = handles') {
        throw 'E4 wire/budget contract missing'
    }
}
Assert-Isolation $sources
if ($SelfTest) {
    $cases = @(
        @{ path='CMakeLists.txt'; before='add_library(shiroha_l1_windows_operations OBJECT diagnostics/l1_windows_operations.cpp)'; after='add_executable(shiroha_l1_windows_operations diagnostics/l1_windows_operations.cpp)' },
        @{ path='CMakeLists.txt'; before='COMMAND shiroha_l1_windows_admission_test)'; after='COMMAND shiroha_l1_windows_operations)' },
        @{ path='diagnostics/l1_crypto_admission.h'; before='kRealExecutionAuthorized = false;'; after='kRealExecutionAuthorized = true;' },
        @{ path='diagnostics/l1_windows_operations.cpp'; before='return false;'; after='return true;' },
        @{ path='diagnostics/l1_windows_operations.cpp'; before='result.unknown = true;'; after='result.confirmed = true;' },
        @{ path='diagnostics/l1_windows_operations.cpp'; before='CREATE_SUSPENDED | CREATE_UNICODE_ENVIRONMENT'; after='CREATE_UNICODE_ENVIRONMENT' },
        @{ path='diagnostics/l1_windows_operations.cpp'; before='!c.token_checked'; after='false' },
        @{ path='diagnostics/l1_e4_protocol.h'; before='l.handle_limit = handles'; after='l.handle_limit = 128' }
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
