// ignore_for_file: depend_on_referenced_packages

import 'dart:convert';
import 'dart:io';
import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'package:shiroha_quiz/data/models/ai_engine_profile.dart';
import 'package:shiroha_quiz/data/repositories/ai_engine_repository.dart';
import 'package:shiroha_quiz/services/import_pipeline/import_document_role.dart';
import 'package:shiroha_quiz/services/import_pipeline/import_format.dart';
import 'package:shiroha_quiz/services/import_pipeline/import_question_final_sorter.dart';
import 'package:shiroha_quiz/services/import_pipeline/latex_sanity_checker.dart';
import 'package:shiroha_quiz/services/import_pipeline/local_question_assembler.dart';
import 'package:shiroha_quiz/services/import_pipeline/ocr_document.dart';
import 'package:shiroha_quiz/services/import_pipeline/ocr_import_service.dart';
import 'package:shiroha_quiz/services/import_pipeline/single_question_repair_service.dart';
import 'package:shiroha_quiz/services/import_pipeline/vision_question_quality_gate.dart';
import 'package:shiroha_quiz/services/llm_providers/zhipu_ocr_client.dart';

import 'import_acceptance_report.dart';

// ---------------------------------------------------------------------------
// Test case configuration
// ---------------------------------------------------------------------------

class ImportAcceptanceCase {
  const ImportAcceptanceCase({
    required this.schemaVersion,
    required this.caseId,
    required this.pdf,
    required this.expectedQuestionCount,
    required this.expectedNumbers,
    required this.allowDuplicateNumbers,
  });

  final int schemaVersion;
  final String caseId;
  final String pdf;
  final int expectedQuestionCount;
  final List<int> expectedNumbers;
  final bool allowDuplicateNumbers;

  factory ImportAcceptanceCase.fromJson(Map<String, dynamic> json) {
    final schemaVersion = json['schemaVersion'];
    if (schemaVersion is! int || schemaVersion != 1) {
      throw FormatException(
        'Unsupported case schema version: $schemaVersion',
      );
    }
    return ImportAcceptanceCase(
      schemaVersion: schemaVersion,
      caseId: json['caseId'] as String,
      pdf: json['pdf'] as String,
      expectedQuestionCount: json['expectedQuestionCount'] as int,
      expectedNumbers:
          (json['expectedNumbers'] as List).cast<int>().toList(),
      allowDuplicateNumbers: json['allowDuplicateNumbers'] as bool? ?? false,
    );
  }
}

ImportAcceptanceCase loadAcceptanceCase({
  required String caseId,
  required String repositoryRoot,
}) {
  final casePath = p.join(
    repositoryRoot,
    'tool',
    'import_cases',
    '$caseId.json',
  );
  final file = File(casePath);
  if (!file.existsSync()) {
    throw ArgumentError('Case file not found: $caseId');
  }
  final json = jsonDecode(file.readAsStringSync()) as Map<String, dynamic>;
  return ImportAcceptanceCase.fromJson(json);
}

// ---------------------------------------------------------------------------
// Replay cache
// ---------------------------------------------------------------------------

String computeReplayCacheFingerprint({
  required List<int> pdfBytes,
  required int documentSchemaVersion,
  required String ocrModelId,
}) {
  final hash = sha256.convert([
    ...utf8.encode('v$documentSchemaVersion'),
    ...utf8.encode(':$ocrModelId:'),
    ...pdfBytes,
  ]);
  return hash.toString().substring(0, 16);
}

class ReplayCacheResult {
  const ReplayCacheResult({
    required this.document,
    required this.sourceMode,
    required this.fingerprint,
    required this.cacheDirectory,
  });

  final OcrDocument document;
  final String sourceMode;
  final String fingerprint;
  final String cacheDirectory;
}

