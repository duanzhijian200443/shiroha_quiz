// P6 SV-B review regression.
//
// Synthetic fixtures only: no real PDF/OCR/provider, no network. Proves the
// connected review flow: question context rendering, human-readable choice
// labels, the explicit source-verification chain (view original != verified),
// safe-closed behavior without verification capability, page-hint
// provenance, and bounded card layout. Inspections are always produced by
// the real SupplementalSourceInspectionService over synthetic ports.
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shiroha_quiz/application/file_library/file_library_ports.dart';
import 'package:shiroha_quiz/application/parsed_artifacts/parsed_artifact_lifecycle.dart';
import 'package:shiroha_quiz/application/supplemental_answers/supplemental_answer_command.dart';
import 'package:shiroha_quiz/application/supplemental_answers/supplemental_answer_matcher.dart';
import 'package:shiroha_quiz/application/supplemental_answers/supplemental_answer_review_session.dart';
import 'package:shiroha_quiz/application/supplemental_answers/supplemental_source_inspection.dart';
import 'package:shiroha_quiz/application/supplemental_answers/target_question_snapshot_service.dart';
import 'package:shiroha_quiz/domain/assets/library_file.dart';
import 'package:shiroha_quiz/domain/assets/parsed_artifact.dart';
import 'package:shiroha_quiz/domain/content/content_node.dart';
import 'package:shiroha_quiz/domain/content/rich_content.dart';
import 'package:shiroha_quiz/domain/question/question_draft_v2.dart';
import 'package:shiroha_quiz/domain/source/source_document.dart';
import 'package:shiroha_quiz/domain/source/source_ref.dart';
import 'package:shiroha_quiz/domain/supplemental_answers/answer_candidate.dart';
import 'package:shiroha_quiz/domain/supplemental_answers/answer_match_record.dart';
import 'package:shiroha_quiz/domain/supplemental_answers/supplemental_answer_fragment.dart';
import 'package:shiroha_quiz/domain/supplemental_answers/supplemental_answer_scope.dart';
import 'package:shiroha_quiz/ui/pages/supplemental_answer_review_screen.dart';

const _artifact = SupplementalArtifactContext(
  supplementalFileId: 'file_001',
  artifactId: 'artifact_001',
  artifactRevision: 1,
);

const _unableToVerifyOriginal = '我已对照原文件确认此候选答案';
const _viewOriginal = '查看原文件';
const _confirmFill = '确认填写';
const _confirmReplace = '确认替换';
const _confirmReplaceAgain = '二次确认替换';

