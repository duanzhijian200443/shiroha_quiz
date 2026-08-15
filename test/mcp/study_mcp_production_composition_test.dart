// M0.1 production-composition acceptance.
//
// Evidence class: fully synthetic and offline. A Flutter-side handle keeps an
// isolated file-backed v19 database open while a plain-Dart MCP subprocess
// opens the same canonical path through the generic explicit-read-only
// runtime. No fake query ports, user database, network, Provider, OCR, PDF, or
// private source data is used.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:mcp_dart/mcp_dart.dart';
import 'package:path/path.dart' as p;
import 'package:shiroha_quiz/core/database/database_helper.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart' show Database;

import '../application/study_query/study_query_test_support.dart';

const String _productionEntrypoint = 'lib/mcp/study_mcp_composition_root.dart';

String _dartExecutable() {
  try {
    final tester = File(Platform.resolvedExecutable).resolveSymbolicLinksSync();
    final parts = tester.split(Platform.pathSeparator);
    final cacheIndex = parts.lastIndexOf('cache');
    if (cacheIndex > 0) {
      final candidate = <String>[
        ...parts.take(cacheIndex + 1),
        'dart-sdk',
        'bin',
        Platform.isWindows ? 'dart.exe' : 'dart',
      ].join(Platform.pathSeparator);
      if (File(candidate).existsSync()) return candidate;
    }
  } on FileSystemException {
    // Fall through to the configured SDK and PATH lookups.
  }
  final flutterRoot = Platform.environment['FLUTTER_ROOT'];
  if (flutterRoot != null && flutterRoot.isNotEmpty) {
    final candidate = '$flutterRoot${Platform.pathSeparator}bin'
        '${Platform.pathSeparator}cache${Platform.pathSeparator}dart-sdk'
        '${Platform.pathSeparator}bin${Platform.pathSeparator}'
        '${Platform.isWindows ? 'dart.exe' : 'dart'}';
    if (File(candidate).existsSync()) return candidate;
  }
  return 'dart';
}

Future<McpClient> _connectProductionClient(String databasePath) async {
  final client = McpClient(
    const Implementation(
      name: 'study_mcp_production_composition_test',
      version: '0.1.0',
    ),
    options: const McpClientOptions(protocol: McpProtocol.legacy),
  );
  final transport = StdioClientTransport(
    StdioServerParameters(
      command: _dartExecutable(),
      args: <String>[
        'run',
        '--verbosity=error',
        _productionEntrypoint,
        '--database-path',
        databasePath,
      ],
      workingDirectory: Directory.current.path,
      stderrMode: ProcessStartMode.normal,
      restartOnUnexpectedExit: false,
    ),
  );
  try {
    await client.connect(transport);
    return client;
  } catch (_) {
    await client.close();
    rethrow;
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory tempDir;

  setUpAll(initTestDatabaseFactory);

  setUp(() async {
    await resetTestDatabase();
    tempDir = await Directory.systemTemp.createTemp('mcp_production_');
  });

  tearDown(() async {
    try {
      await resetTestDatabase();
    } finally {
      if (tempDir.existsSync()) {
        await tempDir.delete(recursive: true);
      }
    }
  });

  test('App-open database is read through the real production MCP chain',
      () async {
    final databasePath = p.join(tempDir.path, 'shared_v19.db');
    Database? appDatabase;
    Database? probe;
    McpClient? client;
    List<String>? before;
    try {
      appDatabase =
          await DatabaseHelper.instance.openPathForTesting(databasePath);
      await appDatabase.insert('bank_folders', <String, Object?>{
        'bank_name': bankMath,
        'folder_name': 'Synthetic Folder',
      });
      await insertTypedQuestion(
        appDatabase,
        draft: makeDraft('production-composition'),
        storageId: idTyped1,
        createdAt: 100,
        bankName: bankMath,
      );
      await insertReviewState(
        appDatabase,
        questionId: idTyped1,
        state: 3,
        nextReviewTime: 0,
        lapses: 2,
        difficulty: 6.5,
        lastLapseTime: 10,
      );
      before = await snapshotCoreTables(appDatabase);

      client = await _connectProductionClient(databasePath);
      final tools = (await client.listTools()).tools;
      expect(tools, hasLength(6));

      final banksResult = await client.callTool(
        const CallToolRequest(name: 'list_question_banks'),
      );
      expect(banksResult.isError, isFalse);
      final banks = banksResult.structuredContent!['items'] as List<Object?>;
      expect(banks, hasLength(1));
      expect(
        banks.single,
        <String, Object?>{
          'bank_name': bankMath,
          'folder_name': 'Synthetic Folder',
          'question_count': 1,
          'due_count': 1,
          'mastered_count': 1,
        },
      );

      final overviewResult = await client.callTool(
        const CallToolRequest(
          name: 'get_study_overview',
          arguments: <String, Object?>{'timezone': 'UTC'},
        ),
      );
      expect(overviewResult.isError, isFalse);
      expect(
        overviewResult.structuredContent!['data'],
        <String, Object?>{
          'question_count': 1,
          'mastered_count': 1,
          'due_count': 1,
          'today_practice_count': 0,
          'wrong_question_count': 1,
        },
      );

      expect(await snapshotCoreTables(appDatabase), before);
      expect(
        await appDatabase.query(
          'questions',
          where: 'id = ?',
          whereArgs: <Object?>[idTyped1],
        ),
        hasLength(1),
      );
      await client.close();
      client = null;
      await appDatabase.close();
      appDatabase = null;

      expect(File(databasePath).existsSync(), isTrue);
      probe = await DatabaseHelper.instance.openPathForTesting(databasePath);
      final version = await probe.rawQuery('PRAGMA user_version');
      expect(version.single['user_version'], 22);
      expect(await snapshotCoreTables(probe), before);
    } finally {
      await client?.close();
      await probe?.close();
      await appDatabase?.close();
    }
  });
}
