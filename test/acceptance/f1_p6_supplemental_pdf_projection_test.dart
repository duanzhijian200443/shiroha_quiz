// F1 -> P6 synthetic PDF integration.
//
// Synthetic fixture only: a generated PDF whose lines carry the answer-document
// structures this closure targets (bracket locators, explicit answers, derived
// solution blocks, context labels), plus a second fixture whose one visual
// answer line is preserved as several ordered text runs the way a real PDF text
// layer does. No private document, no OCR, no network.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:shiroha_quiz/application/parsed_artifacts/parsed_artifact_lifecycle.dart';
import 'package:shiroha_quiz/application/supplemental_answers/supplemental_answer_matcher.dart';
import 'package:shiroha_quiz/application/supplemental_answers/supplemental_answer_projector.dart';
import 'package:shiroha_quiz/application/supplemental_answers/target_question_snapshot_service.dart';
import 'package:shiroha_quiz/domain/answers/answer_candidate.dart';
import 'package:shiroha_quiz/domain/assets/library_file.dart';
import 'package:shiroha_quiz/domain/content/content_node.dart';
import 'package:shiroha_quiz/domain/content/rich_content.dart';
import 'package:shiroha_quiz/domain/question/question_draft_v2.dart';
import 'package:shiroha_quiz/domain/source/source_part.dart';
import 'package:shiroha_quiz/domain/source/source_ref.dart';
import 'package:shiroha_quiz/domain/supplemental_answers/answer_match_record.dart';
import 'package:shiroha_quiz/domain/supplemental_answers/supplemental_answer_fragment.dart';
import 'package:shiroha_quiz/domain/supplemental_answers/target_coverage.dart';
import 'package:shiroha_quiz/services/file_library/managed_file_storage_adapter.dart';
import 'package:shiroha_quiz/services/parsed_artifacts/deterministic_parsed_artifact_generation_adapter.dart';
import 'package:syncfusion_flutter_pdf/pdf.dart';

const _sha256 =
    'ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad';

const _fixtureLines = <String>[
  '(1)【答案】C',
  '【解】reason-one',
  '(2)【答案】B',
  '【解】reason-two',
  '(15)【解】',
  'step-a',
  'step-b',
  '(18)(I)【证明】',
  'proof-a',
  '(II)【解】',
  'solution-b',
];

/// Choice questions whose answer line is fragmented across text runs.
const _fragmentedChoiceAnswers = <String, String>{
  '1': 'C',
  '2': 'B',
  '3': 'D',
  '4': 'A',
  '5': 'C',
  '6': 'B',
  '7': 'D',
  '8': 'A',
};

/// Fill questions whose explicit answer content is fragmented across runs.
const _fragmentedContentAnswers = <String, String>{
  '9': 'x = 1',
  '10': 'y = 2',
  '11': 'z = 3',
  '12': 'w = 4',
  '13': 'v = 5',
  '14': 'u = 6',
};

/// A document title whose leading year must never become a question locator.
const _fragmentedTitle = '2019年数学(一)真题解析';

/// The Q6 shape: the explicit choice token itself is split across two runs and
/// is followed by marker-less prose that no field marker ever opened.
const _splitTokenResidual = 'marker-less solution prose';

/// A token kept in one run whose answer line still ends in marker-less prose.
const _trailingResidual = 'textbook prose';

