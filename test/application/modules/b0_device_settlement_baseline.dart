import 'package:flutter_test/flutter_test.dart';

/// Projects only the exact B0 owner-settlement insertion before checking the
/// original runtime hash. Ordering and all other source bytes remain frozen.
String retainedB0DeviceSettlementSource(String path, String source) {
  if (path != 'lib/services/backup/backup_restore_runtime.dart') return source;
  const before = '''          await _directorySize(liveManaged),
    );
    await Directory(rollbackDbPath).create(recursive: true);
''';
  const after = '''          await _directorySize(liveManaged),
    );
    // Freeze rollback only after the original owners have persisted clean
    // settlement. Otherwise a later rollback resurrects their dirty markers.
    // Keep SQLite open; the existing close barrier still runs before swap.
    await _database.settleProductionOwners();
    await Directory(rollbackDbPath).create(recursive: true);
''';
  expect(source.split(after).length - 1, 1,
      reason:
          'Missing/changed/duplicated exact B0 settlement amendment: $path');
  return source.replaceFirst(after, before);
}
