// ignore_for_file: depend_on_referenced_packages

import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;

import 'package:shiroha_quiz/data/models/ai_engine_profile.dart';
import 'package:shiroha_quiz/data/repositories/ai_engine_repository.dart';
import 'package:shiroha_quiz/services/import_pipeline/import_document_role.dart';
import 'package:shiroha_quiz/services/import_pipeline/import_format.dart';
import 'package:shiroha_quiz/services/import_pipeline/import_question_final_sorter.dart';
import 'package:shiroha_quiz/services/import_pipeline/latex_sanity_checker.dart';
import 'package:shiroha_quiz/services/import_pipeline/local_question_assembler.dart';
import 'package:shiroha_quiz/services/import_pipeline/ocr_document.dart';
import 'package:shiroha_quiz/services/import_pipeline/ocr_document_client.dart';
import 'package:shiroha_quiz/services/import_pipeline/ocr_import_service.dart';
import 'package:shiroha_quiz/services/import_pipeline/single_question_repair_service.dart';
import 'package:shiroha_quiz/services/import_pipeline/vision_question_quality_gate.dart';

import 'import_acceptance_report.dart';

const supportedReplayOcrModelId = 'glm-ocr';

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
      expectedNumbers: (json['expectedNumbers'] as List).cast<int>().toList(),
      allowDuplicateNumbers: json['allowDuplicateNumbers'] as bool? ?? false,
    );
  }
}

bool isValidAcceptanceCaseId(String caseId) {
  return RegExp(r'^[A-Za-z0-9_-]+$').hasMatch(caseId);
}

class InvalidAcceptanceCaseIdException implements Exception {
  const InvalidAcceptanceCaseIdException();
}

