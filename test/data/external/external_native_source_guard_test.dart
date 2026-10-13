import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
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
      for (final forbidden in [
        'CRYPTPROTECT_LOCAL_MACHINE',
        'CredWrite',
        'CredRead',
        'CredDelete',
        'GetEnvironmentVariable',
        'getenv(',
        'CreateDirectory',
        'CreateFile',
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
    ]) {
      expect(header, contains(symbol));
      expect(bindings, contains("'$symbol'"));
    }
    expect(header, contains('SHIROHA_NATIVE_ABI_VERSION 1u'));
    expect(header, contains('SHIROHA_NATIVE_MAX_BYTES 65536u'));
    expect(header, contains('__declspec(dllexport)'));
    expect(header, contains('__cdecl'));
    expect(header, contains('uint64_t* written'));
    expect(bindings, contains('Uint64'));
    expect(bindings, contains('Pointer<Uint64>'));
    expect(bindings, contains('Int32 Function'));
    expect(bindings, contains('Uint32 Function'));
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
        expect(source, isNot(contains('external_native_bindings')),
            reason: file.path);
        expect(source, isNot(contains('shiroha_native_dpapi')),
            reason: file.path);
      }
    }
    final main = File('lib/main.dart').readAsStringSync();
    expect(main, isNot(contains('WindowsExternalNative')));
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