void main() {
  testWidgets('R1: question number, stem, and options are rendered',
      (tester) async {
    final session = _choiceSession();

    await _pumpReview(tester, session: session);

    expect(find.text('第 1 题'), findsOneWidget);
    expect(find.text('stem 1'), findsOneWidget);
    expect(find.textContaining('A.'), findsOneWidget);
    expect(find.textContaining('B.'), findsOneWidget);
    expect(find.text('选项A内容'), findsOneWidget);
    expect(find.text('选项B内容'), findsOneWidget);
    expect(find.text('待核对原文'), findsOneWidget);
  });

  testWidgets(
      'R2+R7: verified fill shows readable choice labels and persists the '
      'original typed answer', (tester) async {
    final port = _FakePersistencePort();
    final command = _command(port);
    final session = _choiceSession();
    final recorder = _LauncherRecorder();
    final service = _inspectionService();

    await _pumpReview(
      tester,
      session: session,
      command: command,
      sourceInspectionService: service,
      launcher: recorder.launch,
    );

    // The candidate answer renders as the human-readable option label.
    expect(find.text('A'), findsOneWidget);

    await _verifyOriginalSource(tester, recorder);

    await tester.tap(find.byType(Checkbox).first);
    await tester.pump();
    await tester.tap(find.widgetWithText(FilledButton, _confirmFill).first);
    await tester.pumpAndSettle();

    expect(find.text('已写入'), findsOneWidget);
    expect(port.confirmed, hasLength(1));
    final answer = port.confirmed.single.answer;
    expect(answer, isA<ChoiceAnswer>());
    // Persistence still receives the original typed answer, never the label.
    expect((answer as ChoiceAnswer).optionIds, ['opt_a']);
  });

  testWidgets('R3: ContentAnswer keeps rendering the original content',
      (tester) async {
    final port = _FakePersistencePort();
    final command = _command(port);
    final session = _session(
      targets: [_target('q_1', number: 1)],
      fragments: [_fragment('frag_1', main: '1', answer: 'x = 1')],
    );

    await _pumpReview(tester, session: session, command: command);

    expect(find.text('x = 1'), findsOneWidget);
    expect(port.confirmed, isEmpty);
  });

  testWidgets(
      'R4: unverified fill stays disabled with zero artifact/persistence calls',
      (tester) async {
    final port = _FakePersistencePort();
    final command = _command(port);
    final session = _session(
      targets: [_target('q_1', number: 1)],
      fragments: [_fragment('frag_1', main: '1', answer: 'x = 1')],
    );

    await _pumpReview(tester, session: session, command: command);

    expect(
      tester
          .widget<FilledButton>(
            find.widgetWithText(FilledButton, _confirmFill),
          )
          .onPressed,
      isNull,
      reason: 'unverified candidates must not offer fill confirmation',
    );

    await tester.tap(find.byType(Checkbox));
    await tester.pump();
    expect(
      tester
          .widget<FilledButton>(
            find.widgetWithText(FilledButton, _confirmFill),
          )
          .onPressed,
      isNull,
      reason: 'selection alone must not enable fill confirmation',
    );

    expect(port.confirmed, isEmpty);
    expect(port.artifacts.calls, 0);
  });

  testWidgets(
      'R5: viewing the original hands the exact inspection to the launcher '
      'but keeps verification required', (tester) async {
    final recorder = _LauncherRecorder();
    final service = _inspectionService();
    final session = _session(
      targets: [_target('q_1', number: 1)],
      fragments: [_fragment('frag_1', main: '1', answer: 'x = 1')],
    );

    await _pumpReview(
      tester,
      session: session,
      sourceInspectionService: service,
      launcher: recorder.launch,
    );

    expect(
      tester
          .widget<FilledButton>(
            find.widgetWithText(FilledButton, _unableToVerifyOriginal),
          )
          .onPressed,
      isNull,
      reason: 'the explicit verify action is closed before any inspection',
    );

    await tester.tap(find.widgetWithText(OutlinedButton, _viewOriginal));
    await tester.pumpAndSettle();

    expect(recorder.launched, hasLength(1));
    final inspection = recorder.launched.single.$1;
    expect(inspection.fileId, 'file_001');
    expect(inspection.artifactId, 'artifact_001');
    expect(inspection.artifactRevision, 1);
    expect(recorder.launched.single.$2, isNull);

    expect(find.text('待核对原文'), findsOneWidget);
    expect(find.text('已核对原文'), findsNothing);
    expect(
      tester
          .widget<FilledButton>(
            find.widgetWithText(FilledButton, _unableToVerifyOriginal),
          )
          .onPressed,
      isNotNull,
    );
    expect(
      tester
          .widget<FilledButton>(
            find.widgetWithText(FilledButton, _confirmFill),
          )
          .onPressed,
      isNull,
      reason: 'opening the viewer must not enable the write',
    );
    expect(find.text('已写入'), findsNothing);
  });

  testWidgets(
      'R6: only the explicit confirmation action records the verification',
      (tester) async {
    final recorder = _LauncherRecorder();
    final service = _inspectionService();
    final session = _session(
      targets: [_target('q_1', number: 1)],
      fragments: [_fragment('frag_1', main: '1', answer: 'x = 1')],
    );

    await _pumpReview(
      tester,
      session: session,
      sourceInspectionService: service,
      launcher: recorder.launch,
    );

    await _verifyOriginalSource(tester, recorder);

    expect(find.text('待核对原文'), findsNothing);
    expect(find.text('已核对原文'), findsOneWidget);
  });

  testWidgets(
      'R8: replace requires verify, then arm, then the second confirmation',
      (tester) async {
    final port = _FakePersistencePort();
    final command = _command(port);
    final recorder = _LauncherRecorder();
    final service = _inspectionService();
    final session = _session(
      targets: [
        _target(
          'q_1',
          number: 1,
          answer: ContentAnswer(content: _text('x = 9')),
        ),
      ],
      fragments: [_fragment('frag_1', main: '1', answer: 'x = 1')],
    );

    await _pumpReview(
      tester,
      session: session,
      command: command,
      sourceInspectionService: service,
      launcher: recorder.launch,
    );

    expect(
      tester
          .widget<FilledButton>(
            find.widgetWithText(FilledButton, _confirmReplace),
          )
          .onPressed,
      isNull,
      reason: 'unverified replace must stay closed',
    );

    await _verifyOriginalSource(tester, recorder);
    await tester.tap(find.widgetWithText(FilledButton, _confirmReplace));
    await tester.pump();
    expect(port.confirmed, isEmpty);
    expect(find.text(_confirmReplaceAgain), findsOneWidget);

    await tester.tap(find.widgetWithText(FilledButton, _confirmReplaceAgain));
    await tester.pumpAndSettle();

    expect(find.text('已替换'), findsOneWidget);
    expect(port.confirmed, hasLength(1));
    expect(port.confirmed.single.answer, isA<ContentAnswer>());
  });

  testWidgets('R9: DOCX cannot reach source verification or any write',
      (tester) async {
    final port = _FakePersistencePort();
    final command = _command(port);
    final recorder = _LauncherRecorder();
    final service = _inspectionService(
      mimeType:
          'application/vnd.openxmlformats-officedocument.wordprocessingml.document',
    );
    final session = _session(
      targets: [_target('q_1', number: 1)],
      fragments: [_fragment('frag_1', main: '1', answer: 'x = 1')],
    );

    await _pumpReview(
      tester,
      session: session,
      command: command,
      sourceInspectionService: service,
      launcher: recorder.launch,
    );

    await tester.tap(find.widgetWithText(OutlinedButton, _viewOriginal));
    await tester.pumpAndSettle();

    expect(find.text('当前格式暂不支持应用内原文核验。'), findsOneWidget);
    expect(recorder.launched, isEmpty);
    expect(find.text(_unableToVerifyOriginal), findsNothing);
    expect(find.text('已核对原文'), findsNothing);
    expect(
      tester
          .widget<FilledButton>(
            find.widgetWithText(FilledButton, _confirmFill),
          )
          .onPressed,
      isNull,
    );
    expect(port.confirmed, isEmpty);
    expect(port.artifacts.calls, 0);
  });

  testWidgets(
      'R10: inspection failure shows the safe message with zero viewer and '
      'zero write', (tester) async {
    final port = _FakePersistencePort();
    final command = _command(port);
    final recorder = _LauncherRecorder();
    final service = _inspectionService(artifactFileId: 'misrouted_file');
    final session = _session(
      targets: [_target('q_1', number: 1)],
      fragments: [_fragment('frag_1', main: '1', answer: 'x = 1')],
    );

    await _pumpReview(
      tester,
      session: session,
      command: command,
      sourceInspectionService: service,
      launcher: recorder.launch,
    );

    await tester.tap(find.widgetWithText(OutlinedButton, _viewOriginal));
    await tester.pumpAndSettle();

    expect(find.text('补充文档解析状态已变化，请重新匹配。'), findsOneWidget);
    expect(recorder.launched, isEmpty);
    expect(
      tester
          .widget<FilledButton>(
            find.widgetWithText(FilledButton, _unableToVerifyOriginal),
          )
          .onPressed,
      isNull,
      reason: 'a failed inspection must not enable the verify action',
    );
    expect(find.text('已核对原文'), findsNothing);
    expect(port.confirmed, isEmpty);
    expect(port.artifacts.calls, 0);
  });

  testWidgets('R11: a real page SourceRef becomes the 1-based page hint',
      (tester) async {
    final recorder = _LauncherRecorder();
    final service = _inspectionService();
    final session = _session(
      targets: [_target('q_1', number: 1)],
      fragments: [
        _fragmentWithRefs('frag_1', main: '1', answer: 'x = 1', refs: [
          SourceRef.at(
            sourceId: 'artifact_001',
            point: SourcePoint.page(pageNumber: 3),
          ),
        ]),
      ],
    );

    await _pumpReview(
      tester,
      session: session,
      sourceInspectionService: service,
      launcher: recorder.launch,
    );

    await tester.tap(find.widgetWithText(OutlinedButton, _viewOriginal));
    await tester.pumpAndSettle();

    expect(recorder.launched, hasLength(1));
    expect(recorder.launched.single.$2, 3);
  });

  testWidgets('R12: document-only source refs never fabricate a page hint',
      (tester) async {
    final recorder = _LauncherRecorder();
    final service = _inspectionService();
    final session = _session(
      targets: [_target('q_1', number: 1)],
      fragments: [_fragment('frag_1', main: '1', answer: 'x = 1')],
    );

    await _pumpReview(
      tester,
      session: session,
      sourceInspectionService: service,
      launcher: recorder.launch,
    );

    await tester.tap(find.widgetWithText(OutlinedButton, _viewOriginal));
    await tester.pumpAndSettle();

    expect(recorder.launched, hasLength(1));
    expect(recorder.launched.single.$2, isNull);
  });

  testWidgets('R13: noOp candidates expose no verification or write actions',
      (tester) async {
    final port = _FakePersistencePort();
    final command = _command(port);
    final session = _session(
      targets: [
        _target('q_1',
            number: 1, answer: ContentAnswer(content: _text('x = 1'))),
      ],
      fragments: [_fragment('frag_1', main: '1', answer: 'x = 1')],
    );

    await _pumpReview(tester, session: session, command: command);

    expect(find.text('不可写入项'), findsOneWidget);
    expect(find.textContaining('noOp'), findsOneWidget);
    expect(find.text(_viewOriginal), findsNothing);
    expect(find.text(_unableToVerifyOriginal), findsNothing);
    expect(find.text(_confirmFill), findsNothing);
    expect(find.text(_confirmReplace), findsNothing);
    expect(port.confirmed, isEmpty);
    expect(port.artifacts.calls, 0);
  });

  testWidgets('R14: review cards bound tall content locally', (tester) async {
    final session = _session(
      targets: [_target('q_1', number: 1)],
      fragments: [_fragment('frag_1', main: '1', answer: 'x = 1')],
    );

    await _pumpReview(tester, session: session);

    final contextBox = tester.widget<ConstrainedBox>(
      find.byKey(const ValueKey<String>('supplemental-review-bounded-context')),
    );
    expect(contextBox.constraints.maxHeight, 240);
    final answerBox = tester.widget<ConstrainedBox>(
      find.byKey(const ValueKey<String>('supplemental-review-bounded-answer')),
    );
    expect(answerBox.constraints.maxHeight, 280);
  });

  testWidgets('reject is terminal with zero mutation', (tester) async {
    final port = _FakePersistencePort();
    final command = _command(port);
    final session = _session(
      targets: [_target('q_1', number: 1)],
      fragments: [_fragment('frag_1', main: '1', answer: 'x = 1')],
    );

    await _pumpReview(tester, session: session, command: command);

    await tester.tap(find.widgetWithText(OutlinedButton, '拒绝'));
    await tester.pump();

    expect(find.text('已拒绝'), findsOneWidget);
    expect(port.confirmed, isEmpty);
  });

  testWidgets('ambiguous and unmatched records render as non-writable',
      (tester) async {
    final port = _FakePersistencePort();
    final command = _command(port);
    final session = _session(
      targets: [
        _target('q_1', number: 1),
        _target('q_2', number: 1),
      ],
      fragments: [
        _fragment('frag_1', main: '1', answer: 'x = 1'),
      ],
    );

    await _pumpReview(tester, session: session, command: command);

    expect(find.text('不可写入项'), findsOneWidget);
    expect(find.textContaining('ambiguous'), findsOneWidget);
  });

  testWidgets('R15: the banner and copy render strictly valid trace ids',
      (tester) async {
    await _pumpReview(
      tester,
      session: _session(
        targets: [_target('q_1', number: 1)],
        fragments: [_fragment('frag_1', main: '1', answer: 'A')],
        correlationId: 'OBS-AAAA-BBBB',
        traceId: 'trace-1-abcd',
      ),
    );

    expect(
      find.byKey(const ValueKey<String>('supplemental-answer-trace-info')),
      findsOneWidget,
    );
    expect(find.textContaining('诊断编号：OBS-AAAA-BBBB'), findsOneWidget);
    expect(find.textContaining('Trace ID：trace-1-abcd'), findsOneWidget);
    expect(find.byTooltip('复制诊断信息'), findsOneWidget);
  });

  testWidgets('R16: invalid trace ids are omitted from the banner and copy',
      (tester) async {
    await _pumpReview(
      tester,
      session: _session(
        targets: [_target('q_1', number: 1)],
        fragments: [_fragment('frag_1', main: '1', answer: 'A')],
        correlationId: 'not-a-diagnostic-id',
        traceId: 'bad id!',
      ),
    );

    expect(
      find.byKey(const ValueKey<String>('supplemental-answer-trace-info')),
      findsNothing,
    );
    expect(find.textContaining('诊断编号：'), findsNothing);
    expect(find.textContaining('Trace ID：'), findsNothing);
  });
}

