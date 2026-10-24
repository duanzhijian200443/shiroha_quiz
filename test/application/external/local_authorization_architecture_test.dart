import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import '../../mcp/fixtures/first_party_app_integration_cases.dart';
import '../../mcp/fixtures/first_party_pairing_cases.dart';
import '../../mcp/fixtures/first_party_interaction_cases.dart';
import '../../mcp/fixtures/windows_app_transport_cases.dart';
import '../../ui/external/first_party_bridge_pairing_control_test.dart'
    as bridge_ui;
import '../generated_question/generated_test_support.dart'
    show initializeGeneratedTests;

void main() {
  initializeGeneratedTests();
  registerFirstPartyAppIntegrationTests();
  registerFirstPartyPairingTests();
  registerFirstPartyInteractionTests();
  windowsAppTransportCases();
  bridge_ui.main();
  test('new local UI depends on Application and never Data/SQLite', () {
    for (final path in [
      'lib/ui/pages/external_authorization_screen.dart',
      'lib/ui/pages/first_party_external_control.dart',
      'lib/ui/pages/first_party_bridge_pairing_control.dart',
      'lib/ui/dependencies/local_authorization_scope.dart',
    ]) {
      final source = File(path).readAsStringSync();
      expect(source, isNot(contains('data/')));
      expect(source, isNot(contains('database_helper')));
      expect(source, isNot(contains('DatabaseHelper')));
      expect(source, isNot(contains('sqflite')));
    }
  });
  test(
      'management is absent from Agent/MCP/Capability projections and Host factories',
      () {
    final service =
        File('lib/application/external/local_authorization_service.dart')
            .readAsStringSync();
    for (final forbidden in [
      'external_trust_core',
      'local_host_dispatch',
      'ExternalSession',
      'ExternalPrincipal',
      'PairingProof',
      'Socket',
      'HttpServer'
    ]) {
      expect(service, isNot(contains(forbidden)));
    }
    for (final root in [
      'lib/mcp',
      'lib/application/agent',
      'lib/services/agent',
      'lib/application/capabilities'
    ]) {
      for (final entity
          in Directory(root).listSync(recursive: true).whereType<File>()) {
        if (!entity.path.endsWith('.dart')) continue;
        final source = entity.readAsStringSync();
        expect(source, isNot(contains('local_authorization_service')),
            reason: entity.path);
        expect(source, isNot(contains('LocalAuthorizationService')),
            reason: entity.path);
        expect(source, isNot(contains('ExternalProfileQuery')),
            reason: entity.path);
      }
    }
    final composition = File('lib/main.dart').readAsStringSync();
    expect(composition,
        contains('compositionIsCurrent: () => authorizationDatabase.isOpen'));
    expect(composition, contains('localAuthorization?.invalidate()'));
    expect(composition, isNot(contains('LocalHostDispatchCore')));
    expect(composition, isNot(contains('ExternalTrustCore')));
    final settings =
        File('lib/ui/pages/profile_screen.dart').readAsStringSync();
    expect(settings, contains('profile-external-authorization-row'));
    expect(settings, contains('ExternalAuthorizationScreen('));
  });
}
