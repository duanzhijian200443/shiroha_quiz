import 'package:flutter_test/flutter_test.dart';
import 'package:shiroha_quiz/application/agent/agent_config_service.dart';
import 'package:shiroha_quiz/core/database/database_helper.dart';
import 'package:shiroha_quiz/data/repositories/agent_config_repository.dart';

void main() {
  test('agent config uses one existing app_settings key', () async {
    final database = _DatabaseHelper();
    final store = SqliteAgentConfigStore(databaseHelper: database);

    expect(await store.readAgentConfig(), isNull);
    await store.writeAgentConfig('{"fixture":true}');

    expect(database.readKeys, <String>['agent_config_v0']);
    expect(database.writes, <String, String>{
      'agent_config_v0': '{"fixture":true}',
    });
    expect(await store.readAgentConfig(), '{"fixture":true}');
  });

  test('database failures become fixed store failures without raw details',
      () async {
    final store = SqliteAgentConfigStore(
      databaseHelper: _DatabaseHelper(
        failure: StateError('SENSITIVE_DATABASE_MARKER'),
      ),
    );

    await expectLater(
      store.readAgentConfig(),
      throwsA(
        isA<AgentConfigStoreException>().having(
          (error) => error.toString(),
          'safe string',
          isNot(contains('SENSITIVE_DATABASE_MARKER')),
        ),
      ),
    );
  });
}

final class _DatabaseHelper extends Fake implements DatabaseHelper {
  _DatabaseHelper({this.failure});

  final Object? failure;
  final Map<String, String> writes = <String, String>{};
  final List<String> readKeys = <String>[];

  @override
  Future<String?> getSetting(String key) async {
    if (failure case final error?) throw error;
    readKeys.add(key);
    return writes[key];
  }

  @override
  Future<void> saveSetting(String key, String value) async {
    if (failure case final error?) throw error;
    writes[key] = value;
  }
}