ReplayCacheResult? loadReplayCache({
  required String caseId,
  required String repositoryRoot,
}) {
  final replayRoot = p.join(repositoryRoot, 'scratch', 'ocr_replay', caseId);
  final dir = Directory(replayRoot);
  if (!dir.existsSync()) return null;

  final subdirs = dir
      .listSync()
      .whereType<Directory>()
      .toList()
    ..sort((a, b) => b.path.compareTo(a.path));

  for (final subdir in subdirs) {
    final manifestFile = File(p.join(subdir.path, 'manifest.json'));
    final docFile =
        File(p.join(subdir.path, 'ocr_document.private.json'));
    if (!manifestFile.existsSync() || !docFile.existsSync()) continue;

    try {
      final manifestJson =
          jsonDecode(manifestFile.readAsStringSync()) as Map<String, dynamic>;
      if (manifestJson['caseId'] != caseId) continue;

      final docJson =
          jsonDecode(docFile.readAsStringSync()) as Map<String, dynamic>;
      final document = OcrDocument.fromReplayJson(docJson);
      final fingerprint = p.basename(subdir.path);

      return ReplayCacheResult(
        document: document,
        sourceMode: 'replay',
        fingerprint: fingerprint,
        cacheDirectory: subdir.path,
      );
    } on FormatException {
      continue;
    } catch (_) {
      continue;
    }
  }
  return null;
}

void writeReplayCache({
  required String caseId,
  required String repositoryRoot,
  required OcrDocument document,
  required String fingerprint,
  required String pdfContentHash,
}) {
  final cacheDir = p.join(
    repositoryRoot,
    'scratch',
    'ocr_replay',
    caseId,
    fingerprint,
  );
  final tempDir = '${cacheDir}_tmp_${DateTime.now().millisecondsSinceEpoch}';

  Directory(tempDir).createSync(recursive: true);

  try {
    final docJson = jsonEncode(document.toReplayJson());
    // Validate round-trip before writing
    jsonDecode(docJson);

    File(p.join(tempDir, 'ocr_document.private.json'))
        .writeAsStringSync(docJson);
    File(p.join(tempDir, 'manifest.json')).writeAsStringSync(jsonEncode({
      'schemaVersion': 1,
      'caseId': caseId,
      'pdfContentHash': pdfContentHash,
      'ocrModelId': ZhipuOcrClient.model,
      'createdAt': DateTime.now().toUtc().toIso8601String(),
      'documentHash': sha256.convert(utf8.encode(docJson)).toString(),
    }));

    final target = Directory(cacheDir);
    if (target.existsSync()) {
      target.deleteSync(recursive: true);
    }
    Directory(tempDir).renameSync(cacheDir);
  } catch (_) {
    try {
      Directory(tempDir).deleteSync(recursive: true);
    } catch (_) {}
    rethrow;
  }
}

// ---------------------------------------------------------------------------
// Stub OCR client for replay (returns cached OcrDocument)
// ---------------------------------------------------------------------------

class _ReplayOcrClient extends ZhipuOcrClient {
  _ReplayOcrClient(this._document);

  final OcrDocument _document;
  int callCount = 0;

  @override
  Future<OcrDocument> parseFile({
    required AiEngineProfile profile,
    required String filePath,
    required String sourceName,
    Duration timeout = const Duration(minutes: 8),
  }) async {
    callCount++;
    return _document;
  }
}

// ---------------------------------------------------------------------------
// No-op repair service stub
// ---------------------------------------------------------------------------

class _NoOpRepairService extends SingleQuestionRepairService {
  _NoOpRepairService() : super(engineRepository: _StubEngineRepository());

  int candidateCount = 0;

  @override
  Future<LocalAssemblyResult> repair({
    required dynamic region,
    required LocalAssemblyResult localResult,
  }) async {
    candidateCount++;
    return localResult;
  }
}

class _StubEngineRepository extends AiEngineRepository {
  @override
  Future<AiEngineProfile?> getActiveOcrEngine() async => null;
  @override
  Future<AiEngineProfile?> getActiveTextEngine() async => null;
}

// ---------------------------------------------------------------------------
// Acceptance quality checker
// ---------------------------------------------------------------------------

class AcceptanceQuestionIssue {
  const AcceptanceQuestionIssue({
    required this.code,
    required this.severity,
  });

  final String code;
  final String severity; // 'hard' or 'review'

  Map<String, dynamic> toJson() => {'code': code, 'severity': severity};
}

