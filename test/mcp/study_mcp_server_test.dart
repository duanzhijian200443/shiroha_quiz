// mcp.study.v0 stdio server lifecycle acceptance.
//
// Drives the production StudyMcpServer over a real local subprocess: the test
// spawns the offline stdio fixture (test/mcp/fixtures/) with the pinned
// mcp_dart SDK client and runs initialize, tools/list, tools/call (success
// and error envelopes), and close over the process stdin/stdout pipes. No
// network, provider, database, or production filesystem is involved.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:mcp_dart/mcp_dart.dart';
import 'package:shiroha_quiz/mcp/study_mcp_adapter.dart';
import 'package:shiroha_quiz/mcp/study_mcp_composition_root.dart';
import 'package:shiroha_quiz/mcp/study_mcp_server.dart';

import 'fixtures/study_mcp_stdio_fixture.dart';

const String _fixturePath = 'test/mcp/fixtures/study_mcp_stdio_fixture.dart';

/// Resolves the plain Dart executable used to launch the fixture subprocess:
/// the Dart SDK bundled with the running Flutter toolchain, then FLUTTER_ROOT,
/// then a PATH scan, then the bare `dart` command.
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
    // Fall through to the environment and PATH lookups.
  }
  final flutterRoot = Platform.environment['FLUTTER_ROOT'];
  if (flutterRoot != null && flutterRoot.isNotEmpty) {
    final candidate = '$flutterRoot${Platform.pathSeparator}bin'
        '${Platform.pathSeparator}cache${Platform.pathSeparator}dart-sdk'
        '${Platform.pathSeparator}bin${Platform.pathSeparator}'
        '${Platform.isWindows ? 'dart.exe' : 'dart'}';
    if (File(candidate).existsSync()) return candidate;
  }
  if (Platform.isWindows) {
    final separator = Platform.pathSeparator;
    for (final entry in (Platform.environment['PATH'] ?? '').split(';')) {
      if (entry.isEmpty) continue;
      final candidate = entry.endsWith(separator)
          ? '${entry}dart.exe'
          : '$entry$separator' 'dart.exe';
      if (File(candidate).existsSync()) return candidate;
    }
  }
  return 'dart';
}

/// Connects an SDK client to a fresh fixture subprocess over real stdio.
Future<McpClient> _connectStdioClient() async {
  final client = McpClient(
    const Implementation(name: 'study_mcp_stdio_test', version: '0.1.0'),
  );
  await client.connect(
    StdioClientTransport(
      StdioServerParameters(
        command: _dartExecutable(),
        // Run the script directly (not `dart run`): the package's
        // native-assets build hooks print "Running build hooks..." to stdout
        // and would corrupt the newline-delimited protocol stream.
        args: <String>[_fixturePath],
        workingDirectory: Directory.current.path,
        stderrMode: ProcessStartMode.normal,
        restartOnUnexpectedExit: false,
      ),
    ),
  );
  return client;
}

void main() {
  group('registry and composition root', () {
    test('the server exposes exactly the six frozen tool names', () {
      final StudyMcpServer server = buildStdioFixtureServer();
      expect(server.toolNames, StudyMcpAdapter.toolNames);
      expect(server.toolNames, hasLength(6));
      expect(server.isConnected, isFalse);
    });

    test('the composition root assembles a runnable stdio server', () {
      final server = buildStudyMcpServer();
      expect(server.toolNames, StudyMcpAdapter.toolNames);
      expect(server.isConnected, isFalse);
    });
  });

  group('real local stdio subprocess lifecycle', () {
    test('initialize handshake and six READ_ONLY tools/list', () async {
      final client = await _connectStdioClient();
      addTearDown(client.close);

      final tools = (await client.listTools()).tools;
      expect(
        tools.map((tool) => tool.name).toList(),
        unorderedEquals(StudyMcpAdapter.toolNames),
      );
      for (final tool in tools) {
        expect(tool.annotations, isNotNull);
        expect(tool.annotations!.readOnlyHint, isTrue);
        expect(tool.annotations!.destructiveHint, isFalse);
        expect(tool.annotations!.idempotentHint, isTrue);
      }
    });

    test('tools/call round-trips a frozen success envelope over stdio',
        () async {
      final client = await _connectStdioClient();
      addTearDown(client.close);

      final result = await client.callTool(
        const CallToolRequest(name: 'list_question_banks'),
      );
      expect(result.isError, isFalse);
      expect(result.hasStructuredContent, isTrue);
      final envelope = result.structuredContent!;
      expect(envelope['schema_version'], 'mcp.study.v0');
      expect(envelope['generated_at'], '2026-08-08T17:00:00Z');
      expect(envelope['items'], isEmpty);
      expect(envelope['next_cursor'], isNull);
    });

    test('tools/call round-trips the exact error envelope over stdio',
        () async {
      final client = await _connectStdioClient();
      addTearDown(client.close);

      final result = await client.callTool(
        const CallToolRequest(name: 'get_question_detail'),
      );
      expect(result.isError, isTrue);
      final envelope = result.structuredContent!;
      expect(envelope.keys.toSet(), <String>{'schema_version', 'error'});
      final error = envelope['error'] as Map<String, Object?>;
      expect(error['code'], 'invalid_request');
      expect(error['message'], 'The request is invalid.');
      expect(error['retryable'], isFalse);
    });

    test('close tears down the real stdio subprocess connection', () async {
      final client = await _connectStdioClient();
      expect(client.isConnected, isTrue);
      await client.close();
      expect(client.isConnected, isFalse);
    });
  });
}
