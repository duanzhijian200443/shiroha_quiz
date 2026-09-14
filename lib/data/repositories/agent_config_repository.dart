import '../../application/agent/agent_config_service.dart';
import '../../application/agent/agent_config.dart';
import '../../application/ai_config/ai_config_ports.dart';
import '../../core/database/database_helper.dart';

final class SqliteAgentConfigStore
    implements AgentConfigStorePort, AgentModelReferencePort {
  SqliteAgentConfigStore({DatabaseHelper? databaseHelper})
      : _databaseHelper = databaseHelper ?? DatabaseHelper.instance;

  static const String settingKey = 'agent_config_v0';

  final DatabaseHelper _databaseHelper;

  @override
  Future<String?> readAgentConfig() async {
    try {
      return await _databaseHelper.getSetting(settingKey);
    } catch (_) {
      throw const AgentConfigStoreException(
        AgentConfigStoreFailure.temporarilyUnavailable,
      );
    }
  }

  @override
  Future<void> writeAgentConfig(String encodedConfig) async {
    try {
      await _databaseHelper.saveSetting(settingKey, encodedConfig);
    } catch (_) {
      throw const AgentConfigStoreException(
        AgentConfigStoreFailure.temporarilyUnavailable,
      );
    }
  }

  @override
  Future<Set<String>> referencedModelRefs() async {
    final encoded = await readAgentConfig();
    if (encoded == null) return const <String>{};
    final config = const AgentConfigCodec().decode(encoded);
    return <String>{
      config.mainProfileId,
      if (config.fallbackProfileId case final fallback?) fallback,
    };
  }
}
