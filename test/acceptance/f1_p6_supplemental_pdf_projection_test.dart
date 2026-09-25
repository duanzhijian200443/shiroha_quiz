// F1 -> P6 synthetic PDF integration.
//
// Synthetic fixture only: a generated PDF whose lines carry the answer-document
// structures this closure targets (bracket locators, explicit answers, derived
// solution blocks, context labels). No private document, no OCR, no network.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:shiroha_quiz/application/parsed_artifacts/parsed_artifact_lifecycle.dart';
import 'package:shiroha_quiz/application/supplemental_answers/supplemental_answer_projector.dart';
import 'package:shiroha_quiz/domain/assets/library_file.dart';
import 'package:shiroha_quiz/domain/content/content_node.dart';
import 'package:shiroha_quiz/domain/content/rich_content.dart';
import 'package:shiroha_quiz/domain/supplemental_answers/supplemental_answer_fragment.dart';
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
