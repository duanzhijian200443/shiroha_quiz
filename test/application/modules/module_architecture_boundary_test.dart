import 'dart:convert';
import 'dart:io';
import 'package:shiroha_quiz/services/backup/sha256.dart';
import 'package:flutter_test/flutter_test.dart';
import 'b0_device_settlement_baseline.dart';
import 'r5a_storage_baseline.dart';
import 'p7_capability_baseline.dart';
import 'r7_runtime_baseline.dart';

void main() {
  test(
      'AR-R3 lifecycle, Provider, receipts, storage and MCP wire retain hashes through exact R7 and B0 amendments',
      () {
    final entries = jsonDecode(
        File('test/application/modules/fixtures/retained_source_contracts.json')
            .readAsStringSync()) as List;
    for (final entry in entries) {
      final path = entry['path'] as String;
      var source = File(path).readAsStringSync().replaceAll('\r\n', '\n');
      source = retainedB0DeviceSettlementSource(path, source);
      source = retainedR6RuntimeSource(path, source);
      source = retainedR4StorageSource(path, source);
      source = retainedR2CapabilitySource(path, source);
      final anchor = entry['anchor'] as String?;
      if (anchor != null) {
        expect(source, contains(anchor), reason: path);
        source = source.substring(source.indexOf(anchor));
      }
      final hash = StreamingSha256()..update(utf8.encode(source));
      expect(hash.digestHex(), entry['sha256'], reason: path);
    }
  });
  group('B0 owner settlement amendment', () {
    const path = 'lib/services/backup/backup_restore_runtime.dart';
    const call = '    await _database.settleProductionOwners();\n';
    late String source;
    setUp(() {
      source = File(path).readAsStringSync().replaceAll('\r\n', '\n');
      expect(source.split(call).length - 1, 1);
    });

    for (final entry in <String, String>{
      'missing': '',
      'changed': '    await _database.closeProduction();\n',
      'unawaited': '    _database.settleProductionOwners();\n',
      'duplicated': '$call$call',
    }.entries) {
      test('rejects ${entry.key} settlement', () {
        expect(
            () => retainedB0DeviceSettlementSource(
                path, source.replaceFirst(call, entry.value)),
            throwsA(isA<TestFailure>()));
      });
    }

    for (final entry in <String, String>{
      'before preflight': '    await BackupFreeSpacePolicy.ensureAvailable(\n',
      'after snapshot':
          '    await _database.validateRollbackDatabaseFile(rollbackDbFile);\n',
    }.entries) {
      test('rejects settlement moved ${entry.key}', () {
        final withoutCall = source.replaceFirst(call, '');
        final method =
            withoutCall.indexOf('  Future<void> _copyLiveToRollback(');
        expect(method, greaterThanOrEqualTo(0));
        final position = withoutCall.indexOf(entry.value, method);
        expect(position, greaterThan(method));
        final moved = withoutCall.replaceRange(position, position, call);
        expect(() => retainedB0DeviceSettlementSource(path, moved),
            throwsA(isA<TestFailure>()));
      });
    }

    test('retains the original hash for unrelated rollback code', () {
      const original = '    await _database.closeProduction();';
      expect(source, contains(original));
      final changed = source.replaceFirst(
          original, '    await _database.reopenProduction();');
      final projected = retainedB0DeviceSettlementSource(path, changed);
      final entries = jsonDecode(File(
              'test/application/modules/fixtures/retained_source_contracts.json')
          .readAsStringSync()) as List;
      final expected = entries.singleWhere((entry) => entry['path'] == path);
      final hash = StreamingSha256()..update(utf8.encode(projected));
      expect(hash.digestHex(), isNot(expected['sha256']));
    });
  });
  test('P7 exact amendment projection rejects changed admission code', () {
    const path = 'lib/application/capabilities/capability.dart';
    final source = retainedR6RuntimeSource(
        path, File(path).readAsStringSync().replaceAll('\r\n', '\n'));
    expect(
        () => retainedR2CapabilitySource(
            path,
            source.replaceFirst(
                'if (principal == CapabilityPrincipal.external)',
                'if (false)')),
        throwsA(isA<TestFailure>()));
  });
  test('P7 projection retains the legacy Kernel byte freeze', () {
    const path = 'lib/application/capabilities/capability.dart';
    final source = retainedR6RuntimeSource(
        path, File(path).readAsStringSync().replaceAll('\r\n', '\n'));
    final legacy = retainedR2CapabilitySource(path, source);
    final changed = legacy.replaceFirst(
        'if (definition == null)', 'if (definition != null)');
    expect(changed, isNot(legacy));
    final entries = jsonDecode(
        File('test/application/modules/fixtures/retained_source_contracts.json')
            .readAsStringSync()) as List;
    final expected = entries.singleWhere((entry) => entry['path'] == path);
    final hash = StreamingSha256()..update(utf8.encode(changed));
    expect(hash.digestHex(), isNot(expected['sha256']));
  });
  test(
      'R7 exact amendments reject changed recipient, permission and history guards',
      () {
    for (final entry in <(String, String, String)>[
      (
        'lib/application/agent/agent_round_engine.dart',
        '!caps.canonicalToolHistory',
        'false'
      ),
      (
        'lib/application/capabilities/capability.dart',
        '!target.permissions.contains(CapabilityPermission.read)',
        'false'
      ),
      (
        'lib/application/agent/agent_turn_transcript.dart',
        'bool _toolHistoryPruned = false;',
        'bool _toolHistoryPruned = true;'
      ),
    ]) {
      final source = File(entry.$1).readAsStringSync().replaceAll('\r\n', '\n');
      expect(source, contains(entry.$2));
      expect(
          () => retainedR6RuntimeSource(
              entry.$1, source.replaceFirst(entry.$2, entry.$3)),
          throwsA(isA<TestFailure>()));
    }
  });
  test(
      'kernel and feature contributions retain Application dependency direction',
      () {
    final files = Directory('lib/application/modules')
        .listSync()
        .whereType<File>()
        .where((f) => f.path.endsWith('.dart'));
    for (final file in files) {
      final source = file.readAsStringSync();
      final imports = RegExp(r'''(?:import|export)\s+['"]([^'"]+)['"]''')
          .allMatches(source)
          .map((m) => m.group(1)!)
          .toList();
      for (final forbidden in [
        'mcp_dart',
        '/mcp/',
        'flutter',
        'dart:io',
        'dart:mirrors',
        '/ui/',
        '/data/',
        'database_helper',
        '/services/'
      ]) {
        expect(imports.any((i) => i.contains(forbidden)), isFalse,
            reason: file.path);
      }
      for (final forbidden in [
        'GetIt',
        'resolve<T>',
        'getService(',
        'ModuleManager',
        'ModuleEventBus',
        'PluginManager',
        'ModuleLifecycleManager'
      ]) {
        expect(source, isNot(contains(forbidden)), reason: file.path);
      }
    }
    final root = File('lib/main.dart').readAsStringSync();
    expect(root, contains('ModuleComposer().compose(buildDefaultModules('));
    expect(root, contains('agentSurface: moduleComposition.agentSurface'));
    expect(root, contains('moduleComposition.mcpSurface'));
    for (final legacy in [
      '...StudyCapabilities.definitions(',
      'missingAnswerCapability(',
      'studyPlanCapability(',
      'AgentStudyToolDispatcher(',
      'AgentRetrievalToolDispatcher('
    ]) {
      expect(root, isNot(contains(legacy)));
    }
    expect(root.indexOf('await databaseHelper.database;'),
        lessThan(root.indexOf('ModuleComposer().compose')));
    expect(root.indexOf('ModuleComposer().compose'),
        lessThan(root.lastIndexOf('runApp(')));
  });
}
