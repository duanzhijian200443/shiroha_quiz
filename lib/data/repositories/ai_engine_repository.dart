import '../models/ai_engine_profile.dart';

/// Pure Dart repository for managing AI engine profiles.
///
/// Decoupled from direct Flutter/sqflite imports to allow pure Dart CLI execution.
class AiEngineRepository {
  AiEngineRepository({dynamic databaseHelper})
      : _db = databaseHelper;

  static AiEngineRepository? _instance;

  /// Optional global provider for default database helper (e.g. DatabaseHelper.instance).
  /// Set automatically when database_helper.dart is loaded.
  static dynamic Function()? defaultDatabaseHelperProvider;

  static AiEngineRepository get instance =>
      _instance ??= AiEngineRepository();

  static set instance(AiEngineRepository repo) => _instance = repo;

  final dynamic _db;

  dynamic get _effectiveDb => _db ?? defaultDatabaseHelperProvider?.call();

  Future<List<AiEngineProfile>> getEngines(AiEngineType type) async {
    final db = _effectiveDb;
    if (db == null) return const [];
    final rows = await (db.getAiEngines(type.dbValue) as Future);
    final profiles = (rows as List)
        .map((row) =>
            AiEngineProfile.fromMap(Map<String, dynamic>.from(row as Map), fallbackType: type))
        .toList(growable: false);
    if (type == AiEngineType.ocr) {
      return profiles
          .where((profile) => profile.engineType == AiEngineType.ocr)
          .toList(growable: false);
    }
    return profiles
        .where((profile) => profile.engineType != AiEngineType.ocr)
        .toList(growable: false);
  }

  Future<AiEngineProfile?> getActiveEngine(AiEngineType type) async {
    final db = _effectiveDb;
    if (db == null) return null;
    final row = await (db.getActiveAiEngine(type.dbValue) as Future);
    if (row == null) return null;
    final profile =
        AiEngineProfile.fromMap(Map<String, dynamic>.from(row as Map), fallbackType: type);
    if (type == AiEngineType.ocr) {
      return profile.engineType == AiEngineType.ocr ? profile : null;
    }
    return profile.engineType == AiEngineType.ocr ? null : profile;
  }

  Future<AiEngineProfile?> getActiveTextEngine() {
    return getActiveEngine(AiEngineType.text);
  }

  Future<AiEngineProfile?> getActiveVisionEngine() {
    return getActiveEngine(AiEngineType.vision);
  }

  Future<AiEngineProfile?> getActiveOcrEngine() async {
    final profile = await getActiveEngine(AiEngineType.ocr);
    if (profile == null || profile.engineType != AiEngineType.ocr) {
      return null;
    }
    return profile;
  }

  Future<void> saveEngine(AiEngineProfile profile) async {
    final db = _effectiveDb;
    if (db != null) {
      await db.saveAiEngine(profile.toMap());
    }
  }

  Future<void> setActiveEngine(String id, AiEngineType type) async {
    final db = _effectiveDb;
    if (db != null) {
      await db.setActiveAiEngine(id, type.dbValue);
    }
  }

  Future<void> deleteEngine(String id) async {
    final db = _effectiveDb;
    if (db != null) {
      await db.deleteAiEngine(id);
    }
  }

  Future<void> renameEngine(
      String id, String newName, AiEngineType type) async {
    final engines = await getEngines(type);
    final target = engines.where((e) => e.id == id).firstOrNull;
    if (target != null) {
      final updatedMap = target.toMap();
      updatedMap['name'] = newName;
      final updatedProfile =
          AiEngineProfile.fromMap(updatedMap, fallbackType: type);
      await saveEngine(updatedProfile);
    }
  }
}
