import 'package:shiroha_quiz/application/content/content_asset_authority.dart';
import 'package:shiroha_quiz/data/models/ai_engine_profile.dart';
import 'package:shiroha_quiz/services/backup/sha256.dart';
import 'package:shiroha_quiz/services/import_pipeline/ocr_document.dart';
import 'package:shiroha_quiz/services/import_pipeline/ocr_document_client.dart';
import 'package:shiroha_quiz/services/import_pipeline/ocr_question_regionizer.dart';
import 'package:shiroha_quiz/services/import_pipeline/reference_answer_extractor.dart';
import 'package:shiroha_quiz/services/import_pipeline/reference_answer_merger.dart';

import 'train_c_runtime_evidence_source.dart';

final class TrainCL1BSourceObservationException implements Exception {
  const TrainCL1BSourceObservationException([
    this.code = 'TRAIN_C_IMAGE_CLOSURE_FAILURE',
  ]);

  final String code;

  @override
  String toString() => code;
}

/// Transparent same-parse observer around the real production OCR client.
///
/// It captures only the returned typed [OcrDocument] object after production
/// has already materialized provider responses and crop bytes. The document is
/// returned unchanged to [OcrImportService]. No HTTP body, request body, URL,
/// API key or raw provider payload is inspected here.
final class TrainCL1BObservingOcrClient implements OcrDocumentClient {
  TrainCL1BObservingOcrClient(this.delegate);

  final OcrDocumentClient delegate;
  OcrDocument? _document;
  int _parseCount = 0;

  @override
  String get modelId => delegate.modelId;

  int get parseCount => _parseCount;

  OcrDocument get observedDocument {
    final document = _document;
    if (document == null || _parseCount != 1) {
      throw const TrainCL1BSourceObservationException(
        'TRAIN_C_PENDING_REVIEW_FAILURE',
      );
    }
    return document;
  }

  @override
  Future<OcrDocument> parseFile({
    required AiEngineProfile profile,
    required String filePath,
    required String sourceName,
    Duration timeout = const Duration(minutes: 8),
  }) async {
    _parseCount++;
    if (_parseCount != 1) {
      throw const TrainCL1BSourceObservationException(
        'TRAIN_C_PROVIDER_REQUEST_COUNT_FAILURE',
      );
    }
    final document = await delegate.parseFile(
      profile: profile,
      filePath: filePath,
      sourceName: sourceName,
      timeout: timeout,
    );
    _document = document;
    return document;
  }
}

final class TrainCL1BSourceObservation {
  const TrainCL1BSourceObservation({
    required this.sourceImages,
    required this.blockCount,
    required this.imageBlockCount,
    required this.tableBlockCount,
    required this.referencedTableBlockCount,
  });

  final TrainCSourceImageFacts sourceImages;
  final int blockCount;
  final int imageBlockCount;
  final int tableBlockCount;
  final int referencedTableBlockCount;
}

