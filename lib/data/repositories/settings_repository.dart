import '../../application/backup/backup_restore_gate.dart';
import '../../core/database/database_helper.dart';

class SettingsRepository {
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

  // --- Clear Cache (for testing/reset) ---
  void clearCache() {
    _cache.clear();
  }
}
