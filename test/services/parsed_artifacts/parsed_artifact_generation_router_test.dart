import 'package:flutter_test/flutter_test.dart';
import 'package:shiroha_quiz/application/parsed_artifacts/parsed_artifact_lifecycle.dart';
import 'package:shiroha_quiz/core/observability/app_logger.dart';
import 'package:shiroha_quiz/core/observability/log_record.dart';
import 'package:shiroha_quiz/core/observability/trace_context.dart';
import 'package:shiroha_quiz/domain/assets/library_file.dart';
import 'package:shiroha_quiz/domain/content/content_node.dart';
import 'package:shiroha_quiz/domain/content/rich_content.dart';
import 'package:shiroha_quiz/domain/source/source_document.dart';
import 'package:shiroha_quiz/domain/source/source_part.dart';
import 'package:shiroha_quiz/domain/source/source_ref.dart';
import 'package:shiroha_quiz/services/parsed_artifacts/parsed_artifact_generation_router.dart';

class _RecordingGenerationPort implements ParsedArtifactGenerationPort {
  _RecordingGenerationPort(this.route);

  final String route;
  int resolveCalls = 0;
  int generateCalls = 0;

  @override
  Future<ParsedArtifactGenerationPlan> resolvePlan({
    required LibraryFile file,
    required ParsedArtifactParseOptions options,
  }) async {
    resolveCalls++;
    if (route == 'fail') {
      throw const ParsedArtifactGenerationException(
        ParsedArtifactGenerationFailure.unsupportedRoute,
      );
    }
    return ParsedArtifactGenerationPlan(
      parserRoute: route,
      parserVersion: 'v1',
      optionsSchemaVersion: 1,
    );
  }

  @override
  Future<SourceDocument> generate({
    required LibraryFile file,
    required String artifactId,
    required ParsedArtifactGenerationPlan plan,
  }) async {
    generateCalls++;
    if (route == 'fail') {
      throw const ParsedArtifactGenerationException(
        ParsedArtifactGenerationFailure.sourceUnavailable,
      );
    }
    return SourceDocument(
      sourceId: artifactId,
      parts: <SourcePart>[
        SourceContentPart(
          sourceRef: SourceRef.document(sourceId: artifactId),
          content: RichContent(
            nodes: <ContentNode>[TextNode('$route content')],
          ),
        ),
      ],
    );
  }
}

LibraryFile file({String displayName = 'a.txt'}) {
  return LibraryFile(
    fileId: 'file-1',
    displayName: displayName,
    mimeType: 'text/plain',
    sizeBytes: 1,
    sha256: 'ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad',
    storageKey: 'library/file-1',
    createdAt: DateTime.utc(2026, 8, 13),
  );
}

