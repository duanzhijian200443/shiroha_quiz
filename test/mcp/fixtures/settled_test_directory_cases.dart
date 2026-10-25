import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

import 'settled_test_directory.dart';

void settledTestDirectoryCases() {
  group('settled test directory', () {
    late Directory root;
    setUp(() async {
      final parent = await Directory(p.absolute('.dart_tool/cleanup-tests'))
          .create(recursive: true);
      root = await parent.createTemp('case-');
    });
    tearDown(() async {
      if (await root.exists()) await root.delete(recursive: true);
    });

    test('does not delete before original settlement', () async {
      final settled = Completer<void>();
      var deletes = 0;
      final cleanup = deleteSettledTestDirectory(root, settled: settled.future,
          remove: () async {
        deletes++;
        await root.delete(recursive: true);
      });
      await Future<void>.value();
      expect(deletes, 0);
      expect(await root.exists(), isTrue);
      settled.complete();
      expect(await cleanup, 0);
      expect(deletes, 1);
    });

    test('failed original settlement forbids deletion and sharing recovery',
        () async {
      final failure = StateError('Original settlement failed');
      var deletes = 0, waits = 0;
      await expectLater(
          deleteSettledTestDirectory(root,
              settled: Future<void>.error(failure),
              remove: () async => deletes++,
              waitForRelease: () async => waits++),
          throwsA(same(failure)));
      expect(deletes, 0);
      expect(waits, 0);
      expect(await root.exists(), isTrue);
    });

    test('sharing recovery waits for release and still requires removal',
        () async {
      final waiting = Completer<void>(), released = Completer<void>();
      var deletes = 0;
      final cleanup = deleteSettledTestDirectory(root,
          settled: Future<void>.value(), windows: true, remove: () async {
        if (++deletes == 1) {
          throw const FileSystemException('sharing', '', OSError('', 32));
        }
        await root.delete(recursive: true);
      }, waitForRelease: () {
        waiting.complete();
        return released.future;
      });
      await waiting.future;
      expect(deletes, 1);
      expect(await root.exists(), isTrue);
      released.complete();
      expect(await cleanup, 1);
      expect(deletes, 2);
      expect(await root.exists(), isFalse);
    });

    test('persistent sharing fails with the original error at the fixed bound',
        () async {
      final first =
          FileSystemException('first sharing', '', const OSError('', 32));
      var deletes = 0, waits = 0;
      await expectLater(
          deleteSettledTestDirectory(root,
              settled: Future<void>.value(),
              windows: true,
              remove: () async {
                if (++deletes == 1) throw first;
                throw const FileSystemException(
                    'later sharing', '', OSError('', 32));
              },
              waitForRelease: () async => waits++),
          throwsA(same(first)));
      expect(deletes, 21);
      expect(waits, 20);
      expect(await root.exists(), isTrue);
    });

    for (final (windows, code) in [(true, 5), (true, 145), (false, 32)]) {
      test('does not retry windows=$windows error=$code', () async {
        final failure = FileSystemException('failure', '', OSError('', code));
        var deletes = 0, waits = 0;
        await expectLater(
            deleteSettledTestDirectory(root,
                settled: Future<void>.value(),
                windows: windows,
                remove: () async {
                  deletes++;
                  throw failure;
                },
                waitForRelease: () async => waits++),
            throwsA(same(failure)));
        expect(deletes, 1);
        expect(waits, 0);
        expect(await root.exists(), isTrue);
      });
    }

    test('a reported delete without actual removal cannot pass', () async {
      await expectLater(
          deleteSettledTestDirectory(root,
              settled: Future<void>.value(), remove: () async {}),
          throwsStateError);
      expect(await root.exists(), isTrue);
    });

    test(
        'real Windows handle reproduces sharing and explicit release closes it',
        () async {
      final file =
          await File(p.join(root.path, 'held.bin')).writeAsString('test');
      final holder = await Process.start(
          'pwsh.exe',
          [
            '-NoProfile',
            '-NonInteractive',
            '-File',
            p.absolute('test/mcp/fixtures/windows_sharing_fixture.ps1'),
            '-TargetFile',
            file.path
          ],
          includeParentEnvironment: false,
          environment: {
            for (final e in Platform.environment.entries)
              if (const {'SYSTEMROOT', 'WINDIR', 'PATH', 'TEMP', 'TMP'}
                  .contains(e.key.toUpperCase()))
                e.key: e.value,
          });
      final lines = StreamIterator(holder.stdout
          .transform(utf8.decoder)
          .transform(const LineSplitter()));
      final errors = holder.stderr.drain<void>();
      Future<void>? releasing;
      Future<void> release() => releasing ??= () async {
            holder.stdin.writeln('release');
            await holder.stdin.close();
            expect(await lines.moveNext().timeout(const Duration(seconds: 5)),
                isFalse);
            expect(
                await holder.exitCode.timeout(const Duration(seconds: 5)), 0);
            await errors;
            await lines.cancel();
          }();
      addTearDown(release);
      expect(
          await lines.moveNext().timeout(const Duration(seconds: 5)), isTrue);
      expect(lines.current, 'held');
      // Reproduce the original single-delete assumption with a known holder.
      await expectLater(
          root.delete(recursive: true),
          throwsA(isA<FileSystemException>()
              .having((e) => e.osError?.errorCode, 'sharing violation', 32)));
      expect(
          await deleteSettledTestDirectory(root,
              settled: Future<void>.value(), waitForRelease: release),
          1);
      expect(await root.exists(), isFalse);
    }, skip: !Platform.isWindows);
  });
}