class AcceptanceQuestionReport {
  AcceptanceQuestionReport({
    required this.questionNumber,
    required this.questionType,
    required this.hasContent,
    required this.optionCount,
    required this.hasStandardAnswer,
    required this.hasExplanation,
    required this.issues,
    required this.latexValidationMode,
  });

  final int questionNumber;
  final int questionType;
  final bool hasContent;
  final int optionCount;
  final bool hasStandardAnswer;
  final bool hasExplanation;
  final List<AcceptanceQuestionIssue> issues;
  final String latexValidationMode;

  bool get hasHardIssue => issues.any((i) => i.severity == 'hard');
  bool get hasReviewIssue => issues.any((i) => i.severity == 'review');

  Map<String, dynamic> toJson() => {
        'questionNumber': questionNumber,
        'questionType': questionType,
        'hasContent': hasContent,
        'optionCount': optionCount,
        'hasStandardAnswer': hasStandardAnswer,
        'hasExplanation': hasExplanation,
        'latexValidationMode': latexValidationMode,
        'issues': issues.map((i) => i.toJson()).toList(),
      };
}

class AcceptanceQualityResult {
  AcceptanceQualityResult({
    required this.questionReports,
    required this.structureVerdict,
    required this.acceptedNumbers,
    required this.missingNumbers,
    required this.duplicateNumbers,
  });

  final List<AcceptanceQuestionReport> questionReports;
  final String structureVerdict; // 'pass', 'fail'
  final List<int> acceptedNumbers;
  final List<int> missingNumbers;
  final List<int> duplicateNumbers;
}

