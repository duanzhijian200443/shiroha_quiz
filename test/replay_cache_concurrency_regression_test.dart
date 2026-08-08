import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:shiroha_quiz/services/import_pipeline/ocr_document.dart';

import '../tool/import_acceptance.dart';

const _pdfHash =
    'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa';
const _fpOld = '1111111111111111';
const _fpA = '2222222222222222';
const _fpB = '3333333333333333';

const _docOld = OcrDocument(
  sourceName: 'old.pdf',
  markdown: 'old',
  usage: {},
  rawResponses: [],
  pages: [
    OcrPage(
      pageIndex: 1,
      blocks: [
        OcrBlock(
          blockId: 'old-b1',
          pageIndex: 1,
          type: 'text',
          text: 'old question',
          bbox: [],
          readingOrder: 0,
        ),
      ],
    ),
  ],
);

const _docA = OcrDocument(
  sourceName: 'a.pdf',
  markdown: 'a',
  usage: {},
  rawResponses: [],
  pages: [
    OcrPage(
      pageIndex: 1,
      blocks: [
        OcrBlock(
          blockId: 'a-b1',
          pageIndex: 1,
          type: 'text',
          text: 'question A',
          bbox: [],
          readingOrder: 0,
        ),
      ],
    ),
  ],
);

const _docB = OcrDocument(
  sourceName: 'b.pdf',
  markdown: 'b',
  usage: {},
  rawResponses: [],
  pages: [
    OcrPage(
      pageIndex: 1,
      blocks: [
        OcrBlock(
          blockId: 'b-b1',
          pageIndex: 1,
          type: 'text',
          text: 'question B',
          bbox: [],
          readingOrder: 0,
        ),
      ],
    ),
  ],
);

class _NoOpReplayCacheWriteLock implements ReplayCacheWriteLock {
  @override
  void lockSync() {}

  @override
  void unlockSync() {}

  @override
  void closeSync() {}
}

void main() {
  group('Replay cache concurrent writer regression', () {
    late Directory tempRepo;

    setUp(() {
      tempRepo = Directory.systemTemp.createTempSync('replay_cache_race_');
    });

    tearDown(() {
      if (tempRepo.existsSync()) {
        tempRepo.deleteSync(recursive: true);
      }
    });

    test('a complete newer publication may supersede post-write self-test', () {
      const caseId = 'supersede_self_test';

      expect(
        () => writeReplayCache(
          caseId: caseId,
          repositoryRoot: tempRepo.path,
          document: _docA,
          fingerprint: _fpA,
          pdfContentHash: _pdfHash,
          hooks: ReplayCacheWriteHooks(
            afterCurrentPublished: () {
              writeReplayCache(
                caseId: caseId,
                repositoryRoot: tempRepo.path,
                document: _docB,
                fingerprint: _fpB,
                pdfContentHash: _pdfHash,
                lockFactory: (_) => _NoOpReplayCacheWriteLock(),
              );
            },
          ),
        ),
        returnsNormally,
      );

      final loaded = loadReplayCache(
        caseId: caseId,
        repositoryRoot: tempRepo.path,
      );
      expect(loaded.isLoaded, isTrue);
      expect(loaded.fingerprint, _fpB);
    });

    test('a failed superseded writer never restores over the newer current', () {
      const caseId = 'superseded_rollback';

      writeReplayCache(
        caseId: caseId,
        repositoryRoot: tempRepo.path,
        document: _docOld,
        fingerprint: _fpOld,
        pdfContentHash: _pdfHash,
      );

      expect(
        () => writeReplayCache(
          caseId: caseId,
          repositoryRoot: tempRepo.path,
          document: _docA,
          fingerprint: _fpA,
          pdfContentHash: _pdfHash,
          hooks: ReplayCacheWriteHooks(
            afterCurrentPublished: () {
              writeReplayCache(
                caseId: caseId,
                repositoryRoot: tempRepo.path,
                document: _docB,
                fingerprint: _fpB,
                pdfContentHash: _pdfHash,
                lockFactory: (_) => _NoOpReplayCacheWriteLock(),
              );
            },
            beforePostWriteVerification: () =>
                throw const FileSystemException('fixture'),
          ),
        ),
        throwsA(isA<FileSystemException>()),
      );

      final loaded = loadReplayCache(
        caseId: caseId,
        repositoryRoot: tempRepo.path,
      );
      expect(loaded.isLoaded, isTrue);
      expect(loaded.fingerprint, _fpB);
    });
  });
}