Future<void> _verifyOriginalSource(
  WidgetTester tester,
  _LauncherRecorder recorder,
) async {
  await tester.tap(find.widgetWithText(OutlinedButton, _viewOriginal));
  await tester.pumpAndSettle();
  expect(recorder.launched, hasLength(1));
  await tester.tap(
    find.widgetWithText(FilledButton, _unableToVerifyOriginal),
  );
  await tester.pump();
}

Future<void> _pumpReview(
  WidgetTester tester, {
  required SupplementalAnswerReviewSession session,
  SupplementalAnswerConfirmCommand? command,
  SupplementalSourceInspectionService? sourceInspectionService,
  SupplementalOriginalSourceLauncher? launcher,
}) async {
  await tester.pumpWidget(
    MaterialApp(
      home: SupplementalAnswerReviewScreen(
        session: session,
        confirmCommand: command ?? _command(_FakePersistencePort()),
        sourceInspectionService: sourceInspectionService,
        originalSourceLauncher: launcher ?? _noopLauncher,
      ),
    ),
  );
  await tester.pump();
}

Future<void> _noopLauncher(
  BuildContext context,
  SupplementalSourceInspection inspection,
  int? pageHint,
) async {}

SupplementalAnswerReviewSession _choiceSession() {
  return _session(
    targets: [
      _choiceTarget('q_1', number: 1),
    ],
    fragments: [
      _fragment('frag_1', main: '1', answer: 'A'),
    ],
  );
}