AcceptanceQualityResult runAcceptanceQualityChecks({
  required List<Map<String, dynamic>> questions,
  required ImportAcceptanceCase testCase,
}) {
  final latexChecker = const LatexSanityChecker();
  final reports = <AcceptanceQuestionReport>[];
  final acceptedNumbers = <int>[];

  for (final q in questions) {
    final qNum = _readInt(q['question_number']) ?? 0;
    final type = _readInt(q['type']) ?? 3;
    final content = _readStr(q['content']);
    final options = q['options'];
    final optionCount = options is List ? options.length : 0;
    final answer = _readStr(q['standard_answer']);
    final explanation = _readStr(q['explanation']);
    final rawExplanation = _readStr(q['raw_explanation']);
    final hasContent = content.isNotEmpty;
    final hasAnswer = answer.isNotEmpty;
    final hasExplanation =
        explanation.isNotEmpty || rawExplanation.isNotEmpty;
    final issues = <AcceptanceQuestionIssue>[];
    final allText = '$content $answer $explanation';

    acceptedNumbers.add(qNum);

    // Empty content
    if (!hasContent) {
      issues.add(const AcceptanceQuestionIssue(
        code: 'empty_content',
        severity: 'hard',
      ));
    }

    // Answer coverage by type
    if (type == 0 || type == 1) {
      // Choice
      if (!hasAnswer) {
        issues.add(const AcceptanceQuestionIssue(
          code: 'missing_required_answer',
          severity: 'hard',
        ));
      }
      if (optionCount < 2) {
        issues.add(const AcceptanceQuestionIssue(
          code: 'missing_options',
          severity: 'hard',
        ));
      }
    } else if (type == 2) {
      // Fill-blank
      if (!hasAnswer) {
        issues.add(const AcceptanceQuestionIssue(
          code: 'missing_required_answer',
          severity: 'hard',
        ));
      }
    } else {
      // Subjective (type == 3)
      if (!hasAnswer && hasExplanation) {
        issues.add(const AcceptanceQuestionIssue(
          code: 'missing_explicit_answer',
          severity: 'review',
        ));
      } else if (!hasAnswer && !hasExplanation) {
        issues.add(const AcceptanceQuestionIssue(
          code: 'missing_answer_and_explanation',
          severity: 'hard',
        ));
      }
    }

    // LaTeX structural check (delimiter balance only)
    String latexMode = 'limited';
    if (_hasLatexContent(allText)) {
      if (latexChecker.hasDanglingDelimiters(allText)) {
        issues.add(const AcceptanceQuestionIssue(
          code: 'latex_unrenderable',
          severity: 'review',
        ));
      }
    } else {
      latexMode = 'not_applicable';
    }

    // HTML residue
    final htmlTagPattern = RegExp(
      r'<\s*/?\s*(?:div|p|br|img|span|table|tr|td|th|h[1-6])\b',
      caseSensitive: false,
    );
    if (htmlTagPattern.hasMatch(allText)) {
      issues.add(const AcceptanceQuestionIssue(
        code: 'raw_html_tag',
        severity: 'review',
      ));
    }

    // Image reference — only match explicit image syntax
    final imagePattern = RegExp(
      r'<img\b|!\[.*?\]\(.*?\)|image_placeholder|figure_missing',
      caseSensitive: false,
    );
    if (imagePattern.hasMatch(allText)) {
      issues.add(const AcceptanceQuestionIssue(
        code: 'image_reference_missing',
        severity: 'review',
      ));
    }

    reports.add(AcceptanceQuestionReport(
      questionNumber: qNum,
      questionType: type,
      hasContent: hasContent,
      optionCount: optionCount,
      hasStandardAnswer: hasAnswer,
      hasExplanation: hasExplanation,
      issues: issues,
      latexValidationMode: latexMode,
    ));
  }

  // Structure checks
  final expectedSet = testCase.expectedNumbers.toSet();
  final actualSet = acceptedNumbers.toSet();
  final missingNumbers = expectedSet.difference(actualSet).toList()..sort();

  final seenNumbers = <int>{};
  final duplicateNumbers = <int>[];
  for (final n in acceptedNumbers) {
    if (!seenNumbers.add(n)) {
      duplicateNumbers.add(n);
    }
  }

  final unexpectedNumbers = actualSet.difference(expectedSet).toList()..sort();
  for (final n in unexpectedNumbers) {
    final report = reports.firstWhere((r) => r.questionNumber == n);
    report.issues.add(AcceptanceQuestionIssue(
      code: 'unexpected_question_number',
      severity: 'hard',
    ));
  }
  for (final n in missingNumbers) {
    // Add a virtual report for missing questions
    reports.add(AcceptanceQuestionReport(
      questionNumber: n,
      questionType: -1,
      hasContent: false,
      optionCount: 0,
      hasStandardAnswer: false,
      hasExplanation: false,
      issues: const [
        AcceptanceQuestionIssue(
          code: 'missing_expected_question',
          severity: 'hard',
        ),
      ],
      latexValidationMode: 'not_applicable',
    ));
  }

  final structureFail = questions.length != testCase.expectedQuestionCount ||
      missingNumbers.isNotEmpty ||
      (!testCase.allowDuplicateNumbers && duplicateNumbers.isNotEmpty);

  return AcceptanceQualityResult(
    questionReports: reports,
    structureVerdict: structureFail ? 'fail' : 'pass',
    acceptedNumbers: acceptedNumbers,
    missingNumbers: missingNumbers,
    duplicateNumbers: duplicateNumbers,
  );
}

bool _hasLatexContent(String text) {
  return RegExp(r'\\[(\[]|\\frac|\\sqrt|\\sum|\\int|\\begin\{').hasMatch(text);
}

String _readStr(Object? value) => value?.toString().trim() ?? '';

int? _readInt(Object? value) {
  if (value is int) return value;
  if (value is num) return value.toInt();
  if (value is String) return int.tryParse(value.trim());
  return null;
}

// ---------------------------------------------------------------------------
// Verdict computation
// ---------------------------------------------------------------------------

class AcceptanceVerdict {
  const AcceptanceVerdict({
    required this.verdict,
    required this.exitCode,
  });

  final String verdict; // PASS, REVIEW, FAIL
  final int exitCode;
}

