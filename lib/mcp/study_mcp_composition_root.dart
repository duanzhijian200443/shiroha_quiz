/// Composition root for the mcp.study.v0 stdio server.
///
/// Assembles the T0 [StudyQueryService] with its production repository ports
/// and exposes the stdio entrypoint. This file only wires the T0 application
/// layer; it defines no second business semantics.
library;

import 'package:shiroha_quiz/application/study_query/study_query_service.dart';
import 'package:shiroha_quiz/application/modules/module_composition.dart';
import 'package:shiroha_quiz/application/modules/production_modules.dart';
import 'package:shiroha_quiz/core/database/database_helper.dart';
import 'package:shiroha_quiz/core/database/sqflite_runtime.dart';
import 'package:shiroha_quiz/data/repositories/question_repository.dart';
import 'package:shiroha_quiz/data/repositories/review_repository.dart';

import 'study_mcp_server.dart';
import 'study_mcp_module_surface.dart';

/// Builds the production stdio server over the T0 query service.
StudyMcpServer buildStudyMcpServer() {
  final service = StudyQueryService(
    questionQuery: QuestionRepository(),
    metricsQuery: ReviewRepository(),
  );
  final composition = const ModuleComposer().compose([studyModule(service)]);
  return buildStudyMcpServerFromComposition(composition, service)!;
}

String _databasePathFromArguments(List<String> arguments) {
  if (arguments.length != 2 || arguments.first != '--database-path') {
    throw const DatabaseRuntimeException(
      DatabaseRuntimeFailure.invalidPath,
    );
  }
  return arguments[1];
}

/// mcp.study.v0 stdio server entrypoint.
Future<void> main(List<String> arguments) async {
  final databasePath = _databasePathFromArguments(arguments);
  initializeStandaloneDatabaseRuntime();
  DatabaseHelper.configureRuntimeProfile(
    DatabaseRuntimeProfile.explicitReadOnly,
    databasePath: databasePath,
  );
  await buildStudyMcpServer().serveStdio();
}
