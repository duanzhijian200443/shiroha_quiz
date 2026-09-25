import 'dart:convert';

import '../../application/backup/backup_restore_gate.dart';
import '../../application/import/import_advanced_preferences.dart';
import '../../application/import/import_target_catalog_service.dart';
import '../../application/import/import_target_selection.dart';
import '../../core/database/database_helper.dart';

class SettingsRepository implements ImportTargetSelectionStore {
  SettingsRepository({DatabaseHelper? databaseHelper})
      : _databaseHelper = databaseHelper ?? DatabaseHelper.instance;

  static final SettingsRepository instance = SettingsRepository();

  final DatabaseHelper _databaseHelper;

  // Advanced Data Structure: In-memory cache to optimize read operations
  final Map<String, String> _cache = {};

  Future<String?> _getSettingWithCache(String key) async {
    if (_cache.containsKey(key)) {
      return _cache[key];
    }
    final value = await _databaseHelper.getSetting(key);
    if (value != null) {
      _cache[key] = value;
    }
    return value;
  }

  Future<void> _saveSettingWithCache(String key, String value) {
    return BackupRestoreMutationGate.instance.runMutation(() async {
      _cache[key] = value;
      await _databaseHelper.saveSetting(key, value);
    });
  }

  // --- App Theme ---
  Future<String> getAppTheme({String defaultTheme = 'light'}) async {
    final value = await _getSettingWithCache('app_theme');
    return value ?? defaultTheme;
  }

  Future<void> setAppTheme(String theme) async {
    await _saveSettingWithCache('app_theme', theme);
  }

  // --- Current Bank ---
  Future<String?> getCurrentBank() async {
    return _getSettingWithCache('current_bank');
  }

  Future<void> setCurrentBank(String bankName) async {
    await _saveSettingWithCache('current_bank', bankName);
  }

  void clearCurrentBankCache() {
    _cache.remove('current_bank');
  }

  // --- Daily Quota ---
  Future<int> getDailyQuota(String bankName, {int defaultQuota = 15}) async {
    final key = '${bankName}_daily_quota';
    final valueStr = await _getSettingWithCache(key);
    if (valueStr == null) return defaultQuota;
    return int.tryParse(valueStr) ?? defaultQuota;
  }

  Future<void> setDailyQuota(String bankName, int quota) async {
    final key = '${bankName}_daily_quota';
    await _saveSettingWithCache(key, quota.toString());
  }

  // --- Import Advanced Preferences ---
  Future<ImportAdvancedPreferences> getImportAdvancedPreferences() async {
    final raw = await _getSettingWithCache('import_advanced_preferences');
    if (raw == null) return ImportAdvancedPreferences.defaults;
    try {
      final decoded = jsonDecode(raw);
      if (decoded is Map<String, dynamic>) {
        return ImportAdvancedPreferences.fromJson(decoded);
      }
    } on FormatException {
      // Corrupt payloads fall back to the frozen defaults.
    }
    return ImportAdvancedPreferences.defaults;
  }

  Future<void> setImportAdvancedPreferences(
    ImportAdvancedPreferences preferences,
  ) async {
    await _saveSettingWithCache(
      'import_advanced_preferences',
      jsonEncode(preferences.toJson()),
    );
  }

  @override
  Future<ImportTargetSelection?> getLastImportTarget() async {
    final raw = await _getSettingWithCache('last_import_target');
    if (raw == null || raw.isEmpty) return null;
    try {
      return ImportTargetSelection.fromJson(jsonDecode(raw));
    } on FormatException {
      return null;
    }
  }

  @override
  Future<void> setLastImportTarget(ImportTargetSelection? selection) async {
    const key = 'last_import_target';
    final value = selection == null ? '' : jsonEncode(selection.toJson());
    await BackupRestoreMutationGate.instance.runMutation(() async {
      await _databaseHelper.saveSetting(key, value);
      _cache[key] = value;
    });
  }

  // --- Clear Cache (for testing/reset) ---
  void clearCache() {
    _cache.clear();
  }
}