void main() {
  late Directory tempDir;
  late ManagedFileStorageAdapter storage;
  late DeterministicParsedArtifactGenerationAdapter adapter;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('f1_p6_pdf_');
    storage = ManagedFileStorageAdapter(managedRoot: tempDir);
    adapter = DeterministicParsedArtifactGenerationAdapter(
      managedFileStorage: storage,
    );
  });

  tearDown(() async {
    if (await tempDir.exists()) {
      await tempDir.delete(recursive: true);
    }
  });

  test('synthetic answer PDF projects one fragment per bracket question',
      () async {
    final source = await _seedPdf(storage: storage, tempDir: tempDir);
    final plan = await adapter.resolvePlan(
      file: source,
      options: const ParsedArtifactParseOptions(
        routeSelection: ParsedArtifactRouteSelection.auto,
      ),
    );
    expect(plan.parserRoute, 'pdf_text');

    final document = await adapter.generate(
      file: source,
      artifactId: 'artifact-answers',
      plan: plan,
    );

    final projection = const SupplementalAnswerProjector().project(document);
    final byNumber = <String?, SupplementalAnswerFragment>{
      for (final fragment in projection.fragments)
        fragment.normalizedMainNumber: fragment,
    };
    expect(
      projection.fragments.map((fragment) => fragment.normalizedMainNumber),
      ['1', '2', '15', '18'],
    );

    final first = byNumber['1']!;
    expect(first.source, SupplementalAnswerSource.explicitAnswer);
    expect(_texts(first.answerContent).join(), contains('C'));
    final firstExplanation = _texts(first.explanationContent!).join();
    expect(firstExplanation, contains('reason-one'));
    expect(firstExplanation, isNot(contains('C\n')));

    expect(_texts(byNumber['2']!.answerContent).join(), contains('B'));

    final fifteenth = byNumber['15']!;
    expect(fifteenth.source, SupplementalAnswerSource.solutionBlock);
    final solution = _texts(fifteenth.answerContent).join();
    expect(solution, contains('step-a'));
    expect(solution, contains('step-b'));

    final eighteenth = byNumber['18']!;
    expect(eighteenth.source, SupplementalAnswerSource.solutionBlock);
    final contextContent = _texts(eighteenth.answerContent).join();
    expect(contextContent, contains('proof-a'));
    expect(contextContent, contains('solution-b'));
    expect(
      projection.fragments
          .where((fragment) => fragment.normalizedMainNumber == '18'),
      hasLength(1),
    );
  });

  test('a fragmented answer PDF recovers every explicit answer', () async {
    final source = await _seedFragmentedPdf(
      storage: storage,
      tempDir: tempDir,
    );
    final plan = await adapter.resolvePlan(
      file: source,
      options: const ParsedArtifactParseOptions(
        routeSelection: ParsedArtifactRouteSelection.auto,
      ),
    );
    expect(plan.parserRoute, 'pdf_text');

    final document = await adapter.generate(
      file: source,
      artifactId: 'artifact-fragmented',
      plan: plan,
    );

    // The fixture must really be fragmented: one visual answer line has to
    // arrive as several ordered parts, otherwise this proves nothing.
    expect(
      document.parts.length,
      greaterThan(5 *
          (_fragmentedChoiceAnswers.length + _fragmentedContentAnswers.length)),
    );
    expect(
      document.parts
          .whereType<SourceContentPart>()
          .map((part) => _texts(part.content).join())
          .where((text) => text.trim() == '答案')
          .length,
      14,
      reason: 'each answer marker must sit in its own run',
    );

    final projection = const SupplementalAnswerProjector().project(document);
    expect(
      projection.fragments.map((fragment) => fragment.normalizedMainNumber),
      <String>[for (var number = 1; number <= 14; number++) '$number'],
    );
    expect(
      projection.fragments.map((fragment) => fragment.source),
      everyElement(SupplementalAnswerSource.explicitAnswer),
    );
    expect(
      projection.issues.map((issue) => issue.kind),
      isNot(
        contains(SupplementalProjectionIssueKind.contentAdmissionRejected),
      ),
    );

    final result = const SupplementalAnswerMatcher().match(
      fragments: projection.fragments,
      snapshot: _fragmentedTargetSnapshot(),
      artifact: const SupplementalArtifactContext(
        supplementalFileId: 'file-fragmented',
        artifactId: 'artifact-fragmented',
        artifactRevision: 1,
      ),
    );

    expect(result.records, hasLength(14));
    expect(
      result.records.map((record) => record.disposition),
      everyElement(AnswerMatchDisposition.matched),
    );
    int countOf(AnswerMatchDisposition disposition) {
      return result.records
          .where((record) => record.disposition == disposition)
          .length;
    }

    expect(countOf(AnswerMatchDisposition.invalid), 0);
    expect(countOf(AnswerMatchDisposition.unmatched), 0);
    expect(countOf(AnswerMatchDisposition.ambiguous), 0);
    expect(countOf(AnswerMatchDisposition.conflict), 0);
    expect(
      result.records.map((record) => record.candidate!.writeIntent),
      everyElement(CandidateWriteIntent.fill),
    );
    expect(
      result.coverage
          .where((entry) => entry.status == TargetCoverageStatus.covered),
      hasLength(14),
    );

    final byTarget = <String, AnswerMatchRecord>{
      for (final record in result.records)
        record.candidate!.targetStorageId: record,
    };
    _fragmentedChoiceAnswers.forEach((number, letter) {
      final answer = byTarget['q_$number']!.candidate!.answer;
      expect(
        answer,
        isA<ChoiceAnswer>(),
        reason: 'question $number must become a typed choice answer',
      );
      expect(
        (answer as ChoiceAnswer).optionIds,
        <String>['q_${number}_opt_${letter.toLowerCase()}'],
        reason: 'the fragmented token ($letter). must normalize to $letter',
      );
    });
    _fragmentedContentAnswers.forEach((number, content) {
      final answer = byTarget['q_$number']!.candidate!.answer;
      expect(answer, isA<ContentAnswer>(), reason: 'question $number');
      expect(
        _texts((answer as ContentAnswer).content).join().trim(),
        content,
        reason: 'question $number must keep its explicit content answer',
      );
    });
  });

  test('a Q6-shaped fragmented explicit token seals to one choice answer',
      () async {
    final source = await _seedQ6Pdf(storage: storage, tempDir: tempDir);
    final plan = await adapter.resolvePlan(
      file: source,
      options: const ParsedArtifactParseOptions(
        routeSelection: ParsedArtifactRouteSelection.auto,
      ),
    );
    expect(plan.parserRoute, 'pdf_text');

    final document = await adapter.generate(
      file: source,
      artifactId: 'artifact-q6',
      plan: plan,
    );

    final projection = const SupplementalAnswerProjector().project(document);
    final byNumber = <String?, SupplementalAnswerFragment>{
      for (final fragment in projection.fragments)
        fragment.normalizedMainNumber: fragment,
    };
    expect(
      projection.fragments.map((fragment) => fragment.normalizedMainNumber),
      ['6', '7'],
    );

    final sixth = byNumber['6']!;
    // The projector keeps the complete answer line; nothing is truncated to
    // fit a seal candidate. The text layer also splits the break between runs
    // into its own part, so the token itself spans three ordered parts.
    expect(_answerTexts(sixth.answerContent), [
      '(',
      'A).',
      _splitTokenResidual,
    ]);
    final evidence = sixth.answerPartEvidence;
    expect(evidence, hasLength(6));
    expect(
      evidence.map((segment) => segment.partIndex).toList(),
      <int>[
        for (var index = 0; index < evidence.length; index++)
          evidence[0].partIndex + index,
      ],
      reason: 'the whole answer line came from consecutive source parts',
    );
    expect(
      evidence
          .map((segment) => (segment.answerNodeStart, segment.answerNodeEnd))
          .toList(),
      <(int, int)>[
        for (var index = 0; index < evidence.length; index++) (index, index + 1)
      ],
    );
    expect(
      evidence.first.sourceRef,
      same(document.parts[evidence.first.partIndex].sourceRef),
    );

    final result = const SupplementalAnswerMatcher().match(
      fragments: projection.fragments,
      snapshot: _q6TargetSnapshot(),
      artifact: const SupplementalArtifactContext(
        supplementalFileId: 'file-q6',
        artifactId: 'artifact-q6',
        artifactRevision: 1,
      ),
    );

    expect(result.records, hasLength(2));
    expect(
      result.records.map((record) => record.disposition),
      everyElement(AnswerMatchDisposition.matched),
    );
    expect(
      result.records.map((record) => record.candidate!.writeIntent),
      everyElement(CandidateWriteIntent.fill),
    );

    final sixthCandidate = result.records
        .singleWhere((record) => record.candidate!.targetStorageId == 'q_6')
        .candidate!;
    expect((sixthCandidate.answer as ChoiceAnswer).optionIds, ['q_6_opt_a']);
    expect(sixthCandidate.reviewOnlyExplanation, isNull);
    // Only the three runs that really proved `(A).` are answer provenance; the
    // three marker-less residual runs are neither answer nor explanation. The
    // text adapter binds every part to one document-level ref, so the number
    // and order of provenance entries is the observable proof here.
    expect(_originRefs(sixthCandidate), hasLength(3));
    expect(_originRefs(sixthCandidate), <SourceRef>[
      evidence[0].sourceRef,
      evidence[1].sourceRef,
      evidence[2].sourceRef,
    ]);

    final seventh = byNumber['7']!;
    expect(_answerTexts(seventh.answerContent), [
      '(C).',
      _trailingResidual,
    ]);
    final seventhEvidence = seventh.answerPartEvidence;
    expect(seventhEvidence, hasLength(5));
    expect(
      seventhEvidence.map((segment) => segment.partIndex).toList(),
      <int>[
        for (var index = 0; index < seventhEvidence.length; index++)
          seventhEvidence[0].partIndex + index,
      ],
    );
    final seventhCandidate = result.records
        .singleWhere((record) => record.candidate!.targetStorageId == 'q_7')
        .candidate!;
    expect((seventhCandidate.answer as ChoiceAnswer).optionIds, ['q_7_opt_c']);
    expect(seventhCandidate.reviewOnlyExplanation, isNull);
    expect(_originRefs(seventhCandidate), hasLength(2));
    expect(_originRefs(seventhCandidate), <SourceRef>[
      seventhEvidence[0].sourceRef,
      seventhEvidence[1].sourceRef,
    ]);
  });
}

