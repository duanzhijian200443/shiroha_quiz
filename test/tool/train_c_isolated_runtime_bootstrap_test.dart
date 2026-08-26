import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

import '../../tool/train_c_isolated_runtime.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('isolated runtime self-bootstraps FFI without test preconfiguration',
      () async {
    final runtime = await TrainCIsolatedRuntime.create();
    try {
      await runtime.open();
      final database = await runtime.database;
      final databasePath = p.normalize(p.absolute(database.path));
      final isolatedDbRoot = p.normalize(p.absolute(runtime.dbDirectory.path));

      expect(p.isWithin(isolatedDbRoot, databasePath), isTrue);
      expect(File(databasePath).existsSync(), isTrue);
      expect((await runtime.verifyBlankStore()).passed, isTrue);
    } finally {
      await runtime.dispose();
    }
  });
}
