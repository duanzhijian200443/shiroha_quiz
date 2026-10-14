import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

final _pathOpen = RegExp(r'\bCreateFile(?:A|W)?\s*\(');

void main() {
  test('path-open guard rejects bare and suffixed calls, allows NtCreateFile',
      () {
    for (final code in [
      'CreateFile(',
      'CreateFile (',
      '::CreateFileW(',
      'CreateFileA\n('
    ]) {
      expect(_pathOpen.hasMatch(code), isTrue);
    }
    expect(_pathOpen.hasMatch('NtCreateFile('), isFalse);
    expect(_pathOpen.hasMatch('decltype(&NtCreateFile)'), isFalse);
  });
  test('production Win32 wrapper preserves exact frozen DPAPI parameters', () {
    final source =
        File('windows/external_native/native_windows.cpp').readAsStringSync();
    expect(
        source,
        contains(
            'CryptProtectData(input, nullptr, nullptr, nullptr, nullptr, 0, output)'));
    expect(
        source,
        contains(
            'CryptUnprotectData(input, nullptr, nullptr, nullptr, nullptr, 0, output)'));
    expect(
        source,
        contains(
            'SHGetKnownFolderPath(FOLDERID_LocalAppData, 0, nullptr, path)'));
    expect(source, contains('LocalFree(data)'));
    expect(source, contains('CoTaskMemFree(data)'));
    for (final file in Directory('windows/external_native')
        .listSync()
        .whereType<File>()
        .where((f) => f.path.endsWith('.cpp') || f.path.endsWith('.h'))) {
      final code = file.readAsStringSync();
      expect(_pathOpen.hasMatch(code), isFalse, reason: file.path);
      for (final forbidden in [
        'CRYPTPROTECT_LOCAL_MACHINE',
        'CredWrite',
        'CredRead',
        'CredDelete',
        'GetEnvironmentVariable',
        'getenv(',
        'CreateDirectory',
        'CreateFileW',
        'CreateFileA',
        'BCryptGenerateKeyPair',
        'CertAddCertificate',
        'CreateThread',
        'std::thread',
        'printf(',
        'std::cout',
        'std::cerr',
        'engine.',
        'flutter_secure_storage',
      ]) {
        expect(code, isNot(contains(forbidden)), reason: file.path);
      }
    }
    final core =
        File('windows/external_native/native_core.cpp').readAsStringSync();
    expect(core, contains('SecureZeroMemory(buffer,'));
    expect(core, contains('SecureZeroMemory(blob.pbData, blob.cbData)'));
    expect(core, contains('ops.free_local(blob.pbData)'));
    expect(core, contains('ops.free_task(path)'));
  });

  test(
      'Dart ABI symbol names, fixed-width lengths and limits agree with header',
      () {
    final header = File('windows/external_native/shiroha_external_native.h')
        .readAsStringSync();
    final bindings =
        File('lib/data/external/native/external_native_bindings.dart')
            .readAsStringSync();
    for (final symbol in [
      'shiroha_native_abi_version',
      'shiroha_native_buffer_alloc',
      'shiroha_native_buffer_free',
      'shiroha_native_local_app_data',
      'shiroha_native_dpapi_protect',
      'shiroha_native_dpapi_unprotect',
      'shiroha_native_owner_acquire',
      'shiroha_native_owner_validate',
      'shiroha_native_owner_close',
      'shiroha_native_association_begin',
      'shiroha_native_association_commit',
      'shiroha_native_association_abort',
    ]) {
      expect(header, contains(symbol));
      expect(bindings, contains("'$symbol'"));
    }
    expect(header, contains('SHIROHA_NATIVE_ABI_VERSION 3u'));
    expect(header, contains('SHIROHA_NATIVE_MAX_BYTES 65536u'));
    expect(header, contains('__declspec(dllexport)'));
    expect(header, contains('__cdecl'));
    expect(header, contains('uint64_t* written'));
    expect(bindings, contains('Uint64'));
    expect(bindings, contains('Pointer<Uint64>'));
    expect(bindings, contains('Int32 Function'));
    expect(bindings, contains('Uint32 Function'));
  });

  test('protected children bind parent handles and never reopen caller paths',
      () {
    final source = File('windows/external_native/protected_windows.cpp')
        .readAsStringSync();
    expect(source, contains('attributes.RootDirectory = parent'));
    expect(source, contains('OBJ_CASE_INSENSITIVE | OBJ_DONT_REPARSE'));
    expect(source, contains('GetModuleHandleW(L"ntdll.dll")'));
    expect(source, contains('GetProcAddress(module, "NtCreateFile")'));
    expect(
        source,
        contains(
            'directory_create ? FILE_DIRECTORY_FILE : FILE_OPEN_REPARSE_POINT'));
    expect(
        source, contains('exclusive ? 0 : FILE_SHARE_READ | FILE_SHARE_WRITE'));
    expect(source, contains('SE_DACL_PROTECTED, SE_DACL_PROTECTED'));
    for (final symbol in [
      'GetSecurityInfo',
      'GetVolumeInformationByHandleW',
      'GetFileInformationByHandle',
      'GetFinalPathNameByHandleW',
      'GetDriveTypeW',
      'CloseHandle'
    ]) {
      expect(source, contains(symbol));
    }
    for (final forbidden in [
      'CreateDirectoryW',
      'CreateFileW',
      'SetSecurityInfo',
      'FILE_OVERWRITE',
      'FILE_SUPERSEDE',
      'FILE_DELETE_ON_CLOSE',
      'DeleteFileW',
      'RemoveDirectoryW',
      'MoveFileExW',
    ]) {
      expect(source, isNot(contains(forbidden)));
    }
    // P19 directory/lock opens still deny delete sharing. Only the fixed P20
    // association read permits it for handle-relative atomic replacement.
    expect(
        source,
        contains(
            'file_share != MAXDWORD ? file_share : (exclusive ? 0 : FILE_SHARE_READ | FILE_SHARE_WRITE)'));
    expect(source, contains('GetProcAddress(module, "NtSetInformationFile")'));
    expect(source, contains('rename_association('));
    expect(source, isNot(contains('SetFileInformationByHandle')));
    final rename =
        File('windows/external_native/association_rename.h').readAsStringSync();
    expect(rename, contains('NTSTATUS(NTAPI*)'));
    expect(rename, contains('info.RootDirectory = directory'));
    expect(rename, contains('info.ReplaceIfExists = existing ? TRUE : FALSE'));
    expect(rename, contains('L"associations.bin"'));
    expect(rename, contains('static_cast<FILE_INFORMATION_CLASS>(10)'));
    expect(rename, contains('status == 0 && io.Status == 0'));
    expect(rename, isNot(contains('GetLastError')));
    expect(source, contains('FlushFileBuffers(file)'));
    expect(source, contains('FILE_CREATE, &security.descriptor, result'));
    final core = File('windows/external_native/protected_objects.cpp')
        .readAsStringSync();
    expect(core, contains('i.aces.size() != 1'));
    expect(core, contains('ace.mask == FILE_ALL_ACCESS'));
    expect(core, contains('current.file != pin.identity.file'));
    expect(core, contains('L"runtime.lock" : L"client.lock"'));
    expect(core, isNot(contains('CreateFile')));
    expect(core, isNot(contains('DeleteFile')));
    final header = File('windows/external_native/shiroha_external_native.h')
        .readAsStringSync();
    expect(
        header.replaceAll(RegExp(r'//[^\n]*'), ''), isNot(contains('HANDLE')));
  });

  test('native adapter is absent from startup, MCP and all authority layers',
      () {
    for (final root in [
      'lib/application',
      'lib/domain',
      'lib/mcp',
      'lib/services/agent',
      'lib/ui',
    ]) {
      for (final file
          in Directory(root).listSync(recursive: true).whereType<File>()) {
        if (!file.path.endsWith('.dart')) continue;
        final source = file.readAsStringSync();
        expect(source, isNot(contains('WindowsExternalNative')),
            reason: file.path);
        expect(source, isNot(contains('WindowsCredentialAssociationStore')),
            reason: file.path);
        expect(source, isNot(contains('external_native_bindings')),
            reason: file.path);
        expect(source, isNot(contains('shiroha_native_dpapi')),
            reason: file.path);
      }
    }
    final main = File('lib/main.dart').readAsStringSync();
    expect(main, isNot(contains('WindowsExternalNative')));
    expect(main, isNot(contains('WindowsCredentialAssociationStore')));
    expect(main, isNot(contains('external/native/')));
    for (final root in ['lib/data/external', 'lib/application/external']) {
      for (final file
          in Directory(root).listSync(recursive: true).whereType<File>()) {
        if (!file.path.endsWith('.dart')) continue;
        final source = file.readAsStringSync();
        for (final forbidden in [
          'defaultContext',
          'onBadCertificate',
          'withTrustedRoots: true'
        ]) {
          expect(source, isNot(contains(forbidden)), reason: file.path);
        }
      }
    }
    for (final file
        in Directory('lib/data/external/native').listSync().whereType<File>()) {
      final source = file.readAsStringSync();
      for (final forbidden in [
        'engine.',
        'flutter_secure_storage',
        'ExternalSession',
        'ExternalPrincipal',
        'PairingState',
        'ExternalCredentialAssociationStore',
        'ExternalCredentialPort',
        'ExternalCredentialFailure',
        'external_authorization',
        'writeAs',
        'createSync',
        'Platform.environment',
        'Directory.current',
        'DynamicLibrary.process',
        'DynamicLibrary.executable',
        'package:flutter/',
      ]) {
        expect(source, isNot(contains(forbidden)), reason: file.path);
      }
    }
    final adapter =
        File('lib/data/external/native/windows_external_native.dart')
            .readAsStringSync();
    expect(adapter, contains('Platform.resolvedExecutable'));
    expect(adapter, contains('DynamicLibrary.open(path)'));
    expect(adapter, contains('Uint8List.fromList(output.asTypedList(length))'));
    expect(adapter, contains('finally'));
  });

  test('CMake packages a separate helper without Runner loading or linking',
      () {
    final cmake =
        File('windows/external_native/CMakeLists.txt').readAsStringSync();
    expect(cmake, contains('add_library(shiroha_external_native SHARED'));
    expect(cmake, contains('cxx_std_17'));
    expect(cmake, contains('crypt32 shell32 ole32 uuid'));
    expect(cmake, contains('native_core.cpp tests/native_core_test.cpp'));
    expect(cmake, contains('SHIROHA_NATIVE_OFFLINE_TESTS'));
    expect(
        cmake,
        contains(
            'protected_objects.cpp association_files.cpp tests/protected_objects_test.cpp'));
    final workflow =
        File('.github/workflows/pr-contract-checks.yml').readAsStringSync();
    expect(
        workflow, contains('run: ./windows/external_native/check_offline.ps1'));
    expect(workflow, contains('- windows_native'));
    expect(workflow, contains("needs.windows_native.result"));
    expect(cmake, isNot(contains('flutter')));
    final root = File('windows/CMakeLists.txt').readAsStringSync();
    expect(root, contains('add_subdirectory("external_native")'));
    expect(root, contains('install(TARGETS shiroha_external_native RUNTIME'));
    for (final file
        in Directory('windows/runner').listSync().whereType<File>()) {
      final source = file.readAsStringSync();
      expect(source, isNot(contains('shiroha_external_native')),
          reason: file.path);
      expect(source, isNot(contains('shiroha_native_dpapi')),
          reason: file.path);
    }
  });
}
