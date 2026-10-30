import 'dart:convert';
import '../../application/backup/backup_restore_gate.dart';
import '../../application/external/external_device_connection.dart';
import '../../core/database/database_helper.dart';

final class SqliteExternalDeviceSelectionStore
    implements ExternalDeviceSelectionStore {
  const SqliteExternalDeviceSelectionStore({required this.databaseHelper});
  final DatabaseHelper databaseHelper;
  static const settingKey = 'external_device_selection_v1';

  @override
  Future<ExternalDeviceSelection?> readDeviceSelection() async {
    final raw = await databaseHelper.getSetting(settingKey);
    if (raw == null) return null;
    return _decode(raw);
  }

  ExternalDeviceSelection _decode(String raw) {
    try {
      final value = jsonDecode(raw);
      if (value is! Map ||
          value.length != 5 ||
          value['version'] != 1 ||
          value['generation'] is! int ||
          value['needsCleanup'] is! bool ||
          !value.containsKey('reference')) {
        throw const FormatException();
      }
      final target = switch (value['kind']) {
        'unselected' when value['reference'] == null =>
          const ExternalDeviceTarget.unselected(),
        'windows' when value['reference'] == null =>
          const ExternalDeviceTarget.windows(),
        'android' when value['reference'] is String =>
          ExternalDeviceTarget.android(value['reference'] as String),
        _ => throw const FormatException(),
      };
      return ExternalDeviceSelection(
          target: target,
          generation: value['generation'] as int,
          needsCleanup: value['needsCleanup'] as bool);
    } catch (_) {
      // Keep the original row; no guessed repair or target fallback.
      throw const ExternalDeviceException(ExternalDeviceFailure.needsAttention);
    }
  }

  String _encode(ExternalDeviceSelection value) => jsonEncode({
        'version': 1,
        'kind': value.target.kind.name,
        'reference': value.target.reference,
        'generation': value.generation,
        'needsCleanup': value.needsCleanup,
      });

  @override
  Future<void> acknowledgeDeviceCleanup(ExternalDeviceSelection expected,
          ExternalDeviceSelection replacement) =>
      BackupRestoreMutationGate.instance.runMutation(() async {
        final db = await databaseHelper.database;
        await db.transaction((txn) async {
          final rows = await txn
              .query('app_settings', where: 'key = ?', whereArgs: [settingKey]);
          if (rows.length != 1 || rows.single['value'] is! String) {
            throw const ExternalDeviceException(
                ExternalDeviceFailure.needsAttention);
          }
          final raw = rows.single['value'] as String;
          final current = _decode(raw);
          if (!expected.needsCleanup ||
              replacement.needsCleanup ||
              current.target != expected.target ||
              current.generation != expected.generation ||
              current.needsCleanup != expected.needsCleanup ||
              replacement.target != expected.target ||
              replacement.generation != expected.generation + 1) {
            throw const ExternalDeviceException(
                ExternalDeviceFailure.needsAttention);
          }
          final changed = await txn.update(
              'app_settings', {'value': _encode(replacement)},
              where: 'key = ? AND value = ?', whereArgs: [settingKey, raw]);
          if (changed != 1) {
            throw const ExternalDeviceException(
                ExternalDeviceFailure.needsAttention);
          }
        });
      });

  @override
  Future<void> saveDeviceSelection(ExternalDeviceSelection value) =>
      BackupRestoreMutationGate.instance.runMutation(
          () => databaseHelper.saveSetting(settingKey, _encode(value)));
}