TargetQuestionSnapshot _fragmentedTargetSnapshot() {
  return TargetQuestionSnapshot(
    targets: <AnswerTargetReference>[
      for (final number in _fragmentedChoiceAnswers.keys)
        _syntheticTarget(number: number, kind: QuestionKind.singleChoice),
      for (final number in _fragmentedContentAnswers.keys)
        _syntheticTarget(number: number, kind: QuestionKind.fillBlank),
    ],
    reports: const <TargetScopeReport>[],
  );
}

AnswerTargetReference _syntheticTarget({
  required String number,
  required QuestionKind kind,
}) {
  final storageId = 'q_$number';
  return AnswerTargetReference(
    storageId: storageId,
    bankName: 'bank_math',
    draft: QuestionDraftV2(
      questionId: storageId,
      kind: kind,
      questionNumber: int.parse(number),
      stem: _text('synthetic stem $number'),
      options: kind == QuestionKind.singleChoice
          ? <QuestionOption>[
              for (final label in const <String>['A', 'B', 'C', 'D'])
                QuestionOption(
                  optionId: '${storageId}_opt_${label.toLowerCase()}',
                  label: label,
                  content: _text('$label option'),
                ),
            ]
          : const <QuestionOption>[],
    ),
  );
}

Future<LibraryFile> _seedFragmentedPdf({
  required ManagedFileStorageAdapter storage,
  required Directory tempDir,
}) async {
  final bytes = _buildFragmentedAnswersPdf();
  final fixture = File(p.join(tempDir.path, 'fragmented_answers_fixture.pdf'));
  await fixture.writeAsBytes(bytes);
  await storage.copyIntoManagedStorage(
    externalPath: fixture.path,
    storageKey: 'library/file-fragmented',
  );
  await fixture.delete();
  return LibraryFile(
    fileId: 'file-fragmented',
    displayName: 'fragmented-answers.pdf',
    mimeType: 'application/pdf',
    sizeBytes: bytes.length,
    sha256: _sha256,
    storageKey: 'library/file-fragmented',
    createdAt: DateTime.utc(2026, 9, 28),
  );
}