ImportAcceptanceCase loadAcceptanceCase({
  required String caseId,
  required String repositoryRoot,
}) {
  if (!isValidAcceptanceCaseId(caseId)) {
    throw const InvalidAcceptanceCaseIdException();
  }
  final casesRoot = p.normalize(
    p.absolute(p.join(repositoryRoot, 'tool', 'import_cases')),
  );
  final casePath = p.normalize(p.join(casesRoot, '$caseId.json'));
  if (!p.isWithin(casesRoot, casePath)) {
    throw const InvalidAcceptanceCaseIdException();
  }
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

enum ReplayCacheLoadStatus {
  loaded,
  missing,
  invalid,
}

class ReplayCacheResult {
  const ReplayCacheResult({
    required this.status,
    this.document,
    this.fingerprint,
    this.cacheDirectory,
    this.causeType,
  });

  final ReplayCacheLoadStatus status;
  final OcrDocument? document;
  final String? fingerprint;
  final String? cacheDirectory;
  final String? causeType;

  bool get isLoaded => status == ReplayCacheLoadStatus.loaded;
  bool get isMissing => status == ReplayCacheLoadStatus.missing;
  bool get isInvalid => status == ReplayCacheLoadStatus.invalid;

  String get sourceMode => 'replay';
}

class ReplayCacheWriteResult {
  const ReplayCacheWriteResult({
    required this.caseId,
    required this.fingerprint,
    required this.documentHash,
    required this.reusedExistingDirectory,
  });

  final String caseId;
  final String fingerprint;
  final String documentHash;
  final bool reusedExistingDirectory;
}

ReplayCacheResult loadReplayCache({
  required String caseId,
  required String repositoryRoot,
}) {
  if (caseId.trim().isEmpty || !RegExp(r'^[A-Za-z0-9_-]+$').hasMatch(caseId)) {
    return const ReplayCacheResult(
      status: ReplayCacheLoadStatus.invalid,
      causeType: 'CurrentPointerMismatch',
    );
  }

  final caseRoot = p.join(repositoryRoot, 'scratch', 'ocr_replay', caseId);
  final caseRootDir = Directory(caseRoot);
  if (!caseRootDir.existsSync()) {
    return const ReplayCacheResult(status: ReplayCacheLoadStatus.missing);
  }

  final currentFile = File(p.join(caseRoot, 'current.json'));
  if (!currentFile.existsSync()) {
    return const ReplayCacheResult(status: ReplayCacheLoadStatus.missing);
  }

  // Parse current.json
  Map<String, dynamic> currentJson;
  try {
    final rawCurrent = currentFile.readAsStringSync();
    final decoded = jsonDecode(rawCurrent);
    if (decoded is! Map<String, dynamic>) {
      return const ReplayCacheResult(
        status: ReplayCacheLoadStatus.invalid,
        causeType: 'CurrentPointerFormatException',
      );
    }
    currentJson = decoded;
  } catch (_) {
    return const ReplayCacheResult(
      status: ReplayCacheLoadStatus.invalid,
      causeType: 'CurrentPointerFormatException',
    );
  }

  if (currentJson['schemaVersion'] != 1) {
    return const ReplayCacheResult(
      status: ReplayCacheLoadStatus.invalid,
      causeType: 'ReplaySchemaMismatch',
    );
  }

  final currentCaseId = currentJson['caseId'];
  if (currentCaseId != caseId) {
    return const ReplayCacheResult(
      status: ReplayCacheLoadStatus.invalid,
      causeType: 'CurrentPointerMismatch',
    );
  }

  final fingerprint = currentJson['fingerprint'];
  if (fingerprint is! String ||
      !RegExp(r'^[a-f0-9]{16}$').hasMatch(fingerprint)) {
    return const ReplayCacheResult(
      status: ReplayCacheLoadStatus.invalid,
      causeType: 'CurrentPointerFormatException',
    );
  }

  final updatedAtRaw = currentJson['updatedAtUtc'];
  if (updatedAtRaw is! String || DateTime.tryParse(updatedAtRaw) == null) {
    return const ReplayCacheResult(
      status: ReplayCacheLoadStatus.invalid,
      causeType: 'CurrentPointerFormatException',
    );
  }

  final fingerprintDir = p.join(caseRoot, fingerprint);
  final relativeToCaseRoot = p.relative(fingerprintDir, from: caseRoot);
  if (relativeToCaseRoot.startsWith('..') ||
      p.isAbsolute(relativeToCaseRoot) ||
      relativeToCaseRoot.contains('/') ||
      relativeToCaseRoot.contains(r'\')) {
    return const ReplayCacheResult(
      status: ReplayCacheLoadStatus.invalid,
      causeType: 'CurrentPointerMismatch',
    );
  }

  final targetDir = Directory(fingerprintDir);
  if (!targetDir.existsSync()) {
    return const ReplayCacheResult(
      status: ReplayCacheLoadStatus.invalid,
      causeType: 'ReplayTargetMissing',
    );
  }

  // Parse and validate manifest.json
  final manifestFile = File(p.join(fingerprintDir, 'manifest.json'));
  if (!manifestFile.existsSync()) {
    return const ReplayCacheResult(
      status: ReplayCacheLoadStatus.invalid,
      causeType: 'ReplayTargetMissing',
    );
  }

  Map<String, dynamic> manifestJson;
  try {
    final rawManifest = manifestFile.readAsStringSync();
    final decoded = jsonDecode(rawManifest);
    if (decoded is! Map<String, dynamic>) {
      return const ReplayCacheResult(
        status: ReplayCacheLoadStatus.invalid,
        causeType: 'ReplayManifestFormatException',
      );
    }
    manifestJson = decoded;
  } catch (_) {
    return const ReplayCacheResult(
      status: ReplayCacheLoadStatus.invalid,
      causeType: 'ReplayManifestFormatException',
    );
  }

  if (manifestJson['schemaVersion'] != 1 ||
      manifestJson['ocrDocumentSchemaVersion'] != 1) {
    return const ReplayCacheResult(
      status: ReplayCacheLoadStatus.invalid,
      causeType: 'ReplaySchemaMismatch',
    );
  }

  if (manifestJson['caseId'] != caseId ||
      manifestJson['fingerprint'] != fingerprint) {
    return const ReplayCacheResult(
      status: ReplayCacheLoadStatus.invalid,
      causeType: 'ReplayManifestMismatch',
    );
  }

  if (manifestJson['ocrModelId'] != supportedReplayOcrModelId) {
    return const ReplayCacheResult(
      status: ReplayCacheLoadStatus.invalid,
      causeType: 'ReplayModelMismatch',
    );
  }

  final pdfContentHash = manifestJson['pdfContentHash'];
  final documentHash = manifestJson['documentHash'];
  if (pdfContentHash is! String ||
      !RegExp(r'^[a-f0-9]{64}$').hasMatch(pdfContentHash) ||
      documentHash is! String ||
      !RegExp(r'^[a-f0-9]{64}$').hasMatch(documentHash)) {
    return const ReplayCacheResult(
      status: ReplayCacheLoadStatus.invalid,
      causeType: 'ReplayManifestMismatch',
    );
  }

  final createdAtRaw =
      manifestJson['createdAtUtc'] ?? manifestJson['createdAt'];
  if (createdAtRaw is! String || DateTime.tryParse(createdAtRaw) == null) {
    return const ReplayCacheResult(
      status: ReplayCacheLoadStatus.invalid,
      causeType: 'ReplayManifestMismatch',
    );
  }

  // Parse and validate ocr_document.private.json
  final docFile = File(p.join(fingerprintDir, 'ocr_document.private.json'));
  if (!docFile.existsSync()) {
    return const ReplayCacheResult(
      status: ReplayCacheLoadStatus.invalid,
      causeType: 'ReplayDocumentMissing',
    );
  }

  List<int> docBytes;
  try {
    docBytes = docFile.readAsBytesSync();
  } catch (_) {
    return const ReplayCacheResult(
      status: ReplayCacheLoadStatus.invalid,
      causeType: 'ReplayDocumentMissing',
    );
  }

  final computedHash = sha256.convert(docBytes).toString();
  if (computedHash != documentHash) {
    return const ReplayCacheResult(
      status: ReplayCacheLoadStatus.invalid,
      causeType: 'ReplayDocumentHashMismatch',
    );
  }

  OcrDocument document;
  try {
    final docText = utf8.decode(docBytes);
    final docJson = jsonDecode(docText) as Map<String, dynamic>;
    document = OcrDocument.fromReplayJson(docJson);
  } catch (_) {
    return const ReplayCacheResult(
      status: ReplayCacheLoadStatus.invalid,
      causeType: 'ReplayDocumentFormatException',
    );
  }

  final hasUsableBlocks = document.pages.isNotEmpty &&
      document.pages.any((p) => p.blocks.any((b) => b.text.trim().isNotEmpty));
  if (!hasUsableBlocks) {
    return const ReplayCacheResult(
      status: ReplayCacheLoadStatus.invalid,
      causeType: 'ReplayDocumentEmpty',
    );
  }

  return ReplayCacheResult(
    status: ReplayCacheLoadStatus.loaded,
    document: document,
    fingerprint: fingerprint,
    cacheDirectory: fingerprintDir,
  );
}

ReplayCacheWriteResult writeReplayCache({
  required String caseId,
  required String repositoryRoot,
  required OcrDocument document,
  required String fingerprint,
  required String pdfContentHash,
}) {
  if (caseId.trim().isEmpty || !RegExp(r'^[A-Za-z0-9_-]+$').hasMatch(caseId)) {
    throw ArgumentError('Invalid caseId format: $caseId');
  }
  if (!RegExp(r'^[a-f0-9]{16}$').hasMatch(fingerprint)) {
    throw ArgumentError('Invalid fingerprint format: $fingerprint');
  }
  if (!RegExp(r'^[a-f0-9]{64}$').hasMatch(pdfContentHash)) {
    throw ArgumentError('Invalid pdfContentHash format: $pdfContentHash');
  }

  final caseRoot = p.join(repositoryRoot, 'scratch', 'ocr_replay', caseId);
  Directory(caseRoot).createSync(recursive: true);

  final stagingDirName =
      '.staging-${DateTime.now().microsecondsSinceEpoch}-${Random().nextInt(10000)}';
  final stagingPath = p.join(caseRoot, stagingDirName);
  final stagingDir = Directory(stagingPath);
  stagingDir.createSync(recursive: true);

  String? tmpCurrentPath;

  try {
    const encoder = JsonEncoder.withIndent('  ');
    final docJsonText = encoder.convert(document.toReplayJson());
    final docBytes = utf8.encode(docJsonText);
    final documentHash = sha256.convert(docBytes).toString();

    File(p.join(stagingPath, 'ocr_document.private.json'))
        .writeAsBytesSync(docBytes, flush: true);

    final createdAtUtc = DateTime.now().toUtc().toIso8601String();
    final manifestJson = {
      'schemaVersion': 1,
      'caseId': caseId,
      'fingerprint': fingerprint,
      'ocrDocumentSchemaVersion': 1,
      'ocrModelId': supportedReplayOcrModelId,
      'pdfContentHash': pdfContentHash,
      'documentHash': documentHash,
      'createdAtUtc': createdAtUtc,
    };
    File(p.join(stagingPath, 'manifest.json'))
        .writeAsStringSync(encoder.convert(manifestJson), flush: true);

    // Staging Self-Check
    final checkDocBytes = File(p.join(stagingPath, 'ocr_document.private.json'))
        .readAsBytesSync();
    if (sha256.convert(checkDocBytes).toString() != documentHash) {
      throw StateError('Staging documentHash self-check failed');
    }
    final checkDocJson =
        jsonDecode(utf8.decode(checkDocBytes)) as Map<String, dynamic>;
    final checkDocument = OcrDocument.fromReplayJson(checkDocJson);
    if (checkDocument.pages.isEmpty ||
        !checkDocument.pages
            .any((p) => p.blocks.any((b) => b.text.trim().isNotEmpty))) {
      throw StateError('Staging document self-check empty');
    }

    final targetPath = p.join(caseRoot, fingerprint);
    final targetDir = Directory(targetPath);
    bool reusedExisting = false;

    if (targetDir.existsSync()) {
      final existingDocFile =
          File(p.join(targetPath, 'ocr_document.private.json'));
      final existingManifestFile = File(p.join(targetPath, 'manifest.json'));
      bool isExistingValid = false;
      if (existingDocFile.existsSync() && existingManifestFile.existsSync()) {
        try {
          final exBytes = existingDocFile.readAsBytesSync();
          final exHash = sha256.convert(exBytes).toString();
          if (exHash == documentHash) {
            isExistingValid = true;
          }
        } catch (_) {}
      }

      if (isExistingValid) {
        stagingDir.deleteSync(recursive: true);
        reusedExisting = true;
      } else {
        targetDir.deleteSync(recursive: true);
        stagingDir.renameSync(targetPath);
        reusedExisting = false;
      }
    } else {
      stagingDir.renameSync(targetPath);
      reusedExisting = false;
    }

    // Write current.json.tmp and rename
    final updatedAtUtc = DateTime.now().toUtc().toIso8601String();
    final currentJson = {
      'schemaVersion': 1,
      'caseId': caseId,
      'fingerprint': fingerprint,
      'updatedAtUtc': updatedAtUtc,
    };
    final tmpCurrentName =
        'current.json.tmp-${DateTime.now().microsecondsSinceEpoch}-${Random().nextInt(10000)}';
    tmpCurrentPath = p.join(caseRoot, tmpCurrentName);
    final tmpCurrentFile = File(tmpCurrentPath);
    tmpCurrentFile.writeAsStringSync(encoder.convert(currentJson), flush: true);

    // Verify temp current pointer
    final checkCurrentJson =
        jsonDecode(tmpCurrentFile.readAsStringSync()) as Map<String, dynamic>;
    if (checkCurrentJson['fingerprint'] != fingerprint) {
      throw StateError('Temp current pointer verification failed');
    }

    tmpCurrentFile.renameSync(p.join(caseRoot, 'current.json'));

    // Production loader self-test
    final postWriteLoad = loadReplayCache(
      caseId: caseId,
      repositoryRoot: repositoryRoot,
    );
    if (!postWriteLoad.isLoaded || postWriteLoad.fingerprint != fingerprint) {
      throw StateError('Post-write load self-test failed');
    }

    return ReplayCacheWriteResult(
      caseId: caseId,
      fingerprint: fingerprint,
      documentHash: documentHash,
      reusedExistingDirectory: reusedExisting,
    );
  } catch (_) {
    if (stagingDir.existsSync()) {
      try {
        stagingDir.deleteSync(recursive: true);
      } catch (_) {}
    }
    if (tmpCurrentPath != null) {
      final tmpFile = File(tmpCurrentPath);
      if (tmpFile.existsSync()) {
        try {
          tmpFile.deleteSync();
        } catch (_) {}
      }
    }
    rethrow;
  }
}

// ---------------------------------------------------------------------------
// Stub OCR client for replay (returns cached OcrDocument)
// ---------------------------------------------------------------------------

class _ReplayOcrClient implements OcrDocumentClient {
  _ReplayOcrClient(this._document);

  final OcrDocument _document;
  int callCount = 0;

  @override
  String get modelId => supportedReplayOcrModelId;

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
    final hasExplanation = explanation.isNotEmpty || rawExplanation.isNotEmpty;
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

  final hasHardIssue = quality.questionReports.any((r) => r.hasHardIssue);
  if (hasHardIssue) {
    return const AcceptanceVerdict(verdict: 'FAIL', exitCode: 1);
  }

  // Repair was needed but skipped → at least REVIEW
  if (repairMode == 'skipped' && repairCandidateCount > 0) {
    return const AcceptanceVerdict(verdict: 'REVIEW', exitCode: 2);
  }

  final hasReviewIssue = quality.questionReports.any((r) => r.hasReviewIssue);
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
  AcceptanceReportWriter? reportWriter,
}) async {
  final stopwatch = Stopwatch()..start();

  // 1. Load test case
  final ImportAcceptanceCase testCase;
  if (!isValidAcceptanceCaseId(caseId)) {
    emitEvent({
      'stage': 'launcher',
      'status': 'invalid_case_id',
      'causeType': 'InvalidAcceptanceCaseId',
    });
    return 2;
  }
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

  final cached = loadReplayCache(
    caseId: caseId,
    repositoryRoot: repositoryRoot,
  );
  if (cached.isMissing) {
    emitEvent({
      'stage': 'cache',
      'status': 'replay_cache_missing',
      'caseId': caseId,
    });
    return 1;
  }
  if (cached.isInvalid) {
    emitEvent({
      'stage': 'cache',
      'status': 'replay_cache_invalid',
      'caseId': caseId,
      'causeType': cached.causeType ?? 'ReplayCacheInvalid',
    });
    return 1;
  }
  document = cached.document!;
  sourceMode = cached.sourceMode;
  cacheFingerprint = cached.fingerprint!;
  emitEvent({
    'stage': 'cache',
    'status': 'replay_cache_loaded',
    'caseId': caseId,
    'fingerprint': cacheFingerprint,
  });

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
    modelName: supportedReplayOcrModelId,
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

  emitEvent({
    'stage': 'pipeline',
    'status': 'completed',
    'questionCount': finalQuestions.length,
    'repairMode': 'skipped',
    'repairCandidateCount': noOpRepair.candidateCount,
    'providerCallCount': 0,
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
    final regionizerDiagnostics = ocrResult.diagnostics['regionizer'] as Map?;
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

// ---------------------------------------------------------------------------
// CLI main
// ---------------------------------------------------------------------------

class ImportAcceptanceCliArguments {
  const ImportAcceptanceCliArguments({
    required this.showHelp,
    this.caseId,
    this.repositoryRoot,
  });

  final bool showHelp;
  final String? caseId;
  final String? repositoryRoot;
}

class ImportAcceptanceCliArgumentException implements Exception {
  const ImportAcceptanceCliArgumentException();
}

ImportAcceptanceCliArguments parseImportAcceptanceCliArguments(
  List<String> args,
) {
  var showHelp = false;
  String? caseId;
  String? repositoryRoot;

  for (final arg in args) {
    if (arg == '--help') {
      if (showHelp) throw const ImportAcceptanceCliArgumentException();
      showHelp = true;
      continue;
    }
    if (arg.startsWith('--case=')) {
      if (caseId != null) throw const ImportAcceptanceCliArgumentException();
      caseId = arg.substring('--case='.length);
      if (caseId.isEmpty) {
        throw const ImportAcceptanceCliArgumentException();
      }
      continue;
    }
    if (arg.startsWith('--repository-root=')) {
      if (repositoryRoot != null) {
        throw const ImportAcceptanceCliArgumentException();
      }
      repositoryRoot = arg.substring('--repository-root='.length);
      if (repositoryRoot.isEmpty) {
        throw const ImportAcceptanceCliArgumentException();
      }
      continue;
    }
    throw const ImportAcceptanceCliArgumentException();
  }

  if (showHelp) {
    if (args.length != 1) {
      throw const ImportAcceptanceCliArgumentException();
    }
    return const ImportAcceptanceCliArguments(showHelp: true);
  }
  if (caseId == null) {
    throw const ImportAcceptanceCliArgumentException();
  }
  return ImportAcceptanceCliArguments(
    showHelp: false,
    caseId: caseId,
    repositoryRoot: repositoryRoot,
  );
}

void _emitCliEvent(Map<String, dynamic> event) {
  stdout.writeln(jsonEncode(event));
}

Future<void> main(List<String> args) async {
  final environment = Platform.environment;
  final ImportAcceptanceCliArguments parsed;
  try {
    parsed = parseImportAcceptanceCliArguments(args);
  } on ImportAcceptanceCliArgumentException {
    _emitCliEvent({
      'stage': 'launcher',
      'status': 'invalid_arguments',
      'causeType': 'InvalidArguments',
    });
    exit(2);
  }

  if (parsed.showHelp) {
    stdout.writeln(
      'Usage: --case=<caseId> [--repository-root=<path>]',
    );
    exit(0);
  }

  final caseId = parsed.caseId!;
  if (!isValidAcceptanceCaseId(caseId)) {
    _emitCliEvent({
      'stage': 'launcher',
      'status': 'invalid_case_id',
      'causeType': 'InvalidAcceptanceCaseId',
    });
    exit(2);
  }

  final repoRoot = parsed.repositoryRoot ??
      environment['SHIROHA_REPOSITORY_ROOT'] ??
      Directory.current.path;
  final rootDir = Directory(repoRoot).absolute;
  if (!File(p.join(rootDir.path, 'pubspec.yaml')).existsSync()) {
    _emitCliEvent({
      'stage': 'launcher',
      'status': 'repository_root_invalid',
      'causeType': 'InvalidRepositoryRoot',
    });
    exit(1);
  }

  final exitCode = await runImportAcceptance(
    caseId: caseId,
    repositoryRoot: rootDir.path,
    emitEvent: _emitCliEvent,
    reportWriter: AcceptanceReportWriter(repositoryRoot: rootDir.path),
  );
  exit(exitCode);
}
