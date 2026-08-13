// P6-U0 isolated Preview/Review activation smoke.
//
// This entry is NOT production navigation and is not wired into `main.dart`.
// It composes the full P6 application chain over a synthetic in-memory
// artifact and a real in-memory SQLite database, then opens the bounded
// review screen. No real PDF, OCR, provider, Replay, or network path is
// touched. It exists only to prove that the U0 surface activates against
// the real C0 persistence boundary with synthetic fixtures.
import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'package:shiroha_quiz/core/database/database_helper.dart';
import 'package:shiroha_quiz/data/persistence/question_v2_persistence_mapper.dart';
import 'package:shiroha_quiz/data/repositories/supplemental_answer_persistence_repository.dart';
import 'package:shiroha_quiz/application/parsed_artifacts/parsed_artifact_lifecycle.dart';
import 'package:shiroha_quiz/application/supplemental_answers/supplemental_answer_command.dart';
import 'package:shiroha_quiz/application/supplemental_answers/supplemental_answer_matcher.dart';
import 'package:shiroha_quiz/application/supplemental_answers/supplemental_answer_projector.dart';
import 'package:shiroha_quiz/application/supplemental_answers/supplemental_answer_review_session.dart';
import 'package:shiroha_quiz/application/supplemental_answers/target_question_snapshot_service.dart';
import 'package:shiroha_quiz/domain/assets/parsed_artifact.dart';
import 'package:shiroha_quiz/domain/content/content_node.dart';
import 'package:shiroha_quiz/domain/content/rich_content.dart';
import 'package:shiroha_quiz/domain/question/question_draft_v2.dart';
import 'package:shiroha_quiz/domain/source/source_document.dart';
import 'package:shiroha_quiz/domain/source/source_part.dart';
import 'package:shiroha_quiz/domain/source/source_ref.dart';
import 'package:shiroha_quiz/domain/supplemental_answers/answer_match_record.dart';
import 'package:shiroha_quiz/domain/supplemental_answers/supplemental_answer_scope.dart';
import 'package:shiroha_quiz/ui/pages/supplemental_answer_review_screen.dart';
import 'package:shiroha_quiz/ui/theme/app_theme.dart';

const _bankName = 'P6 Smoke Bank';
const _fileId = 'p6_smoke_file';
const _artifactId = 'p6_smoke_artifact';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  if (Platform.isWindows || Platform.isLinux) {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  }
  DatabaseHelper.configureRuntimeProfile(
    DatabaseRuntimeProfile.isolatedSmokeInMemory,
  );

  final db = await DatabaseHelper.instance.database;
  await _seedSyntheticData(db);

  final snapshot = _syntheticSnapshot();
  const matcher = SupplementalAnswerMatcher();
  const projector = SupplementalAnswerProjector();
  final projection = projector.project(
    SourceDocument(
      sourceId: _artifactId,
      parts: [
        SourceContentPart(
          sourceRef: SourceRef.document(sourceId: _artifactId),
          content: RichContent(nodes: [TextNode('1. x = 1')]),
          role: SourceContentRole.answerLike,
        ),
      ],
    ),
  );
  final matchResult = matcher.match(
    fragments: projection.fragments,
    snapshot: snapshot,
    artifact: const SupplementalArtifactContext(
      supplementalFileId: _fileId,
      artifactId: _artifactId,
      artifactRevision: 1,
    ),
  );
  final session = SupplementalAnswerReviewSession(
    request: SupplementalAnswerMatchRequest(
      targetScope: const QuestionBankScope(bankName: _bankName),
      supplementalFileId: _fileId,
    ),
    snapshot: snapshot,
    matchResult: matchResult,
  );
  final command = SupplementalAnswerConfirmCommand(
    artifactPort: _SmokeArtifactPort(),
    persistencePort: SupplementalAnswerPersistenceRepository(),
  );

  runApp(
    MaterialApp(
      title: 'Shiroha Quiz P6 Review Smoke',
      debugShowCheckedModeBanner: false,
      theme: AppTheme.lightTheme,
      home: SupplementalAnswerReviewScreen(
        session: session,
        confirmCommand: command,
      ),
    ),
  );
}

Future<void> _seedSyntheticData(Database db) async {
  const mapper = QuestionV2PersistenceMapper();
  final draft = QuestionDraftV2(
    questionId: 'smoke_question_1',
    kind: QuestionKind.shortAnswer,
    questionNumber: 1,
    stem: RichContent(nodes: [TextNode('Synthetic stem')]),
  );
  final frozen = mapper.freezeForWrite(
    storageId: candidateStorageId,
    bankName: _bankName,
    createdAt: 1,
    draft: draft,
  );
  await db.insert('questions', frozen.questionRow);
  await db.insert('question_v2_payloads', frozen.payloadRow);
  await db.insert('review_states', <String, Object?>{
    'question_id': candidateStorageId,
    'state': 0,
    'difficulty': 5.0,
    'stability': 0.0,
    'next_review_time': 0,
    'reps': 0,
    'lapses': 0,
  });
  await db.insert('library_files', <String, Object?>{
    'file_id': _fileId,
    'display_name': 'p6-smoke.pdf',
    'mime_type': 'application/pdf',
    'size_bytes': 1,
    'sha256': 'a' * 64,
    'storage_key': 'p6/smoke',
    'created_at': 1,
  });
  await db.insert('parsed_artifact_heads', <String, Object?>{
    'file_id': _fileId,
    'last_revision': 1,
  });
  await db.insert('parsed_artifacts', <String, Object?>{
    'file_id': _fileId,
    'artifact_id': _artifactId,
    'revision': 1,
    'source_sha256': 'b' * 64,
    'cache_key_version': 1,
    'cache_fingerprint': 'p6-smoke',
    'parser_route': 'pdf_text',
    'parser_version': '1.0',
    'options_schema_version': 1,
    'payload_schema_version': 1,
    'storage_key': 'p6/smoke-artifact',
    'payload_sha256': 'c' * 64,
    'size_bytes': 1,
    'published_at': 1,
  });
}

const candidateStorageId = 'a3f9c2e4-5b6d-4e7f-8a9b-0c1d2e3f4a5b';

TargetQuestionSnapshot _syntheticSnapshot() {
  return TargetQuestionSnapshot(
    targets: [
      AnswerTargetReference(
        storageId: candidateStorageId,
        bankName: _bankName,
        draft: _syntheticDraft(),
      ),
    ],
    reports: const [],
  );
}

QuestionDraftV2 _syntheticDraft() {
  return QuestionDraftV2(
    questionId: 'smoke_question_1',
    kind: QuestionKind.shortAnswer,
    questionNumber: 1,
    stem: RichContent(nodes: [TextNode('Synthetic stem')]),
  );
}

class _SmokeArtifactPort implements ParsedArtifactLifecyclePort {
  @override
  Future<ParsedArtifactSnapshot> getCurrentArtifact(String fileId) async {
    return ParsedArtifactSnapshot(
      artifact: ParsedArtifact(
        fileId: _fileId,
        artifactId: _artifactId,
        revision: 1,
        payloadSchemaVersion: 1,
      ),
      sourceDocument: SourceDocument(sourceId: _artifactId, parts: const []),
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