Future<LibraryFile> _seedQ6Pdf({
  required ManagedFileStorageAdapter storage,
  required Directory tempDir,
}) async {
  final bytes = _buildQ6AnswersPdf();
  final fixture = File(p.join(tempDir.path, 'q6_answers_fixture.pdf'));
  await fixture.writeAsBytes(bytes);
  await storage.copyIntoManagedStorage(
    externalPath: fixture.path,
    storageKey: 'library/file-q6',
  );
  await fixture.delete();
  return LibraryFile(
    fileId: 'file-q6',
    displayName: 'q6-answers.pdf',
    mimeType: 'application/pdf',
    sizeBytes: bytes.length,
    sha256: _sha256,
    storageKey: 'library/file-q6',
    createdAt: DateTime.utc(2026, 9, 29),
  );
}

TargetQuestionSnapshot _q6TargetSnapshot() {
  return TargetQuestionSnapshot(
    targets: <AnswerTargetReference>[
      _syntheticTarget(number: '6', kind: QuestionKind.singleChoice),
      _syntheticTarget(number: '7', kind: QuestionKind.singleChoice),
    ],
    reports: const <TargetScopeReport>[],
  );
}

List<SourceRef> _originRefs(AnswerCandidate candidate) {
  return switch (candidate.origin) {
    SupplementalAnswerOrigin origin => origin.supplementalSourceRefs,
    AiAnswerOrigin() => fail('matcher must produce a supplemental origin'),
  };
}

