import '../../core/database/database_helper.dart';
import '../models/ai_engine_profile.dart';

class AiEngineRepository {
  AiEngineRepository({DatabaseHelper? databaseHelper})
      : _databaseHelper = databaseHelper ?? DatabaseHelper.instance;

  static final AiEngineRepository instance = AiEngineRepository();

  final DatabaseHelper _databaseHelper;

  Future<List<AiEngineProfile>> getEngines(AiEngineType type) async {
    final rows = await _databaseHelper.getAiEngines(type.dbValue);
    final profiles = rows
        .map((row) => AiEngineProfile.fromMap(row, fallbackType: type))
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
    final row = await _databaseHelper.getActiveAiEngine(type.dbValue);
    if (row == null) return null;
    final profile = AiEngineProfile.fromMap(row, fallbackType: type);
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
    await _databaseHelper.saveAiEngine(profile.toMap());
  }

  Future<void> setActiveEngine(String id, AiEngineType type) async {
    await _databaseHelper.setActiveAiEngine(id, type.dbValue);
  }

  Future<void> deleteEngine(String id) async {
    await _databaseHelper.deleteAiEngine(id);
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