SupplementalAnswerReviewSession _session({
  required List<AnswerTargetReference> targets,
  required List<SupplementalAnswerFragment> fragments,
  String? correlationId,
  String? traceId,
}) {
  const matcher = SupplementalAnswerMatcher();
  final snapshot = TargetQuestionSnapshot(
    targets: targets,
    reports: const [],
  );
  final result = matcher.match(
    fragments: fragments,
    snapshot: snapshot,
    artifact: _artifact,
  );
  return SupplementalAnswerReviewSession(
    request: SupplementalAnswerMatchRequest(
      targetScope: const QuestionBankScope(bankName: 'bank_math'),
      supplementalFileId: 'file_001',
    ),
    snapshot: snapshot,
    matchResult: result,
    correlationId: correlationId,
    traceId: traceId,
  );
}

AnswerTargetReference _target(
  String storageId, {
  required int number,
  QuestionAnswer? answer,
}) {
  return AnswerTargetReference(
    storageId: storageId,
    bankName: 'bank_math',
    draft: QuestionDraftV2(
      questionId: storageId,
      kind: QuestionKind.shortAnswer,
      questionNumber: number,
      stem: _text('stem $number'),
      answer: answer,
    ),
  );
}

AnswerTargetReference _choiceTarget(
  String storageId, {
  required int number,
}) {
  return AnswerTargetReference(
    storageId: storageId,
    bankName: 'bank_math',
    draft: QuestionDraftV2(
      questionId: storageId,
      kind: QuestionKind.singleChoice,
      questionNumber: number,
      stem: _text('stem $number'),
      options: [
        QuestionOption(
          optionId: 'opt_a',
          label: 'A',
          content: _text('选项A内容'),
        ),
        QuestionOption(
          optionId: 'opt_b',
          label: 'B',
          content: _text('选项B内容'),
        ),
      ],
    ),
  );
}

