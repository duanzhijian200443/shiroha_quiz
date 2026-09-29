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

/// Draws every token of one answer line as its own text run, so the extractor
/// preserves the line as several ordered parts.
List<int> _buildFragmentedAnswersPdf() {
  final document = PdfDocument();
  final font = PdfCjkStandardFont(PdfCjkFontFamily.sinoTypeSongLight, 10);
  document.pages.add().graphics.drawString(_fragmentedTitle, font);
  void drawFragmentedLine(List<String> runs) {
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

  _fragmentedChoiceAnswers.forEach((number, letter) {
    drawFragmentedLine(<String>['($number)', '【', '答案', '】', '($letter).']);
  });
  _fragmentedContentAnswers.forEach((number, content) {
    drawFragmentedLine(<String>['($number)', '【', '答案', '】', content]);
  });

  final bytes = document.saveSync();
  document.dispose();
  return bytes;
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

RichContent _text(String text) {
  return RichContent(nodes: <ContentNode>[TextNode(text)]);
}
