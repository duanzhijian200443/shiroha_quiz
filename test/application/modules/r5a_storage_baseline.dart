import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';

const r5aStorageHashExceptions = {
  'lib/core/database/database_helper.dart',
  'lib/data/repositories/backup_snapshot_repository.dart',
};

/// Exact additive-source projection, not a new hash or an ignored region.
/// Called only for the two explicitly user-authorized storage owners.
String retainedR4StorageSource(String path, String source) {
  if (!r5aStorageHashExceptions.contains(path)) return source;
  final fixtures = jsonDecode(
      File('test/application/modules/fixtures/r5a_storage_additions.json')
          .readAsStringSync()) as Map;
  expect(fixtures.keys.toSet(), r5aStorageHashExceptions);
  final operations = fixtures[path] as List;
  expect(operations, isNotEmpty);
  for (final raw in operations.reversed) {
    final op = raw as Map;
    expect(op.keys.toSet(), {'before', 'after', 'count'});
    final before = op['before'] as String;
    final after = op['after'] as String;
    final count = op['count'] as int;
    expect(before, isNotEmpty);
    expect(after, isNotEmpty);
    expect(count, greaterThan(0));
    final version = path == 'lib/core/database/database_helper.dart' &&
        before == 'static const int _dbVersion = importTaskSchemaVersion;' &&
        after ==
            'static const int _dbVersion = generatedProposalSchemaVersion;';
    if (!version) {
      expect(after.length, greaterThan(before.length));
      expect(after.split(before).length - 1, 1,
          reason: 'Only exact additions may be projected away');
    } else {
      expect(count, 1);
    }
    expect(source.split(after).length - 1, count,
        reason: 'Missing/duplicated R5A storage addition: $path');
    source = source.replaceAll(after, before);
  }
  return source;
}
