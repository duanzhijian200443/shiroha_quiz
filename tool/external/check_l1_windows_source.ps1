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
    'diagnostics/l1_e4_protocol.h', 'diagnostics/l1_windows_operations.h',
    'diagnostics/l1_e5_controller.h', 'diagnostics/l1_e5_windows.h',
    'diagnostics/l1_e5_windows.cpp', 'diagnostics/l1_e5_worker.cpp',
    'diagnostics/l1_b1_unified.h', 'diagnostics/l1_b1_admission_worker.cpp',
    'diagnostics/l1_r1_wiring.h', 'diagnostics/l1_r1_wiring.cpp',
    'diagnostics/l1_r1_controller_entry.cpp', 'diagnostics/l1_r1_worker_entry.cpp',
    'diagnostics/l1_r2_adapters.h', 'diagnostics/l1_r2_adapters.cpp',
    'diagnostics/l1_r2_custodian_entry.cpp', 'diagnostics/l1_r2_windows.h',
    'diagnostics/l1_r2_windows.cpp')) {
    $sources[$path] = [IO.File]::ReadAllText((Join-Path $native $path))
}
function Assert-Isolation([hashtable]$Text) {
    $cmake = $Text['CMakeLists.txt']
    $ops = $Text['diagnostics/l1_windows_operations.cpp']
    if ($cmake -notmatch 'add_library\(shiroha_l1_windows_operations OBJECT diagnostics/l1_windows_operations\.cpp\)' -or
        $cmake -match '(?s)add_executable\([^)]*l1_windows_operations' -or
        $cmake -match '(?s)target_link_libraries\([^)]*shiroha_l1_windows_operations|TARGET_OBJECTS:shiroha_l1_windows_operations' -or
        $cmake -match '(?s)add_test\([^)]*(?:shiroha_l1_windows_operations|shiroha_l1_crypto_candidate)\b') {
        throw 'E3 Windows leaves must remain compile-only and unlinked'
    }
    if ($cmake -notmatch 'add_executable\(shiroha_l1_windows_admission_test tests/l1_windows_admission_test\.cpp\)' -or
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
    $e5 = $Text['diagnostics/l1_e5_windows.cpp']
    if ($cmake -notmatch 'add_library\(shiroha_l1_e5_windows OBJECT diagnostics/l1_e5_windows\.cpp\)' -or
        $cmake -notmatch 'add_library\(shiroha_l1_e5_worker OBJECT diagnostics/l1_e5_worker\.cpp\)' -or
        [regex]::Matches($cmake, 'diagnostics/l1_e5_(?:windows|worker)\.cpp').Count -ne 2 -or
        $cmake -match '(?s)target_link_libraries\([^)]*shiroha_l1_e5_windows|TARGET_OBJECTS:shiroha_l1_e5_windows' -or
        $cmake -match '(?s)target_link_libraries\([^)]*shiroha_l1_e5_worker|TARGET_OBJECTS:shiroha_l1_e5_worker' -or
        $cmake -match '(?s)add_test\([^)]*shiroha_l1_e5_windows\b' -or
        $cmake -match '(?s)add_test\([^)]*shiroha_l1_e5_worker\b' -or
        $cmake -notmatch 'add_test\(NAME shiroha_l1_e5_offline COMMAND shiroha_l1_e5_test\)' -or
        $cmake -match '(?s)target_link_libraries\(shiroha_l1_e5_test' -or
        $e5 -notmatch '(?s)WindowsPlatform::runtime_allowed\(\) const noexcept\s*\{\s*return false;' -or
        ($e5 + $Text['diagnostics/l1_e5_worker.cpp']) -match '\b(?:TerminateProcess|CreateJobObject[AW]|BCrypt\w+|CertOpenStore)\s*\(' -or
        $Text['diagnostics/l1_e5_controller.h'] -notmatch 'display.summary != fresh_display.summary' -or
        $Text['diagnostics/l1_e5_controller.h'] -notmatch 'core_.poll\(reading\(\), true\)') {
        throw 'E5 closed runtime, human binding, original deadline or OBJECT/Fake isolation missing'
    }
    $b1Header = $Text['diagnostics/l1_b1_unified.h']
    $b1Worker = $Text['diagnostics/l1_b1_admission_worker.cpp']
    if ($cmake -notmatch 'add_library\(shiroha_l1_b1_admission_worker OBJECT diagnostics/l1_b1_admission_worker\.cpp\)' -or
        [regex]::Matches($cmake, 'diagnostics/l1_b1_admission_worker\.cpp').Count -ne 1 -or
        $cmake -match '(?s)target_link_libraries\([^)]*shiroha_l1_b1_admission_worker|TARGET_OBJECTS:shiroha_l1_b1_admission_worker' -or
        $cmake -match '(?s)target_compile_definitions\(shiroha_l1_b1_admission_worker[^\)]*SHIROHA_L1_CRYPTO_OBSERVATION' -or
        $cmake -match '(?s)add_test\([^)]*shiroha_l1_b1_admission_worker\b' -or
        $cmake -notmatch 'add_test\(NAME shiroha_l1_b1_unified_offline COMMAND shiroha_l1_b1_unified_test\)' -or
        $cmake -match '(?s)target_link_libraries\(shiroha_l1_b1_unified_test' -or
        $b1Header -notmatch 'kUnifiedRealExecutionAuthorized = false;' -or
        $b1Header -notmatch 'operation_allowed_for_trial' -or
        $b1Header -notmatch 'probe_isolated_root' -or
        $b1Worker -match 'shiroha_native_(?:abi_version|buffer_alloc|buffer_free|ecdsa_\w+|peer_certificate_policy)\s*\(|resolve_l1_crypto_api|run_l1_crypto_sequence|\b(?:TerminateProcess|CreateJobObject[AW]|BCrypt\w+|Cert\w+|Crypt\w+)\s*\(') {
        throw 'B1 unified isolation, zero-crypto Admission-only Worker or Fake registration missing'
    }
    $r1 = $Text['diagnostics/l1_r1_wiring.cpp']
    $r1h = $Text['diagnostics/l1_r1_wiring.h']
    if ($r1h -notmatch 'allow_live_execution\(\) const noexcept\s*\{\s*return false;' -or
        $r1h -notmatch 'Origin origin\(\) const noexcept override\s*\{\s*return Origin::kUnavailable;' -or
        $r1 -notmatch 'e4::launch_once\(steps\)' -or
        $r1 -notmatch 'b1::admission_only_worker_candidate' -or
        [regex]::Matches($r1, 'ports.origin\(\)\s*!=\s*Origin::kFake').Count -ne 2 -or
        $r1 -notmatch 'custody_\.accept_intent\(frozen_\)' -or
        $r1 -notmatch 'acknowledge_identity\(c.process_\)' -or
        $r1 -notmatch 'r.process_identity_sha256\s*==\s*process_\.hash\(\)' -or
        $r1 -notmatch 'kResumeAttempt\)\s*\|\|\s*!timely\(\)' -or
        $r1 -notmatch 'ack.record_sha256\s*!=\s*hash' -or
        $r1 -notmatch 'frozen_\.manifest.max_pumps\s*\+\s*32' -or
        $cmake -notmatch 'add_test\(NAME shiroha_l1_r1_wiring_offline COMMAND shiroha_l1_r1_wiring_test\)' -or
        $cmake -notmatch 'add_executable\(shiroha_l1_r1_\$\{role\}_candidate diagnostics/l1_r1_wiring.cpp\s+diagnostics/l1_r1_\$\{role\}_entry.cpp\)' -or
        $cmake -match '(?s)add_test\([^)]*shiroha_l1_r1_(?:controller|worker)_candidate|target_link_libraries\(shiroha_l1_r1_' -or
        ($r1 + $r1h) -match '\b(?:CreateProcess[AW]|ResumeThread|TerminateProcess|CreateFile[AW]|WriteFile|BCrypt\w+|Crypt\w+|Cert\w+|getenv|GetEnvironmentVariable[AW])\s*\(') {
        throw 'R1 fixed Fake-only wiring/custody/evidence/entry isolation missing'
    }
    foreach ($role in @('controller','worker')) {
        if ($Text["diagnostics/l1_r1_${role}_entry.cpp"] -notmatch 'ClosedWindowsBoundary boundary;' -or
            $Text["diagnostics/l1_r1_${role}_entry.cpp"] -notmatch "${role}_process_entry") {
            throw 'R1 process entry bypasses the concrete closed boundary'
        }
    }
    $r2 = $Text['diagnostics/l1_r2_adapters.cpp']
    $r2h = $Text['diagnostics/l1_r2_adapters.h']
    $r2w = $Text['diagnostics/l1_r2_windows.cpp']
    $r2wh = $Text['diagnostics/l1_r2_windows.h']
    $r2entry = $Text['diagnostics/l1_r2_custodian_entry.cpp']
    if ($r2h -notmatch 'kPolls = 512, kUiEvents = 128, kPins = 64' -or
        $r2h -notmatch 'kArtifactBytes = 16 \* 1024 \* 1024' -or
        $r2h -notmatch 'kReadBlock = 65536, kRecordBytes = 8192' -or
        $r2h -notmatch 'allow_live_execution\(\) noexcept\s*\{\s*return false;\s*\}' -or
        $r2 -notmatch 'if\(!allow_live_execution\(\)\)return 10;' -or
        $r2 -notmatch 'persist\(State::ready\) \|\| !persist\(State::accepted\)' -or
        $r2 -notmatch '!proof\(\) \|\| !persist\(State::attempt\) \|\| !timely\(\)' -or
        $r2 -notmatch 'owner_\.sample_three\(s\)' -or
        $r2entry -notmatch 'custodian_process_entry\(argc, argv\)' -or
        $cmake -notmatch 'add_library\(shiroha_l1_r2_windows OBJECT diagnostics/l1_r2_windows\.cpp\)' -or
        $cmake -notmatch 'add_executable\(shiroha_l1_r2_custodian_candidate diagnostics/l1_r2_adapters\.cpp\s+diagnostics/l1_r1_wiring\.cpp diagnostics/l1_r2_custodian_entry\.cpp\)' -or
        $cmake -notmatch 'add_test\(NAME shiroha_l1_r2_adapters_offline COMMAND shiroha_l1_r2_adapters_test\)' -or
        $cmake -match '(?s)target_link_libraries\([^)]*shiroha_l1_r2_windows|TARGET_OBJECTS:shiroha_l1_r2_windows' -or
        $cmake -match '(?s)add_test\([^)]*(?:shiroha_l1_r2_windows|shiroha_l1_r2_custodian_candidate)\b' -or
        ($r2 + $r2h + $r2entry) -match '\b(?:CreateProcess[AW]|ResumeThread|TerminateProcess|CreateFile[AW]|WriteFile|ReadFile|FlushFileBuffers|BCrypt\w+|Crypt\w+|Cert\w+|getenv|GetEnvironmentVariable[AW])\s*\(' -or
        ($r2w + $r2wh) -match '\b(?:TerminateProcess|CreateJobObject[AW]|BCrypt\w+|Crypt\w+|Cert\w+|getenv|GetEnvironmentVariable[AW])\s*\(') {
        throw 'R2 custodian/adapter/Windows-OBJECT isolation or hard ceiling missing'
    }
    # F1 guards the shared executable comparison AND both pre-custody callers.
    # Reject the original skipped index even if the general hash check survives.
    if ($r2 -notmatch 'l\.custodian_sha256,\s*f\.manifest\.build\.worker' -or
        $r2 -notmatch 'image\.sha256 != expected\[i\]' -or
        ($r2 + $r2w) -match 'i\s*!=\s*1|i\s*==\s*1' -or
        $r2 -notmatch 'f\.manifest\.r2_sha256 != l\.hash\(\)' -or
        $r2 -notmatch 'pin\.object == image\.object && pin\.bytes_sha256 == image\.sha256' -or
        $r2 -notmatch 'pin\.security_sha256 == image\.security_sha256' -or
        $r2 -notmatch '!hex_digest\(image\.security_sha256, 64\)' -or
        $r2w -notmatch 'out\.security_sha256 = p\.image\.artifact_security_sha256' -or
        $r2w -notmatch 'if \(hosts_measurement_attempted_\) return host_images_;' -or
        $r2w -notmatch 'actual_security != images\[i\]\.security_sha256' -or
        $r2wh -notmatch 'hosts_measurement_attempted_=false' -or
        $r2 -notmatch '!match_images\(frozen_, limits_, owner_\.measure_hosts\(\), 2\)' -or
        $r2w -notmatch '!match_images\(frozen_, limits_, images, 3\)' -or
        $r2w -notmatch '!match_images\(frozen_, limits_, images, 2\)' -or
        $r2w -notmatch '!revalidate_hosts_no_read\(images\)' -or
        $r2w -notmatch '!inspect_process_pin\(p, sid\) \|\| !measure_artifact\(p\.image, hash, reads\)' -or
        $r2w -notmatch 'stopped_ = true; // failed identity' -or
        $r2h -notmatch 'measure_hosts\(\) = 0;') {
        throw 'F1 mandatory measured executable/custody binding missing'
    }
}
Assert-Isolation $sources
if ($SelfTest) {
    $cases = @(
        @{ path='diagnostics/l1_r2_adapters.cpp'; before='pin.security_sha256 == image.security_sha256'; after='true' },
        @{ path='diagnostics/l1_r2_adapters.cpp'; before='!hex_digest(image.security_sha256, 64)'; after='false' },
        @{ path='diagnostics/l1_r2_windows.cpp'; before='if (hosts_measurement_attempted_) return host_images_;'; after='if (false) return host_images_;' },
        @{ path='diagnostics/l1_r2_windows.cpp'; before='!revalidate_hosts_no_read(images)'; after='false' },
        @{ path='diagnostics/l1_r2_windows.cpp'; before='actual_security != images[i].security_sha256'; after='false' },
        @{ path='diagnostics/l1_r2_adapters.cpp'; before='image.sha256 != expected[i]'; after='false' },
        @{ path='diagnostics/l1_r2_adapters.cpp'; before='image.sha256 != expected[i]'; after='(i != 1 && image.sha256 != expected[i])' },
        @{ path='diagnostics/l1_r2_adapters.cpp'; before='l.custodian_sha256,'; after='std::string{},' },
        @{ path='diagnostics/l1_r2_adapters.cpp'; before='!match_images(frozen_, limits_, owner_.measure_hosts(), 2)'; after='false' },
        @{ path='diagnostics/l1_r2_windows.cpp'; before='!match_images(frozen_, limits_, images, 2)'; after='false' },
        @{ path='diagnostics/l1_r2_windows.cpp'; before='!match_images(frozen_, limits_, images, 3)'; after='false' },
        @{ path='CMakeLists.txt'; before='add_library(shiroha_l1_windows_operations OBJECT diagnostics/l1_windows_operations.cpp)'; after='add_executable(shiroha_l1_windows_operations diagnostics/l1_windows_operations.cpp)' },
        @{ path='CMakeLists.txt'; before='COMMAND shiroha_l1_windows_admission_test)'; after='COMMAND shiroha_l1_windows_operations)' },
        @{ path='diagnostics/l1_crypto_admission.h'; before='kRealExecutionAuthorized = false;'; after='kRealExecutionAuthorized = true;' },
        @{ path='diagnostics/l1_windows_operations.cpp'; before='return false;'; after='return true;' },
        @{ path='diagnostics/l1_windows_operations.cpp'; before='result.unknown = true;'; after='result.confirmed = true;' },
        @{ path='diagnostics/l1_windows_operations.cpp'; before='CREATE_SUSPENDED | CREATE_UNICODE_ENVIRONMENT'; after='CREATE_UNICODE_ENVIRONMENT' },
        @{ path='diagnostics/l1_windows_operations.cpp'; before='!c.token_checked'; after='false' },
        @{ path='diagnostics/l1_e4_protocol.h'; before='l.handle_limit = handles'; after='l.handle_limit = 128' },
        @{ path='diagnostics/l1_e5_windows.cpp'; before='return false; // Fixed runtime'; after='return true; // Fixed runtime' },
        @{ path='CMakeLists.txt'; before='add_library(shiroha_l1_e5_windows OBJECT'; after='add_library(shiroha_l1_e5_windows SHARED' },
        @{ path='diagnostics/l1_e5_controller.h'; before='display.summary != fresh_display.summary'; after='false' },
        @{ path='diagnostics/l1_e5_controller.h'; before='core_.poll(reading(), true)'; after='true' },
        @{ path='diagnostics/l1_b1_unified.h'; before='kUnifiedRealExecutionAuthorized = false;'; after='kUnifiedRealExecutionAuthorized = true;' },
        @{ path='CMakeLists.txt'; before='add_library(shiroha_l1_b1_admission_worker OBJECT'; after='add_library(shiroha_l1_b1_admission_worker SHARED' },
        @{ path='diagnostics/l1_b1_admission_worker.cpp'; before='admission_only_worker_candidate('; after='run_l1_crypto_sequence(' },
        @{ path='diagnostics/l1_r1_wiring.h'; before='return Origin::kUnavailable;'; after='return Origin::kFake;' },
        @{ path='diagnostics/l1_r1_wiring.h'; before='return false;'; after='return true;' },
        @{ path='diagnostics/l1_r1_wiring.cpp'; before='ports.origin() != Origin::kFake'; after='false' },
        @{ path='diagnostics/l1_r1_wiring.cpp'; before='ack.record_sha256 != hash'; after='false' },
        @{ path='diagnostics/l1_r1_wiring.cpp'; before='e4::launch_once(steps)'; after='steps.create()' },
        @{ path='CMakeLists.txt'; before='COMMAND shiroha_l1_r1_wiring_test)'; after='COMMAND shiroha_l1_r1_worker_candidate)' },
        @{ path='diagnostics/l1_r1_wiring.cpp'; before='r.process_identity_sha256 == process_.hash()'; after='true' },
        @{ path='diagnostics/l1_r1_wiring.cpp'; before='!c.save(Stage::kResumeAttempt) || !timely()'; after='!c.save(Stage::kResumeAttempt)' },
        @{ path='diagnostics/l1_r2_adapters.h'; before='allow_live_execution() noexcept { return false; }'; after='allow_live_execution() noexcept { return true; }' },
        @{ path='diagnostics/l1_r2_adapters.h'; before='kPolls = 512, kUiEvents = 128, kPins = 64'; after='kPolls = 30000, kUiEvents = 128, kPins = 64' },
        @{ path='diagnostics/l1_r2_adapters.cpp'; before='if(!allow_live_execution())return 10;'; after='if(false)return 10;' },
        @{ path='diagnostics/l1_r2_adapters.cpp'; before='!proof() || !persist(State::attempt) || !timely()'; after='!timely()' },
        @{ path='diagnostics/l1_r2_adapters.cpp'; before='owner_.sample_three(s)'; after='true' },
        @{ path='CMakeLists.txt'; before='add_library(shiroha_l1_r2_windows OBJECT diagnostics/l1_r2_windows.cpp)'; after='add_executable(shiroha_l1_r2_windows diagnostics/l1_r2_windows.cpp)' },
        @{ path='CMakeLists.txt'; before='COMMAND shiroha_l1_r2_adapters_test)'; after='COMMAND shiroha_l1_r2_custodian_candidate)' }
    )
    foreach ($case in $cases) {
        $copy = $sources.Clone()
        $copy[$case.path] = $copy[$case.path].Replace($case.before, $case.after)
        if ($copy[$case.path] -ceq $sources[$case.path]) { throw 'Source guard mutation did not apply' }
        $rejected = $false
        try { Assert-Isolation $copy } catch { $rejected = $true }
        if (!$rejected) { throw 'Source guard mutation escaped rejection' }
    }
    Write-Output "PASS: E3/B1/R1 source guard; $($cases.Count) in-memory mutation rejections"
}
Write-Output 'PASS: E3/B1/R1 compile-only Windows leaves, Fake-only registration, unconditional real STOP (STATIC)'
