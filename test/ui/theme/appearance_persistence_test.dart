import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:shiroha_quiz/core/database/database_helper.dart';
import 'package:shiroha_quiz/data/repositories/settings_repository.dart';
import 'package:shiroha_quiz/ui/theme/app_theme.dart';
import 'package:shiroha_quiz/ui/theme/shiroha_theme_tokens.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory directory;
  late String path;

  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfiNoIsolate;
  });
  setUp(() async {
    await DatabaseHelper.resetRuntimeProfileForTesting();
    final root = await Directory('build/theme-persistence-tests')
        .create(recursive: true);
    directory = await root.createTemp('case-');
    path = directory.absolute.path;
    DatabaseHelper.configureRuntimeProfile(DatabaseRuntimeProfile.explicitFile,
        databasePath: path);
  });
  tearDown(() async {
    await DatabaseHelper.resetRuntimeProfileForTesting();
    await directory.delete(recursive: true);
  });

  for (final name in ['light', 'dark', 'colorful']) {
    test('$name survives database close and a new settings repository',
        () async {
      await SettingsRepository().setAppTheme(name);
      await DatabaseHelper.resetRuntimeProfileForTesting();
      DatabaseHelper.configureRuntimeProfile(
          DatabaseRuntimeProfile.explicitFile,
          databasePath: path);
      final restored = await SettingsRepository().getAppTheme();
      expect(restored, name);
      expect(
          AppTheme.getTheme(restored)
              .extension<ShirohaThemeTokens>()!
              .appearance
              .name,
          name);
    });
  }

  test('missing, historical and corrupt values keep a read-only light fallback',
      () async {
    expect(AppTheme.normalizeName(await SettingsRepository().getAppTheme()),
        'light');
    for (final raw in ['morandi', '', 'unknown', '{broken}']) {
      await DatabaseHelper.instance.saveSetting('app_theme', raw);
      final settings = SettingsRepository();
      expect(AppTheme.normalizeName(await settings.getAppTheme()), 'light');
      expect(await DatabaseHelper.instance.getSetting('app_theme'), raw);
    }
  });
}
