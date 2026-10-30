import 'dart:io';
import 'package:flutter_test/flutter_test.dart';

void developmentSourceGuardCases() {
  const required = <String, List<String>>{
    'lib/composition/mcp_vnext_development_app.dart': [
      'kDebugMode',
      'relay.launchCurrent',
      'WindowsDevelopmentBootstrap.lifetime',
      'ExternalInitializationState.incomplete',
      '.initialize()',
      'port:48763,process:relay',
      'enableWithoutRetainedChannel:true',
      'associationRecoveryAvailable:()=>_current&&!relay.hasChild&&relay.observation.phase==FirstPartyRelayPhase.listening',
      'relay.onDisconnected=integration.controls.disconnectTransport',
      'relay.businessBootstrap=()=>_packet(pairingUi:false)',
      'if(!pairingUi){integration.controls.requireBusinessEnablement();',
      'startup!.currentPublicMaterial()',
      'monitorWindowsDevelopmentLifetime(isCurrent:()=>_current,',
      'launchIsCurrent:()=>relay.launchCurrent,stop:stopFor)',
      '!DateTime.now().toUtc().isBefore(_expiry!)',
      '_elapsed.elapsed>=WindowsDevelopmentBootstrap.lifetime',
    ],
    'lib/composition/mcp_vnext_development_lifetime.dart': [
      'Timer.periodic(constDuration(milliseconds:100)',
      'if(!isCurrent()){finalcause=isExpired()',
      'FirstPartyDevelopmentStopCause.expired',
      '!launchIsCurrent()',
      'FirstPartyDevelopmentStopCause.relayLost',
      'FirstPartyDevelopmentStopCause.appInvalidated',
      'unawaited(stop(cause).then',
    ],
    'lib/composition/mcp_vnext_development_bridge.dart': [
      'WindowsDevelopmentAdmission.receive(pairingUi:false)',
      'if(failure.unsettled)rethrow',
      'awaitserveWindowsBridgeStdio(profileVersion:profileVersion)',
      'verifiedEpochHighWater:BigInt.zero',
      'connectionMode:WindowsCodexConnectionMode.appOwnedDevelopment',
      'requireSecurityAdmission:()async=>admission.requireCurrent()',
      'appOwnedAdmission:admission',
      'input:admission.input.remainingStdin',
    ],
    'lib/composition/mcp_vnext_development_pairing.dart': [
      '!kDebugMode',
      'WindowsDevelopmentAdmission.receive(pairingUi:true)',
      'native.acquireBridgeObjects()',
      'store.read(4)',
      'if(existing!=null)',
      'requirePublication:admitted.packet.requireCurrentPublication',
      'awaitconnection.waitForProofClosure()',
      'BridgeUiHost.open(',
      'AppDataEnvironment.development',
      "'bridge-pairing-ui'",
      'awaitopened.closeForBusiness()',
      'acquired.close()',
    ],
    'lib/data/external/windows_development_admission.dart': [
      'WindowsAppParentGuard.open(pairingUi:pairingUi)',
      'WindowsBootstrapInput(stdin,isCurrent:()=>guard.isCurrent)',
      'packet.requireCurrent(',
      '_elapsed.elapsed<_remaining',
      'if(_claimed||packet.pairingUi)',
      '_guard.close()',
    ],
  };
  const forbidden = [
    'test/',
    'Fake',
    'Platform.environment',
    'String.fromEnvironment',
    '.recoverServer(',
    'DatabaseHelper',
    'ExternalSession(',
    'ExternalPrincipal(',
    'PairingProof(',
    'AuthenticatedPeerEvidence(',
    'DiscoveryDescriptorCodec',
    'ExchangeMessageCodec',
    'PairingTranscriptCodec',
    'Process.kill',
    'DirectDatabase',
    'ServerSocket.bind',
    'SecurityContext(',
  ];
  bool valid(String path, String source) {
    final compact = source.replaceAll(RegExp(r'\s'), '');
    return required[path]!.every(compact.contains) &&
        forbidden.every((token) => !source.contains(token));
  }

  test(
      'development roots retain exact admission and reject authority mutations',
      () {
    for (final entry in required.entries) {
      final source = File(entry.key).readAsStringSync();
      expect(valid(entry.key, source), isTrue, reason: entry.key);
      for (final token in forbidden) {
        expect(valid(entry.key, '$source\n$token'), isFalse,
            reason: '${entry.key}: $token');
      }
      final compact = source.replaceAll(RegExp(r'\s'), '');
      for (final token in entry.value) {
        expect(valid(entry.key, compact.replaceAll(token, 'removed')), isFalse,
            reason: '${entry.key}: required $token');
      }
    }
    final bootstrap = File('lib/composition/mcp_vnext_windows_bootstrap.dart')
        .readAsStringSync();
    expect(bootstrap, contains('appOwnedAdmission.claimBusiness()'));
    expect(
        bootstrap.replaceAll(RegExp(r'\s'), ''),
        contains(
            'appOwnedAdmission?.packet.requireCurrentPublication(descriptor.publicationEpoch)'));
    final native =
        File('windows/local_relay/local_relay.cpp').readAsStringSync();
    for (final token in [
      'role > 3',
      'p->authenticate_parent()',
      'independent_launch(id, peer.value)',
      'CompareFileTime(&parent_created, &self_created) >= 0',
      'GetShellWindow()',
      'bind_image(peer.value, root + L"\\\\shiroha_quiz.exe"'
    ]) {
      expect(native, contains(token));
    }
    final main = File('lib/main.dart').readAsStringSync();
    expect(main, contains("arguments.single == '--shiroha-bridge-pairing-ui'"));
    expect(main, contains('arguments.length == 1'));
    expect(main, contains('exitCode = 64'));
  });

  test('development recovery retains same Owner and original Host revoke only',
      () {
    final source = File('lib/composition/mcp_vnext_windows_startup.dart')
        .readAsStringSync()
        .replaceAll(RegExp(r'\s'), '');
    const tokens = [
      'this.associationRecoveryAvailable,',
      'associationRecovery:associationRecoveryAvailable==null||!enableWithoutRetainedChannel?null:',
      'dependencies.associations.usesOwner(dependencies.owner)',
      'dependencies.associations.read(reference.profileId)',
      'returnstartup._host!.revoke(reference,expectedRevision);',
    ];
    bool valid(String text) => tokens.every(text.contains);
    expect(valid(source), isTrue);
    for (final token in tokens) {
      expect(valid(source.replaceAll(token, 'removed')), isFalse);
    }
    for (final file
        in Directory('lib').listSync(recursive: true).whereType<File>()) {
      if (!file.path.endsWith('.dart') ||
          file.path.replaceAll('\\', '/') ==
              'lib/composition/mcp_vnext_development_app.dart') {
        continue;
      }
      expect(file.readAsStringSync(),
          isNot(contains('associationRecoveryAvailable:')),
          reason: file.path);
    }
  });
}
