[CmdletBinding()]
param()
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
$build = Join-Path $root 'build/p24-native'
$vswhere = Join-Path ${env:ProgramFiles(x86)} 'Microsoft Visual Studio/Installer/vswhere.exe'
$installation = & $vswhere -latest -products '*' -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -property installationPath
if ($LASTEXITCODE -ne 0 -or !$installation) { throw 'MSVC x64 unavailable' }
$cmake = Join-Path $installation 'Common7/IDE/CommonExtensions/Microsoft/CMake/CMake/bin/cmake.exe'
$ctest = Join-Path (Split-Path -Parent $cmake) 'ctest.exe'
$version = (Get-Content (Join-Path $installation 'VC/Auxiliary/Build/Microsoft.VCToolsVersion.default.txt') -Raw).Trim()
$dumpbin = Join-Path $installation "VC/Tools/MSVC/$version/bin/Hostx64/x64/dumpbin.exe"
$diagnosticRoot = Join-Path $build 'p20-compile-only-root'
& $cmake -S $PSScriptRoot -B $build -G 'Visual Studio 17 2022' -A x64 -DSHIROHA_NATIVE_OFFLINE_TESTS=ON -DSHIROHA_BATCH3_EXISTING_ONLY_BUILD=ON -DSHIROHA_P20_MINIMAL_TEST_BUILD=ON "-DSHIROHA_P20_TEST_ROOT=$diagnosticRoot"
if ($LASTEXITCODE -ne 0) { throw 'Exchange configure failed' }
& $cmake --build $build --config Debug --target shiroha_external_native shiroha_batch3_existing_only shiroha_p20_minimal_test shiroha_exchange_offline_test shiroha_objects_offline_test shiroha_discovery_offline_test
if ($LASTEXITCODE -ne 0) { throw 'Exchange compile failed' }
# Compile production only. Inspect the exact ABI before running any Fake.
$dll = Join-Path $build 'Debug/shiroha_external_native.dll'
$exports = (& $dumpbin /exports $dll | Out-String)
if ($LASTEXITCODE -ne 0) { throw 'Exchange export inspection failed' }
$actual = @([regex]::Matches($exports, '(?m)^\s+\d+\s+[0-9A-F]+\s+[0-9A-F]+\s+(\w+)(?:\s+=.*)?\s*$') | ForEach-Object { $_.Groups[1].Value })
$header = [IO.File]::ReadAllText((Join-Path $PSScriptRoot 'shiroha_external_native.h'))
$expected = @([regex]::Matches($header, 'SHIROHA_NATIVE_CALL\s+(shiroha_native_\w+)\(') | ForEach-Object { $_.Groups[1].Value })
if ($actual.Count -ne 26 -or @(Compare-Object $expected $actual).Count) { throw 'Exchange ABI mismatch' }
$existingExports = (& $dumpbin /exports (Join-Path $build 'Debug/shiroha_batch3_existing_only.dll') | Out-String)
if ($LASTEXITCODE -ne 0) { throw 'Existing-only export inspection failed' }
$existingNames = @([regex]::Matches($existingExports, '(?m)^\s+\d+\s+[0-9A-F]+\s+[0-9A-F]+\s+(\w+)(?:\s+=.*)?\s*$') | ForEach-Object { $_.Groups[1].Value })
if ($existingNames.Count -ne 26 -or @(Compare-Object $expected $existingNames).Count) { throw 'Existing-only Exchange ABI mismatch' }
$headers = (& $dumpbin /headers $dll | Out-String)
if ($LASTEXITCODE -ne 0 -or $headers -notmatch '8664 machine \(x64\)') { throw 'Exchange DLL is not x64' }
foreach ($flag in @('Dynamic base', 'NX compatible', 'Control Flow Guard')) {
    if ($headers -notmatch [regex]::Escape($flag)) { throw 'Exchange DLL hardening missing' }
}
$imports = (& $dumpbin /imports $dll | Out-String)
if ($LASTEXITCODE -ne 0) { throw 'Exchange import inspection failed' }
foreach ($symbol in @('CreateMutexExW', 'WaitForSingleObject', 'ReleaseMutex', 'GetSecurityInfo',
    'GetFileInformationByHandleEx', 'SetFileInformationByHandle', 'ReadFile', 'WriteFile', 'FlushFileBuffers')) {
    if ($imports -notmatch "\b$symbol\b") { throw 'Exchange production import missing' }
}
if ($imports -match 'ntoskrnl|MoveFileEx[AW]|DeleteFile[AW]') { throw 'Exchange unsafe file fallback' }
foreach ($name in @('shiroha_discovery_offline_test', 'shiroha_exchange_offline_test', 'shiroha_objects_offline_test')) {
    $imports = (& $dumpbin /imports (Join-Path $build "Debug/$name.exe") | Out-String)
    if ($LASTEXITCODE -ne 0 -or $imports -match 'CryptProtectData|CryptUnprotectData|SHGetKnownFolderPath|NtCreateFile|GetSecurityInfo|GetVolumeInformationByHandleW|CreateFile[AW]|ReadFile|WriteFile|FlushFileBuffers|SetFileInformationByHandle|GetFileInformationByHandleEx|CreateMutexExW|ReleaseMutex|WaitForSingleObject|BCrypt|\bLoadLibrary[AW]\b|shiroha_external_native\.dll') {
        throw 'Exchange Fake executable includes real security operations'
    }
}
# Only the changed Exchange core and affected owner/store regressions execute.
& $ctest --test-dir $build -C Debug -R '^shiroha_(exchange|objects|discovery)_offline$' --output-on-failure
if ($LASTEXITCODE -ne 0) { throw 'Exchange Fake contracts failed' }
Write-Output 'PASS: P24/E0 compile/26 exports/hardening/import isolation and Fake-only regressions; REAL WINDOWS PENDING'