SupplementalAnswerFragment _fragment(
  String fragmentId, {
  required String main,
  required String answer,
}) {
  return _fragmentWithRefs(fragmentId, main: main, answer: answer, refs: [
    SourceRef.document(sourceId: 'artifact_001'),
  ]);
}

SupplementalAnswerFragment _fragmentWithRefs(
  String fragmentId, {
  required String main,
  required String answer,
  required List<SourceRef> refs,
}) {
  return SupplementalAnswerFragment(
    fragmentId: fragmentId,
    normalizedMainNumber: main,
    answerContent: _text(answer),
    sourceRefs: refs,
    sequencePosition: const SupplementalSequencePosition(
      partIndex: 0,
      continuationOrdinal: 0,
    ),
  );
}

SupplementalAnswerConfirmCommand _command(_FakePersistencePort port) {
  return SupplementalAnswerConfirmCommand(
    artifactPort: port.artifacts,
    persistencePort: port,
  );
}

/// Builds a real SV-C1 inspection over synthetic ports only; tests never
/// construct a SupplementalSourceInspection directly.
SupplementalSourceInspectionService _inspectionService({
  String mimeType = 'application/pdf',
  String artifactFileId = 'file_001',
}) {
  final bytes = utf8.encode('%PDF-1.7 synthetic original source');
  return SupplementalSourceInspectionService(
    fileCatalog: _FakeFileCatalog(
      LibraryFile(
        fileId: 'file_001',
        displayName: 'answers.pdf',
        mimeType: mimeType,
        sizeBytes: bytes.length,
        sha256: _sha256,
        storageKey: 'p6/review-test',
        createdAt: DateTime.utc(2026, 1, 1),
      ),
    ),
    artifactPort: _FakeArtifactPort(artifactFileId: artifactFileId),
    sourceReader: _FakeSourceReader(bytes),
    maxBytes: 1 << 30,
  );
}

