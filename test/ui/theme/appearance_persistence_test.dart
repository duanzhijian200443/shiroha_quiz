import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:shiroha_quiz/core/database/database_helper.dart';
import 'package:shiroha_quiz/data/repositories/settings_repository.dart';
import 'package:shiroha_quiz/data/repositories/backup_snapshot_repository.dart';
import 'package:shiroha_quiz/application/appearance/appearance_settings_service.dart';
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

  test('legacy reads migrate both axes without rewriting history', () async {
    for (final name in ['light', 'dark', 'colorful']) {
      await DatabaseHelper.instance.saveSetting('app_theme', name);
      final service = AppearanceSettingsService(SettingsRepository(),
          paperDefaultEnabled: true);
      final restored = await service.load();
      expect(restored, ShirohaAppearance.fromLegacy(name));
      expect(await DatabaseHelper.instance.getSetting('app_theme'), name);
      expect(
          await DatabaseHelper.instance
              .getSetting(SettingsRepository.appearanceKey),
          isNull);
    }
  });

  test('rollout default applies only to absent history, never invalid history',
      () async {
    final settings = SettingsRepository();
    expect(await settings.getAppearance(), ShirohaAppearance.light);
    expect(await settings.getAppearance(paperDefaultEnabled: true),
        ShirohaAppearance.paperLight);
    for (final raw in [
      'light',
      'dark',
      'colorful',
      'morandi',
      '',
      'unknown',
      '{broken}'
    ]) {
      await DatabaseHelper.instance.saveSetting('app_theme', raw);
      settings.clearCache();
      expect(await settings.getAppearance(paperDefaultEnabled: true),
          ShirohaAppearance.fromLegacy(raw));
      expect(await DatabaseHelper.instance.getSetting('app_theme'), raw);
    }
  });

  for (final style in ShirohaThemeStyle.values) {
    for (final mode in ShirohaDisplayMode.values) {
      test('$style / $mode survives new service and database reopen', () async {
        final expected = ShirohaAppearance(style: style, mode: mode);
        await SettingsRepository().setAppTheme('dark');
        await AppearanceSettingsService(SettingsRepository()).save(expected);
        await DatabaseHelper.resetRuntimeProfileForTesting();
        DatabaseHelper.configureRuntimeProfile(
            DatabaseRuntimeProfile.explicitFile,
            databasePath: path);
        expect(await AppearanceSettingsService(SettingsRepository()).load(),
            expected);
        expect(await SettingsRepository().getAppTheme(), 'dark');
      });
    }
  }

  test('malformed/future records preserve bytes and use legacy fallback',
      () async {
    for (final legacy in [null, 'dark', 'colorful']) {
      final db = await DatabaseHelper.instance.database;
      await db.delete('app_settings');
      if (legacy != null) {
        await DatabaseHelper.instance.saveSetting('app_theme', legacy);
      }
      for (final raw in [
        '{broken}',
        '{}',
        'null',
        '[]',
        '{"version":2,"style":"paper","mode":"light"}',
        '{"version":1,"style":"paper","mode":null}',
        '{"version":1,"style":"unknown","mode":"system"}'
      ]) {
        await DatabaseHelper.instance
            .saveSetting(SettingsRepository.appearanceKey, raw);
        expect(
            await SettingsRepository().getAppearance(paperDefaultEnabled: true),
            ShirohaAppearance.fromLegacy(legacy));
        expect(
            await DatabaseHelper.instance
                .getSetting(SettingsRepository.appearanceKey),
            raw);
      }
    }
  });

  test('failed atomic save preserves both persisted axes and invalidates cache',
      () async {
    final settings = SettingsRepository();
    final previous = ShirohaAppearance.dark;
    await settings.setAppTheme('colorful');
    await settings.setAppearance(previous);
    final db = await DatabaseHelper.instance.database;
    await db.execute(
        "CREATE TRIGGER reject_appearance BEFORE INSERT ON app_settings "
        "WHEN NEW.key = 'app_appearance' BEGIN SELECT RAISE(ABORT, 'synthetic'); END");
    await expectLater(settings.setAppearance(ShirohaAppearance.paperLight),
        throwsA(isA<DatabaseException>()));
    expect(await settings.getAppearance(), previous);
    expect(await SettingsRepository().getAppearance(), previous);
    expect(await settings.getAppTheme(), 'colorful');
  });

  test('portable snapshots scrub both appearance keys without mutating source',
      () async {
    await SettingsRepository().setAppTheme('colorful');
    await SettingsRepository().setAppearance(ShirohaAppearance.paperLight);
    final snapshots = BackupSnapshotRepository();
    final rawPath = '${directory.absolute.path}/raw.sqlite';
    await snapshots.createRawConsistentSnapshot(rawPath);
    final raw = await databaseFactory.openDatabase(rawPath);
    expect(
        await raw.query('app_settings',
            where: 'key IN (?, ?)', whereArgs: ['app_theme', 'app_appearance']),
        hasLength(2));
    await raw.close();
    final portablePath = '${directory.absolute.path}/portable.sqlite';
    await snapshots.createSanitizedSnapshot(portablePath);
    final portable = await databaseFactory.openDatabase(portablePath);
    expect(
        await portable.query('app_settings',
            where: 'key IN (?, ?)', whereArgs: ['app_theme', 'app_appearance']),
        isEmpty);
    await portable.close();
    expect(await SettingsRepository().getAppearance(),
        ShirohaAppearance.paperLight);
    expect(await SettingsRepository().getAppTheme(), 'colorful');
  });

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
