import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:shiroha_quiz/data/external/windows_codex_client.dart';

import 'windows_codex_selection_fixture.dart';

void windowsCodexClientCases() {
  for (final digest in [
    WindowsCodexClientSelection.isolatedPatchDigest,
    'cbacbb9726262ef558b4af0438a1b2a5bba9076132401d947b5b4d2bf92ab0e4',
    '1103e9e09c71fa2cd0afd6d8f3b9a2d63174fe8efd7cb5bd09f1cb14ef58a098',
    '6f267830b029ee25d9339864aa867cd45de9f8fd4c5ea007d2e63c13a0c66d36',
    'unknown',
  ]) {
    test(
        'product selection rejects ${digest.substring(0, 7.clamp(0, digest.length))}',
        () async {
      final selection = await WindowsCodexClientSelection.inspect(
          executable: FakeCodexExecutable(digest),
          use: WindowsCodexClientUse.product,
          mode: WindowsCodexConnectionMode.direct);
      await expectLater(
          selection.claim(WindowsCodexConnectionMode.direct), throwsStateError);
      var dispatched = false;
      await expectLater(
          selection.discoverBeforeBusiness(
              discover: () async {
                dispatched = true;
              },
              settleOriginal: () async {}),
          throwsStateError);
      expect(dispatched, isFalse);
    });
  }

  test('unknown build cannot enter isolated business either', () async {
    final selection = await WindowsCodexClientSelection.inspect(
        executable: FakeCodexExecutable('unknown'),
        use: WindowsCodexClientUse.isolatedValidation,
        mode: WindowsCodexConnectionMode.direct);
    await expectLater(
        selection.claim(WindowsCodexConnectionMode.direct), throwsStateError);
  });

  test(
      'discovery joins original drain and rejects concurrent or active inventory',
      () async {
    final selection = await isolatedClientSelection();
    final drained = Completer<void>();
    final entered = Completer<void>();
    final discovery = selection.discoverBeforeBusiness(
        discover: () async => 7,
        settleOriginal: () {
          entered.complete();
          return drained.future;
        });
    await entered.future;
    var calls = 0;
    Future<void> compete() => selection.discoverBeforeBusiness(
        discover: () async {
          calls++;
        },
        settleOriginal: () async {});
    await expectLater(compete(), throwsStateError);
    await expectLater(
        selection.claim(WindowsCodexConnectionMode.direct), throwsStateError);
    drained.complete();
    expect(await discovery, 7);
    await selection.claim(WindowsCodexConnectionMode.direct);
    await expectLater(compete(), throwsStateError);
    await expectLater(
        selection.claim(WindowsCodexConnectionMode.direct), throwsStateError);
    expect(calls, 0);
  });

  for (final failDrain in [false, true]) {
    test('discovery failure retained, including drain=$failDrain', () async {
      final selection = await isolatedClientSelection();
      var settled = false;
      await expectLater(
          selection.discoverBeforeBusiness(discover: () async {
            if (!failDrain) throw StateError('discovery failed');
          }, settleOriginal: () async {
            settled = true;
            if (failDrain) throw StateError('unknown original settlement');
          }),
          throwsStateError);
      expect(settled, isTrue);
      await expectLater(
          selection.claim(WindowsCodexConnectionMode.direct), throwsStateError);
      await expectLater(
          selection.discoverBeforeBusiness(
              discover: () async {}, settleOriginal: () async {}),
          throwsStateError);
    });
  }

  test('changed executable is rejected and failure cannot be retried',
      () async {
    final executable = FakeCodexExecutable();
    final selection = await WindowsCodexClientSelection.inspect(
        executable: executable,
        use: WindowsCodexClientUse.isolatedValidation,
        mode: WindowsCodexConnectionMode.direct);
    executable.digest = 'replacement';
    await expectLater(
        selection.claim(WindowsCodexConnectionMode.direct), throwsStateError);
    executable.digest = WindowsCodexClientSelection.isolatedPatchDigest;
    await expectLater(
        selection.claim(WindowsCodexConnectionMode.direct), throwsStateError);
  });

  test('Direct and Hosted cannot consume the same selection', () async {
    final selection =
        await isolatedClientSelection(mode: WindowsCodexConnectionMode.hosted);
    await expectLater(
        selection.claim(WindowsCodexConnectionMode.direct), throwsStateError);
    await selection.claim(WindowsCodexConnectionMode.hosted);
    await expectLater(
        selection.claim(WindowsCodexConnectionMode.hosted), throwsStateError);
  });

  test(
      'both trusted roots check client compatibility before security or acquisition',
      () {
    for (final name in ['bootstrap', 'registration']) {
      final source = File('lib/composition/mcp_vnext_windows_$name.dart')
          .readAsStringSync();
      expect(source, contains('if (clientSelection == null)'));
      expect(source.indexOf('await clientSelection.claim('),
          lessThan(source.indexOf('await requireSecurityAdmission();')));
    }
  });
}