AcceptanceVerdict computeVerdict({
  required AcceptanceQualityResult quality,
  required int repairCandidateCount,
  required String repairMode,
}) {
  if (quality.structureVerdict == 'fail') {
    return const AcceptanceVerdict(verdict: 'FAIL', exitCode: 1);
  }

  final hasHardIssue =
      quality.questionReports.any((r) => r.hasHardIssue);
  if (hasHardIssue) {
    return const AcceptanceVerdict(verdict: 'FAIL', exitCode: 1);
  }

  // Repair was needed but skipped → at least REVIEW
  if (repairMode == 'skipped' && repairCandidateCount > 0) {
    return const AcceptanceVerdict(verdict: 'REVIEW', exitCode: 2);
  }

  final hasReviewIssue =
      quality.questionReports.any((r) => r.hasReviewIssue);
  if (hasReviewIssue) {
    return const AcceptanceVerdict(verdict: 'REVIEW', exitCode: 2);
  }

  return const AcceptanceVerdict(verdict: 'PASS', exitCode: 0);
}

// ---------------------------------------------------------------------------
// Core acceptance runner
// ---------------------------------------------------------------------------

typedef AcceptanceEventEmitter = void Function(Map<String, dynamic> event);

Future<int> runImportAcceptance({
  required String caseId,
  required String repositoryRoot,
  required AcceptanceEventEmitter emitEvent,
  bool refreshOcr = false,
  SavedApiKeyLoader? loadSavedApiKey,
  Map<String, String>? environment,
  AcceptanceReportWriter? reportWriter,
}) async {
  final stopwatch = Stopwatch()..start();
  final env = environment ?? Platform.environment;

  // 1. Load test case
  final ImportAcceptanceCase testCase;
  try {
    testCase = loadAcceptanceCase(
      caseId: caseId,
      repositoryRoot: repositoryRoot,
    );
  } catch (e) {
    emitEvent({
      'stage': 'preflight',
      'status': 'case_not_found',
      'caseId': caseId,
    });
    return 1;
  }

  emitEvent({
    'stage': 'preflight',
    'status': 'case_loaded',
    'caseId': testCase.caseId,
    'expectedQuestionCount': testCase.expectedQuestionCount,
  });

  // 2. Obtain OcrDocument (replay cache or live OCR)
  final OcrDocument document;
  final String sourceMode;
  String cacheFingerprint = '';

  if (refreshOcr) {
    // Live OCR — need API key
    var apiKey = env['SHIROHA_OCR_API_KEY'];
    final useSavedAppKey = env['SHIROHA_OCR_USE_SAVED_APP_KEY'] == 'true';

    if ((apiKey == null || apiKey.trim().isEmpty) && useSavedAppKey) {
      try {
        apiKey = await loadSavedApiKey?.call();
      } catch (_) {
        apiKey = null;
      }
    }

    if (apiKey == null || apiKey.trim().isEmpty) {
      emitEvent({
        'stage': 'preflight',
        'status': 'missing_api_key',
      });
      return 1;
    }

    // Resolve PDF
    final pdfRelative = testCase.pdf;
    final pdfPath = p.join(
      repositoryRoot,
      'scratch',
      'test_pdfs',
      pdfRelative,
    );
    final pdfFile = File(pdfPath);
    if (!pdfFile.existsSync()) {
      emitEvent({
        'stage': 'preflight',
        'status': 'pdf_not_found',
      });
      return 1;
    }

    final baseUrl = env['SHIROHA_OCR_BASE_URL'] ??
        'https://open.bigmodel.cn/api/paas';
    final profile = AiEngineProfile(
      id: 'acceptance-ocr',
      engineType: AiEngineType.ocr,
      name: 'acceptance-zhipu',
      apiKey: apiKey,
      baseUrl: baseUrl,
      modelName: ZhipuOcrClient.model,
      temperature: 0.0,
      reasoningEffort: '',
      isActive: true,
    );

    emitEvent({
      'stage': 'ocr',
      'status': 'live_ocr_started',
    });

    try {
      final ocrClient = const ZhipuOcrClient();
      document = await ocrClient.parseFile(
        profile: profile,
        filePath: pdfPath,
        sourceName: p.basename(pdfPath),
      );
    } catch (e) {
      emitEvent({
        'stage': 'ocr',
        'status': 'live_ocr_failed',
        'causeType': e.runtimeType.toString(),
      });
      return 1;
    }

    // Write replay cache atomically
    final pdfBytes = pdfFile.readAsBytesSync();
    cacheFingerprint = computeReplayCacheFingerprint(
      pdfBytes: pdfBytes,
      documentSchemaVersion: 1,
      ocrModelId: ZhipuOcrClient.model,
    );
    final pdfHash = sha256.convert(pdfBytes).toString();

    try {
      writeReplayCache(
        caseId: caseId,
        repositoryRoot: repositoryRoot,
        document: document,
        fingerprint: cacheFingerprint,
        pdfContentHash: pdfHash,
      );
    } catch (_) {
      // Cache write failure is non-fatal
    }

    sourceMode = 'live';
    emitEvent({
      'stage': 'ocr',
      'status': 'live_ocr_completed',
      'fingerprint': cacheFingerprint,
    });
  } else {
    // Replay from cache
    final cached = loadReplayCache(
      caseId: caseId,
      repositoryRoot: repositoryRoot,
    );
    if (cached == null) {
      emitEvent({
        'stage': 'cache',
        'status': 'replay_cache_missing',
        'caseId': caseId,
      });
      return 1;
    }
    document = cached.document;
    sourceMode = cached.sourceMode;
    cacheFingerprint = cached.fingerprint;
    emitEvent({
      'stage': 'cache',
      'status': 'replay_cache_loaded',
      'fingerprint': cacheFingerprint,
    });
  }

  // 3. Run production parsing pipeline via OcrImportService
  final replayClient = _ReplayOcrClient(document);
  final noOpRepair = _NoOpRepairService();

  // Need a profile for OcrImportService to proceed
  final replayProfile = AiEngineProfile(
    id: 'acceptance-replay',
    engineType: AiEngineType.ocr,
    name: 'acceptance-replay',
    apiKey: 'replay-no-network',
    baseUrl: 'https://open.bigmodel.cn/api/paas',
    modelName: ZhipuOcrClient.model,
    temperature: 0.0,
    reasoningEffort: '',
    isActive: true,
  );
  final replayRepo = _ReplayEngineRepository(replayProfile);

  final ocrImportService = OcrImportService(
    engineRepository: replayRepo,
    ocrClient: replayClient,
    repairService: noOpRepair,
  );

  emitEvent({
    'stage': 'pipeline',
    'status': 'started',
    'sourceMode': sourceMode,
  });

  final ocrResult = await ocrImportService.tryParse(
    filePath: 'replay://acceptance/${testCase.caseId}',
    sourceName: testCase.caseId,
    format: ImportFormat.pdf,
  );

  if (ocrResult == null || !ocrResult.usedOcr || ocrResult.questions.isEmpty) {
    emitEvent({
      'stage': 'pipeline',
      'status': 'pipeline_produced_no_questions',
      'diagnosticStatus': ocrResult?.diagnostics['status'],
    });
    return 1;
  }

  // Apply VisionQuestionQualityGate (matches production)
  final qualityGate = const VisionQuestionQualityGate().evaluate(
    ocrResult.questions,
    sourceName: 'glm_ocr_intermediate',
    documentRole: tryParseImportDocumentRole(
      ocrResult.diagnostics['documentRole'],
    ),
  );

  // Apply ImportQuestionFinalSorter (matches production)
  final sorted = const ImportQuestionFinalSorter().sort(
    qualityGate.questions,
  );
  final finalQuestions = sorted.questions;

  final providerCallCount = refreshOcr ? 1 : 0;
  emitEvent({
    'stage': 'pipeline',
    'status': 'completed',
    'questionCount': finalQuestions.length,
    'repairMode': 'skipped',
    'repairCandidateCount': noOpRepair.candidateCount,
    'providerCallCount': providerCallCount,
  });

  // 4. Acceptance quality checks
  final quality = runAcceptanceQualityChecks(
    questions: finalQuestions,
    testCase: testCase,
  );

  // 5. Compute verdict
  final verdict = computeVerdict(
    quality: quality,
    repairCandidateCount: noOpRepair.candidateCount,
    repairMode: 'skipped',
  );

  stopwatch.stop();

  // 6. Build summary
  final summary = <String, dynamic>{
    'caseId': testCase.caseId,
    'sourceMode': sourceMode,
    'fingerprint': cacheFingerprint,
    'verdict': verdict.verdict,
    'expectedQuestionCount': testCase.expectedQuestionCount,
    'actualQuestionCount': finalQuestions.length,
    'acceptedNumbers': quality.acceptedNumbers,
    'missingNumbers': quality.missingNumbers,
    'duplicateNumbers': quality.duplicateNumbers,
    'repairMode': 'skipped',
    'repairCandidateCount': noOpRepair.candidateCount,
    'hardFailureCount':
        quality.questionReports.where((r) => r.hasHardIssue).length,
    'reviewIssueCount':
        quality.questionReports.where((r) => r.hasReviewIssue).length,
    'questionsWithIssues': quality.questionReports
        .where((r) => r.issues.isNotEmpty)
        .map((r) => r.questionNumber)
        .toList(),
    'durationMs': stopwatch.elapsedMilliseconds,
  };

  // 7. Write reports
  if (reportWriter != null) {
    final regionizerDiagnostics =
        ocrResult.diagnostics['regionizer'] as Map?;
    final candidateTrace =
        regionizerDiagnostics?['questionCandidateTrace'] as List?;

    await reportWriter.write(
      summary: summary,
      questionReports: quality.questionReports,
      candidateTrace: candidateTrace,
      verdict: verdict,
    );
  }

  // 8. Final terminal event
  emitEvent({
    'stage': 'completed',
    'status': verdict.verdict.toLowerCase(),
    'verdict': verdict.verdict,
    'caseId': testCase.caseId,
    'sourceMode': sourceMode,
    'actualQuestionCount': finalQuestions.length,
    'expectedQuestionCount': testCase.expectedQuestionCount,
    'hardFailureCount': summary['hardFailureCount'],
    'reviewIssueCount': summary['reviewIssueCount'],
    'repairMode': 'skipped',
    'repairCandidateCount': noOpRepair.candidateCount,
    'durationMs': stopwatch.elapsedMilliseconds,
  });

  return verdict.exitCode;
}