const String _sha256 =
    'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa';

class _LauncherRecorder {
  final List<(SupplementalSourceInspection, int?)> launched =
      <(SupplementalSourceInspection, int?)>[];

  Future<void> launch(
    BuildContext context,
    SupplementalSourceInspection inspection,
    int? pageHint,
  ) async {
    launched.add((inspection, pageHint));
  }
}

class _FakeFileCatalog implements LibraryFileRepositoryPort {
  _FakeFileCatalog(this.file);

  final LibraryFile file;

  @override
  Future<void> save(LibraryFile file) async {}

  @override
  Future<LibraryFile?> findById(String fileId) async => file;

  @override
  Future<List<LibraryFile>> findAll() async => <LibraryFile>[file];
}

class _FakeArtifactPort implements ParsedArtifactLifecyclePort {
  _FakeArtifactPort({this.artifactFileId = 'file_001'});

  final String artifactFileId;

  @override
  Future<ParsedArtifactSnapshot> getCurrentArtifact(String fileId) async {
    return ParsedArtifactSnapshot(
      artifact: ParsedArtifact(
        fileId: artifactFileId,
        artifactId: 'artifact_001',
        revision: 1,
        payloadSchemaVersion: 1,
      ),
      sourceDocument: SourceDocument(
        sourceId: 'artifact_001',
        parts: const [],
      ),
    );
  }

  @override
  Future<ParsedArtifactEnsureResult> ensureParsedArtifact({
    required String fileId,
    required ParsedArtifactParseOptions options,
  }) {
    throw UnimplementedError();
  }

  @override
  Future<ParsedArtifactEnsureResult> reparseArtifact({
    required String fileId,
    required ParsedArtifactParseOptions options,
    required int expectedRevision,
  }) {
    throw UnimplementedError();
  }

  @override
  Future<void> removeCurrentArtifact({
    required String fileId,
    required int expectedRevision,
  }) {
    throw UnimplementedError();
  }
}

class _FakeSourceReader implements SupplementalSourceReaderPort {
  _FakeSourceReader(this.bytes);

  final List<int> bytes;

  @override
  Future<SupplementalSourceReadResult> readOriginalBytes({
    required LibraryFile file,
    required int maxBytes,
  }) async {
    return SupplementalSourceReadResult(
      bytes: bytes,
      actualSizeBytes: bytes.length,
      actualSha256: _sha256,
    );
  }
}

class _StaticArtifactPort implements ParsedArtifactLifecyclePort {
  int calls = 0;
  @override
  Future<ParsedArtifactSnapshot> getCurrentArtifact(String fileId) async {
    calls++;
    return ParsedArtifactSnapshot(
      artifact: ParsedArtifact(
        fileId: 'file_001',
        artifactId: 'artifact_001',
        revision: 1,
        payloadSchemaVersion: 1,
      ),
      sourceDocument: SourceDocument(
        sourceId: 'artifact_001',
        parts: const [],
      ),
    );
  }

  @override
  Future<ParsedArtifactEnsureResult> ensureParsedArtifact({
    required String fileId,
    required ParsedArtifactParseOptions options,
  }) {
    throw UnimplementedError();
  }

  @override
  Future<ParsedArtifactEnsureResult> reparseArtifact({
    required String fileId,
    required ParsedArtifactParseOptions options,
    required int expectedRevision,
  }) {
    throw UnimplementedError();
  }

  @override
  Future<void> removeCurrentArtifact({
    required String fileId,
    required int expectedRevision,
  }) {
    throw UnimplementedError();
  }
}

class _FakePersistencePort implements SupplementalAnswerPersistencePort {
  final artifacts = _StaticArtifactPort();

  final List<AnswerCandidate> confirmed = <AnswerCandidate>[];

  @override
  Future<void> confirmCandidate(AnswerCandidate candidate) async {
    confirmed.add(candidate);
  }
}

RichContent _text(String text) {
  return RichContent(nodes: [TextNode(text)]);
}