/// Draws every token of one answer line as its own text run, so the extractor
/// preserves the line as several ordered parts.
List<int> _buildFragmentedAnswersPdf() {
  final document = PdfDocument();
  final font = PdfCjkStandardFont(PdfCjkFontFamily.sinoTypeSongLight, 10);
  document.pages.add().graphics.drawString(_fragmentedTitle, font);

  _fragmentedChoiceAnswers.forEach((number, letter) {
    _drawFragmentedLine(
        document, font, <String>['($number)', '【', '答案', '】', '($letter).']);
  });
  _fragmentedContentAnswers.forEach((number, content) {
    _drawFragmentedLine(
        document, font, <String>['($number)', '【', '答案', '】', content]);
  });

  final bytes = document.saveSync();
  document.dispose();
  return bytes;
}

/// Draws the Q6 shape: one explicit token split across two runs, plus a token
/// that stays in one run while marker-less prose follows it.
List<int> _buildQ6AnswersPdf() {
  final document = PdfDocument();
  final font = PdfCjkStandardFont(PdfCjkFontFamily.sinoTypeSongLight, 10);

  _drawFragmentedLine(
    document,
    font,
    <String>['(6)', '【', '答案', '】', '(', 'A).', _splitTokenResidual],
  );
  _drawFragmentedLine(
    document,
    font,
    <String>['(7)', '【', '答案', '】', '(C).', _trailingResidual],
  );

  final bytes = document.saveSync();
  document.dispose();
  return bytes;
}

void _drawFragmentedLine(
  PdfDocument document,
  PdfCjkStandardFont font,
  List<String> runs,
) {
  final page = document.pages.add();
  var offset = 0.0;
  for (final run in runs) {
    page.graphics
      ..save()
      ..translateTransform(offset, 10)
      ..drawString(run, font)
      ..restore();
    offset += 25;
  }
}

Future<LibraryFile> _seedPdf({
  required ManagedFileStorageAdapter storage,
  required Directory tempDir,
}) async {
  final bytes = _buildAnswersPdf(_fixtureLines);
  final fixture = File(
    p.join(tempDir.path, 'answers_fixture.pdf'),
  );
  await fixture.writeAsBytes(bytes);
  await storage.copyIntoManagedStorage(
    externalPath: fixture.path,
    storageKey: 'library/file-1',
  );
  await fixture.delete();
  return LibraryFile(
    fileId: 'file-1',
    displayName: 'answers.pdf',
    mimeType: 'application/pdf',
    sizeBytes: bytes.length,
    sha256: _sha256,
    storageKey: 'library/file-1',
    createdAt: DateTime.utc(2026, 8, 13),
  );
}

/// One drawn line per page keeps the fixture's line structure explicit.
List<int> _buildAnswersPdf(List<String> lines) {
  final document = PdfDocument();
  final font = PdfCjkStandardFont(PdfCjkFontFamily.sinoTypeSongLight, 10);
  for (final line in lines) {
    final page = document.pages.add();
    if (line.isEmpty) continue;
    page.graphics.drawString(line, font);
  }
  final bytes = document.saveSync();
  document.dispose();
  return bytes;
}

List<String> _texts(RichContent content) {
  return <String>[
    for (final node in content.nodes)
      if (node is TextNode) node.text,
  ];
}

/// The significant texts of one projected answer: the text layer's own
/// break-only parts are dropped, so an assertion states the answer content
/// instead of the extraction's part granularity.
List<String> _answerTexts(RichContent content) {
  return <String>[
    for (final text in _texts(content))
      if (text.trim().isNotEmpty) text.trim(),
  ];
}

RichContent _text(String text) {
  return RichContent(nodes: <ContentNode>[TextNode(text)]);
}
