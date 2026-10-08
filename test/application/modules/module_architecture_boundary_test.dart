import 'dart:convert';
import 'dart:io';
import 'package:shiroha_quiz/services/backup/sha256.dart';
import 'package:flutter_test/flutter_test.dart';
import 'r5a_storage_baseline.dart';

void main() {
  test(
      'AR-R3 generic lifecycle/round body, Provider, receipts, storage and MCP wire remain byte-identical',
      () {
    final entries = jsonDecode(
        File('test/application/modules/fixtures/retained_source_contracts.json')
            .readAsStringSync()) as List;
    for (final entry in entries) {
      final path = entry['path'] as String;
      var source = File(path).readAsStringSync().replaceAll('\r\n', '\n');
      source = retainedR4StorageSource(path, source);
      final anchor = entry['anchor'] as String?;
      if (anchor != null) {
        expect(source, contains(anchor), reason: path);
        source = source.substring(source.indexOf(anchor));
      }
      final hash = StreamingSha256()..update(utf8.encode(source));
      expect(hash.digestHex(), entry['sha256'], reason: path);
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