void main() {
  late _RecordingGenerationPort deterministic;
  late _RecordingGenerationPort ocr;
  late ParsedArtifactGenerationRouter router;

  setUp(() {
    deterministic = _RecordingGenerationPort('txt');
    ocr = _RecordingGenerationPort('ocr_image');
    router = ParsedArtifactGenerationRouter(
      deterministicGeneration: deterministic,
      ocrGeneration: ocr,
    );
  });

  test('deterministic selections delegate to the deterministic port', () async {
    for (final (selection, route) in <(ParsedArtifactRouteSelection, String)>[
      (ParsedArtifactRouteSelection.auto, 'txt'),
      (ParsedArtifactRouteSelection.pdfText, 'txt'),
      (ParsedArtifactRouteSelection.docxText, 'txt'),
      (ParsedArtifactRouteSelection.txt, 'txt'),
      (ParsedArtifactRouteSelection.markdown, 'txt'),
    ]) {
      final plan = await router.resolvePlan(
        file: file(),
        options: ParsedArtifactParseOptions(routeSelection: selection),
      );
      expect(plan.parserRoute, route);
    }
    expect(deterministic.resolveCalls, 5);
    expect(ocr.resolveCalls, 0);
  });

  test('OCR selections delegate to the OCR port', () async {
    final pdfPlan = await router.resolvePlan(
      file: file(displayName: 'a.pdf'),
      options: const ParsedArtifactParseOptions(
        routeSelection: ParsedArtifactRouteSelection.ocrPdf,
      ),
    );
    final imagePlan = await router.resolvePlan(
      file: file(displayName: 'a.png'),
      options: const ParsedArtifactParseOptions(
        routeSelection: ParsedArtifactRouteSelection.ocrImage,
      ),
    );
    expect(pdfPlan.parserRoute, 'ocr_image');
    expect(imagePlan.parserRoute, 'ocr_image');
    expect(deterministic.resolveCalls, 0);
    expect(ocr.resolveCalls, 2);
  });

  test('generate delegates by parser route', () async {
    final txt = await router.generate(
      file: file(),
      artifactId: 'artifact-txt',
      plan: ParsedArtifactGenerationPlan(
        parserRoute: 'txt',
        parserVersion: 'v1',
        optionsSchemaVersion: 1,
      ),
    );
    final ocrDoc = await router.generate(
      file: file(displayName: 'a.png'),
      artifactId: 'artifact-ocr',
      plan: ParsedArtifactGenerationPlan(
        parserRoute: 'ocr_image',
        parserVersion: 'v1',
        optionsSchemaVersion: 1,
      ),
    );
    expect(txt.documentRef.sourceId, 'artifact-txt');
    expect(ocrDoc.documentRef.sourceId, 'artifact-ocr');
    expect(deterministic.generateCalls, 1);
    expect(ocr.generateCalls, 1);
  });

  test('unknown parser routes are unsupported', () async {
    await expectLater(
      router.generate(
        file: file(),
        artifactId: 'artifact-x',
        plan: ParsedArtifactGenerationPlan(
          parserRoute: 'hologram',
          parserVersion: 'v1',
          optionsSchemaVersion: 1,
        ),
      ),
      throwsA(
        isA<ParsedArtifactGenerationException>().having(
          (error) => error.failure,
          'failure',
          ParsedArtifactGenerationFailure.unsupportedRoute,
        ),
      ),
    );
    expect(deterministic.generateCalls, 0);
    expect(ocr.generateCalls, 0);
  });

  test('auto image never reaches the OCR port', () async {
    final failingDeterministic = _RecordingGenerationPort('fail');
    final failingOcr = _RecordingGenerationPort('ocr_image');
    final failingRouter = ParsedArtifactGenerationRouter(
      deterministicGeneration: failingDeterministic,
      ocrGeneration: failingOcr,
    );

    await expectLater(
      failingRouter.resolvePlan(
        file: file(displayName: 'a.png'),
        options: const ParsedArtifactParseOptions(
          routeSelection: ParsedArtifactRouteSelection.auto,
        ),
      ),
      throwsA(
        isA<ParsedArtifactGenerationException>().having(
          (error) => error.failure,
          'failure',
          ParsedArtifactGenerationFailure.unsupportedRoute,
        ),
      ),
    );
    expect(failingDeterministic.resolveCalls, 1);
    expect(failingOcr.resolveCalls, 0);
  });

  test('empty-text PDF auto never falls back to OCR', () async {
    final failingDeterministic = _RecordingGenerationPort('fail');
    final failingOcr = _RecordingGenerationPort('ocr_image');
    final failingRouter = ParsedArtifactGenerationRouter(
      deterministicGeneration: failingDeterministic,
      ocrGeneration: failingOcr,
    );

    await expectLater(
      failingRouter.generate(
        file: file(displayName: 'a.pdf'),
        artifactId: 'artifact-x',
        plan: ParsedArtifactGenerationPlan(
          parserRoute: 'pdf_text',
          parserVersion: 'v1',
          optionsSchemaVersion: 1,
        ),
      ),
      throwsA(
        isA<ParsedArtifactGenerationException>().having(
          (error) => error.failure,
          'failure',
          ParsedArtifactGenerationFailure.sourceUnavailable,
        ),
      ),
    );
    expect(failingDeterministic.generateCalls, 1);
    expect(failingOcr.generateCalls, 0);
  });

  group('OBS-1 generation trace', () {
    late _MemoryLogSink sink;

    setUp(() {
      sink = _MemoryLogSink();
      AppLogger.setSink(sink);
    });

    tearDown(() {
      AppLogger.setSink(null);
    });

    Future<void> flushLogs() => AppLogger.flush();

    test('standalone generation opens a root correlation', () async {
      final document = await router.generate(
        file: file(),
        artifactId: 'artifact-standalone',
        plan: ParsedArtifactGenerationPlan(
          parserRoute: 'txt',
          parserVersion: 'v1',
          optionsSchemaVersion: 1,
        ),
      );
      await flushLogs();

      expect(document.documentRef.sourceId, 'artifact-standalone');
      final records = sink.records
          .where((r) => r.data['stage'] == 'parsed_artifact_generation')
          .toList();
      expect(records, hasLength(1));
      final record = records.single;
      expect(record.operationKind, TraceOperationKind.parsedArtifactGeneration);
      expect(record.correlationId,
          matches(RegExp(r'^OBS-[A-Z0-9]{4}-[A-Z0-9]{4}$')));
      expect(record.parentTraceId, isNull);
      expect(record.data['parserRoute'], 'txt');
      expect(record.data['artifactId'], 'artifact-standalone');
      expect(record.data['status'], 'success');
      expect(record.data['durationMs'], isA<int>());
    });

    test(
        'generation under an existing Agent context inherits correlation '
        'and creates a child trace', () async {
      await TraceContext.run(
        correlationId: 'OBS-AAAA-BBBB',
        traceId: 'trace-agent-root',
        operationKind: TraceOperationKind.agentTurn,
        action: () => router.generate(
          file: file(),
          artifactId: 'artifact-child',
          plan: ParsedArtifactGenerationPlan(
            parserRoute: 'txt',
            parserVersion: 'v1',
            optionsSchemaVersion: 1,
          ),
        ),
      );
      await flushLogs();

      final records = sink.records
          .where((r) => r.data['stage'] == 'parsed_artifact_generation')
          .toList();
      expect(records, hasLength(1));
      final record = records.single;
      expect(record.correlationId, 'OBS-AAAA-BBBB');
      expect(record.parentTraceId, 'trace-agent-root');
      expect(record.traceId, isNot('trace-agent-root'));
      expect(record.operationKind, TraceOperationKind.parsedArtifactGeneration);
    });

    test('generation logging never contains SourceDocument content', () async {
      await router.generate(
        file: file(displayName: 'private-exam.pdf'),
        artifactId: 'artifact-secret',
        plan: ParsedArtifactGenerationPlan(
          parserRoute: 'txt',
          parserVersion: 'v1',
          optionsSchemaVersion: 1,
        ),
      );
      await flushLogs();

      final encoded =
          sink.records.map((record) => record.toJson().toString()).join('\n');
      expect(encoded, isNot(contains('txt content')));
      expect(encoded, isNot(contains('private-exam.pdf')));
    });

    test('failed generation logs fixed errorType and rethrows', () async {
      final failingOcr = _RecordingGenerationPort('fail');
      final failingRouter = ParsedArtifactGenerationRouter(
        deterministicGeneration: deterministic,
        ocrGeneration: failingOcr,
      );
      await expectLater(
        failingRouter.generate(
          file: file(displayName: 'a.png'),
          artifactId: 'artifact-fail',
          plan: ParsedArtifactGenerationPlan(
            parserRoute: 'ocr_image',
            parserVersion: 'v1',
            optionsSchemaVersion: 1,
          ),
        ),
        throwsA(
          isA<ParsedArtifactGenerationException>().having(
            (error) => error.failure,
            'failure',
            ParsedArtifactGenerationFailure.sourceUnavailable,
          ),
        ),
      );
      await flushLogs();

      final record = sink.records.single;
      expect(record.data['status'], 'failed');
      expect(record.data['errorType'], isA<String>());
      expect(record.data['parserRoute'], 'ocr_image');
    });
  });
}

class _MemoryLogSink implements LogSink {
  final List<LogRecord> records = <LogRecord>[];

  @override
  Future<void> write(LogRecord record) async {
    records.add(record);
  }

  @override
  Future<void> flush() async {}
}