/// Replays only deterministic production source-ownership logic over the exact
/// [OcrDocument] returned by the same real parse. This is independent of the
/// typed database state: image bytes/hashes and block placement come from the
/// source document, while [retainedLease] contributes only the generated
/// source namespace needed to compare source and durable identities.
TrainCL1BSourceObservation buildTrainCL1BSourceObservation({
  required OcrDocument document,
  required ContentAssetCandidateLease retainedLease,
  required Set<int> acceptedQuestionNumbers,
  OcrQuestionRegionizer regionizer = const OcrQuestionRegionizer(),
  ReferenceAnswerExtractor referenceAnswerExtractor =
      const ReferenceAnswerExtractor(),
  ReferenceAnswerMerger referenceAnswerMerger = const ReferenceAnswerMerger(),
}) {
  if (acceptedQuestionNumbers.isEmpty ||
      retainedLease.sourceId.trim().isEmpty ||
      retainedLease.localAssetIds.isEmpty) {
    throw const TrainCL1BSourceObservationException();
  }

  final flattened = document.flattenedBlocks;
  final blocksById = <String, OcrBlock>{};
  for (final block in flattened) {
    if (block.blockId.trim().isEmpty || blocksById.containsKey(block.blockId)) {
      throw const TrainCL1BSourceObservationException();
    }
    blocksById[block.blockId] = block;
  }

  final regionized = regionizer.regionize(document);
  final referenceIndex = referenceAnswerExtractor.extract(
    document,
    regionized.regions,
  );
  final merged = referenceAnswerMerger.merge(
    regionized.regions,
    referenceIndex,
  );

  final regionsByNumber = <int, OcrQuestionRegion>{};
  for (final region in merged) {
    if (!acceptedQuestionNumbers.contains(region.number)) continue;
    if (regionsByNumber.containsKey(region.number)) {
      throw const TrainCL1BSourceObservationException(
        'TRAIN_C_NUMBERING_FAILURE',
      );
    }
    regionsByNumber[region.number] = region;
  }
  if (regionsByNumber.length != acceptedQuestionNumbers.length ||
      !regionsByNumber.keys.toSet().containsAll(acceptedQuestionNumbers)) {
    throw const TrainCL1BSourceObservationException(
      'TRAIN_C_NUMBERING_FAILURE',
    );
  }

  final evidence = <TrainCPreTypedSourceImageEvidence>[];
  final counts = <int, int>{};
  final identitiesByQuestion = <int, Set<(String, String)>>{};
  var referencedTableBlockCount = 0;

  final sortedNumbers = acceptedQuestionNumbers.toList()..sort();
  for (final questionNumber in sortedNumbers) {
    final region = regionsByNumber[questionNumber]!;
    var imageOrder = 0;
    final questionIdentities = <(String, String)>{};
    final seenStructuralBlocks = <String>{};

    for (final owned in region.ownedSources) {
      final block = blocksById[owned.blockId];
      if (block == null) {
        throw const TrainCL1BSourceObservationException();
      }
      final type = block.type.trim().toLowerCase();
      if (type != 'image' && type != 'figure' && type != 'table') continue;
      if (!seenStructuralBlocks.add(block.blockId)) {
        throw const TrainCL1BSourceObservationException();
      }

      if (type == 'table') {
        referencedTableBlockCount++;
        continue;
      }

      final payload = block.imagePayload;
      if (payload == null || payload.bytes.isEmpty) {
        throw const TrainCL1BSourceObservationException();
      }
      final identity = (retainedLease.sourceId, block.blockId);
      if (!questionIdentities.add(identity)) {
        throw const TrainCL1BSourceObservationException();
      }
      evidence.add(
        TrainCPreTypedSourceImageEvidence(
          questionNumber: questionNumber,
          sourceId: retainedLease.sourceId,
          blockId: block.blockId,
          localAssetId: block.blockId,
          contentHash: sha256Hex(payload.bytes),
          // The trusted closure contract uses canonical per-question encounter
          // order, not the absolute page-level OCR reading-order integer.
          readingOrder: imageOrder++,
        ),
      );
    }

    counts[questionNumber] = imageOrder;
    identitiesByQuestion[questionNumber] = questionIdentities;
  }

  final observedAssetIds = evidence.map((item) => item.localAssetId).toSet();
  final retainedAssetIds = retainedLease.localAssetIds.toSet();
  if (observedAssetIds.length != evidence.length ||
      retainedAssetIds.length != retainedLease.localAssetIds.length ||
      observedAssetIds.length != retainedAssetIds.length ||
      !observedAssetIds.containsAll(retainedAssetIds)) {
    throw const TrainCL1BSourceObservationException();
  }

  var imageBlockCount = 0;
  var tableBlockCount = 0;
  for (final block in flattened) {
    switch (block.type.trim().toLowerCase()) {
      case 'image':
      case 'figure':
        imageBlockCount++;
      case 'table':
        tableBlockCount++;
    }
  }

  return TrainCL1BSourceObservation(
    sourceImages: TrainCSourceImageFacts(
      referencedImageCounts: counts,
      referencedIdentitiesByQuestion: identitiesByQuestion,
      orderedEvidence: evidence,
    ),
    blockCount: flattened.length,
    imageBlockCount: imageBlockCount,
    tableBlockCount: tableBlockCount,
    referencedTableBlockCount: referencedTableBlockCount,
  );
}
