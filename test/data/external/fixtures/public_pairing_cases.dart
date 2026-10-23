import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:shiroha_quiz/data/external/windows_pairing.dart';
import 'package:shiroha_quiz/application/external/first_party_external_credentials.dart';
import '../../../mcp/fixtures/codex_app_server_support.dart'
    show flutterDartExecutable;
import '../windows_pairing_test.dart' show PairingHarness;
import '../bootstrap_test_support.dart' show vectorBytes;
import 'public_pairing_process_support.dart';

void publicPairingCases(PairingHarness Function() current) {
  group('independent public exports', () {
    test('close drains late Submission input and cannot publish a challenge',
        () async {
      final h = current();
      final input = Completer<Uint8List>();
      final reached = Completer<void>();
      final app = WindowsAppPublicPairingHandoff(
          owner: h.app,
          submissionId: () {
            reached.complete();
            return input.future;
          });
      final opening = app.request(h.local.reference);
      final rejected = expectLater(opening, throwsA(anything));
      await reached.future;
      final closing = app.close();
      expect(identical(closing, app.close()), isTrue);
      var done = false;
      final observed = closing.then((_) => done = true);
      await Future<void>.value();
      expect(done, isFalse);
      input.complete(Uint8List(16));
      await rejected;
      await observed;
      expect(h.native.calls.exchangeFiles.keys.any((k) => k.$1 == 2), isFalse);
      await expectLater(app.request(h.local.reference), throwsA(anything));
    });
    for (final mode in [
      'foreign',
      'duplicate',
      'expired',
      'close',
      'pending-completion'
    ]) {
      test('App public handoff $mode refuses and cannot revive', () async {
        final h = current();
        h.begin();
        final id = h.enrollment.submissionId;
        final app = WindowsAppPublicPairingHandoff(
            owner: h.app, submissionId: () async => id);
        addTearDown(app.close);
        await app.request(h.local.reference);
        final bytes = await app.exportTrust(id);
        expect(
            PairingPublicExport.decodeTrust(bytes, id).issuerDer, isNotEmpty);
        switch (mode) {
          case 'foreign':
            await expectLater(
                app.exportTrust(Uint8List(16)), throwsA(anything));
          case 'duplicate':
            await expectLater(
                app.request(h.local.reference), throwsA(anything));
          case 'expired':
            h.elapsed += const Duration(minutes: 11);
            await expectLater(app.exportTrust(id), throwsA(anything));
          case 'close':
            await app.close();
          case 'pending-completion':
            await expectLater(app.exportCompletion(id), throwsA(anything));
        }
        await expectLater(app.exportTrust(id), throwsA(anything));
      });
    }

    test(
        'public decoder rejects wrong identity, kind, version and extra fields',
        () {
      final id = Uint8List(16);
      final bytes = PairingPublicExport.encodeTrust(
          id,
          BridgeAppPublicMaterial(
              issuerDer: vectorBytes('issuerDer'),
              serverLeafDigest: Uint8List(32)));
      final fields = jsonDecode(utf8.decode(bytes)) as List;
      for (final data in [
        [...fields, 'extra'],
        [1.0, ...fields.skip(1)],
        [2, ...fields.skip(1)],
        [1, 'completion', ...fields.skip(2)],
        [1, 'trust', 'foreign', ...fields.skip(3)]
      ]) {
        expect(
            () => PairingPublicExport.decodeTrust(
                Uint8List.fromList(utf8.encode(jsonEncode(data))), id),
            throwsFormatException);
      }
      expect(() => PairingPublicExport.decodeTrust(Uint8List(4097), id),
          throwsFormatException);
      for (final revision in [0, 2147483648]) {
        expect(
            () => PairingPublicExport.encodeCompletion(id,
                FirstPartyPairingDisplay(revision: revision, digest: 'a' * 64)),
            throwsFormatException);
      }
    });

    test(
        'independent Windows Bridge completes original App request through public exports',
        () async {
      final h = current();
      final root =
          await Directory(p.absolute('.dart_tool/public-pairing-tests'))
              .create(recursive: true);
      final temp = await root.createTemp('independent-');
      Process? child;
      Future<int>? exit;
      Future<void>? output, errors;
      final diagnostic = StringBuffer();
      addTearDown(() async {
        if (child != null) {
          child.kill(); // Failure-only owned process cleanup; never PID lookup.
          await exit;
          await Future.wait([output!, errors!]);
          await File(p.join(root.path, 'worker-diagnostic.log'))
              .writeAsString(diagnostic.toString());
        }
        await temp.delete(recursive: true);
      });
      final dart = flutterDartExecutable();
      final snapshot = p.join(
          p.dirname(p.dirname(p.dirname(dart))), 'flutter_tools.snapshot');
      child = await Process.start(
          dart,
          [
            snapshot,
            'test',
            '--concurrency=1',
            '--no-pub',
            'test/data/external/windows_public_pairing_worker_test.dart'
          ],
          includeParentEnvironment: false,
          environment: {
            for (final entry in Platform.environment.entries)
              if (const {
                'SYSTEMROOT',
                'WINDIR',
                'PATH',
                'PATHEXT',
                'TEMP',
                'TMP',
                'USERPROFILE',
                'APPDATA',
                'LOCALAPPDATA',
                'PROGRAMFILES',
                'PROGRAMFILES(X86)',
                'PROGRAMW6432',
                'COMSPEC',
                'SYSTEMDRIVE',
                'PROCESSOR_ARCHITECTURE'
              }.contains(entry.key.toUpperCase()))
                entry.key: entry.value,
            'SHIROHA_PUBLIC_PAIRING_TEST': temp.path,
          });
      exit = child.exitCode;
      void capture(String value) {
        if (diagnostic.length < 16384) diagnostic.write(value);
      }

      output =
          child.stdout.transform(utf8.decoder).listen(capture).asFuture<void>();
      errors =
          child.stderr.transform(utf8.decoder).listen(capture).asFuture<void>();
      final id = await (await waitPublicFile(temp, 'submission')).readAsBytes();
      await importExchange(h, temp, 'submission.exchange');
      final app = WindowsAppPublicPairingHandoff(
          owner: h.app, submissionId: () async => id);
      addTearDown(app.close);
      final request = await app.request(h.local.reference);
      await publishPublic(temp, 'trust', await app.exportTrust(id));
      await exportExchange(h, temp, 'challenge.exchange');
      final displayed = await request.display();
      final ready = await waitPublicFile(temp, 'initial-ready');
      expect(await ready.readAsString(), displayed.digest);
      expect(h.native.calls.exchangeFiles.keys.any((k) => k.$1 == 3), isFalse);
      await publishPublic(
          temp, 'confirm-initial', utf8.encode(displayed.digest!));
      await importExchange(h, temp, 'proof.exchange');
      await request.approve();
      await request.complete();
      final actual = await request.display();
      await publishPublic(temp, 'completion', await app.exportCompletion(id));
      await waitPublicFile(temp, 'completion-ready');
      await publishPublic(temp, 'confirm-completion',
          utf8.encode(jsonEncode([actual.revision, actual.digest])));
      await waitPublicFile(temp, 'finished');
      expect(await exit.timeout(const Duration(seconds: 20)), 0);
      await Future.wait([output, errors]);
      child = null;
      await app.close();
      await expectLater(app.exportCompletion(id), throwsA(anything));
    },
        skip: Platform.isWindows ? false : 'Windows process evidence only',
        timeout: const Timeout(Duration(minutes: 2)));
  });
}
