import '../models/ai_engine_profile.dart';
import '../persistence/ai_engine_store.dart';

class AiEngineDependencyException implements Exception {
  const AiEngineDependencyException();

  @override
  String toString() => 'AiEngineDependencyException';
}

class AiEngineRepository {
  const AiEngineRepository({required AiEngineStore store}) : _store = store;

  final AiEngineStore _store;

  Future<List<AiEngineProfile>> getEngines(AiEngineType type) async {
    final profiles = await _store.listAiEngines(type);
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
    final profile = await _store.getActiveAiEngine(type);
    if (profile == null) return null;
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

  Future<void> saveEngine(AiEngineProfile profile) =>
      _store.saveAiEngine(profile);

  Future<void> setActiveEngine(String id, AiEngineType type) =>
      _store.setActiveAiEngine(id, type);

  Future<void> deleteEngine(String id) => _store.deleteAiEngine(id);

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
