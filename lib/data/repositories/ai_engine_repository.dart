import '../../core/database/database_helper.dart';
import '../models/ai_engine_profile.dart';

class AiEngineRepository {
  AiEngineRepository({DatabaseHelper? databaseHelper})
      : _databaseHelper = databaseHelper ?? DatabaseHelper.instance;

  static final AiEngineRepository instance = AiEngineRepository();

  final DatabaseHelper _databaseHelper;

  Future<List<AiEngineProfile>> getEngines(AiEngineType type) async {
    final rows = await _databaseHelper.getAiEngines(type.dbValue);
    return rows
        .map((row) => AiEngineProfile.fromMap(row, fallbackType: type))
        .toList(growable: false);
  }

  Future<AiEngineProfile?> getActiveEngine(AiEngineType type) async {
    final row = await _databaseHelper.getActiveAiEngine(type.dbValue);
    if (row == null) return null;
    return AiEngineProfile.fromMap(row, fallbackType: type);
  }

  Future<AiEngineProfile?> getActiveTextEngine() {
    return getActiveEngine(AiEngineType.text);
  }

  Future<AiEngineProfile?> getActiveVisionEngine() {
    return getActiveEngine(AiEngineType.vision);
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