// ---------------------------------------------------------------------------
// Replay engine repository
// ---------------------------------------------------------------------------

class _ReplayEngineRepository extends AiEngineRepository {
  _ReplayEngineRepository(this._profile);
  final AiEngineProfile _profile;

  @override
  Future<AiEngineProfile?> getActiveOcrEngine() async => _profile;
  @override
  Future<AiEngineProfile?> getActiveTextEngine() async => null;
}

typedef SavedApiKeyLoader = Future<String?> Function();

Future<String?> loadSavedOcrApiKey() async {
  final profile = await AiEngineRepository.instance.getActiveOcrEngine();
  return profile?.apiKey;
}

// ---------------------------------------------------------------------------
// CLI main
// ---------------------------------------------------------------------------

Future<void> main(List<String> args) async {
  final environment = Platform.environment;
  final useSavedAppKey =
      environment['SHIROHA_OCR_USE_SAVED_APP_KEY'] == 'true';
  if (useSavedAppKey && (Platform.isWindows || Platform.isLinux)) {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  }

  String? caseId;
  bool refreshOcr = false;
  for (final arg in args) {
    if (arg.startsWith('--case=')) {
      caseId = arg.substring(7);
    } else if (arg == '--refresh-ocr') {
      refreshOcr = true;
    }
  }

  if (caseId == null || caseId.isEmpty) {
    stderr.writeln('Usage: --case=<caseId> [--refresh-ocr]');
    exit(1);
  }

  final repoRoot = Directory.current.path;

  final exitCode = await runImportAcceptance(
    caseId: caseId,
    repositoryRoot: repoRoot,
    emitEvent: (event) => stdout.writeln(jsonEncode(event)),
    refreshOcr: refreshOcr,
    environment: environment,
    loadSavedApiKey: useSavedAppKey ? loadSavedOcrApiKey : null,
    reportWriter: AcceptanceReportWriter(repositoryRoot: repoRoot),
  );
  exit(exitCode);
}
