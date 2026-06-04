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
}
