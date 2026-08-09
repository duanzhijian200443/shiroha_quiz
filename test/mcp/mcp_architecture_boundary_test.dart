// mcp.study.v0 layering guard.
//
// Static source-level checks: the adapter and server never reference
// persistence or filesystem APIs, the adapter reaches only the T0
// application layer, the server registers exactly the six frozen tools, and
// the composition root only assembles the T0 service with its production
// ports. M0 also freezes local-stdio-only transport, the exact mcp_dart 2.4.0
// pin, SDK confinement to lib/mcp/**, and protocol-behavior acceptance.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

final RegExp _importPattern = RegExp(
  r'''^\s*import\s+['"]([^'"]+)['"]''',
  multiLine: true,
);

List<String> _imports(String source) {
  return _importPattern
      .allMatches(source)
      .map((match) => match.group(1)!)
      .toList(growable: false);
}

void _expectForbiddenTokensAbsent(String path, String source) {
  const forbidden = <String>[
    'DatabaseHelper',
    'package:sqflite',
    'sqflite_common_ffi',
    'rawQuery',
    'rawInsert',
    'rawUpdate',
    'dart:io',
    'dart:ffi',
    'question_v2_payloads',
  ];
  final wordBoundary = <RegExp>[
    RegExp(r'\bDatabase\b'),
    RegExp(r'\bSQL\b'),
    RegExp(r'\bFile\b'),
    RegExp(r'\bProject\b'),
    RegExp(r'\bRepository\b'),
  ];
  for (final token in forbidden) {
    expect(
      source.contains(token),
      isFalse,
      reason: '$path must not reference "$token".',
    );
  }
  for (final pattern in wordBoundary) {
    expect(
      pattern.hasMatch(source),
      isFalse,
      reason: '$path must not reference ${pattern.pattern}.',
    );
  }
}

void main() {
  group('mcp.study.v0 layering guard', () {
    final adapterPath = 'lib/mcp/study_mcp_adapter.dart';
    final serverPath = 'lib/mcp/study_mcp_server.dart';
    final compositionRootPath = 'lib/mcp/study_mcp_composition_root.dart';

    test('adapter and server never touch persistence or filesystem APIs', () {
      for (final path in <String>[adapterPath, serverPath]) {
        final file = File(path);
        expect(file.existsSync(), isTrue, reason: 'Required file missing.');
        _expectForbiddenTokensAbsent(path, file.readAsStringSync());
      }
    });

    test('adapter reaches only the T0 application query layer', () {
      final source = File(adapterPath).readAsStringSync();
      for (final uri in _imports(source)) {
        final allowed = uri.startsWith('dart:') ||
            uri.startsWith(
              'package:shiroha_quiz/application/study_query/',
            );
        expect(
          allowed,
          isTrue,
          reason: 'Adapter import "$uri" crosses the layer boundary.',
        );
      }
    });

    test('server depends only on the MCP SDK and the adapter', () {
      final source = File(serverPath).readAsStringSync();
      final allowedUris = <String>[
        'dart:async',
        'dart:convert',
        'study_mcp_adapter.dart',
      ];
      for (final uri in _imports(source)) {
        final allowed =
            allowedUris.contains(uri) || uri.startsWith('package:mcp_dart/');
        expect(
          allowed,
          isTrue,
          reason: 'Server import "$uri" crosses the layer boundary.',
        );
      }
    });

    test('server registers exactly the six frozen tools and nothing else', () {
      final source = File(serverPath).readAsStringSync();
      final registerToolCount = 'registerTool('.allMatches(source).length;
      expect(registerToolCount, 6);
      expect(source, isNot(contains('registerStatelessTool')));
      expect(source, isNot(contains('registerPrompt')));
      expect(source, isNot(contains('registerResource')));
      for (final name in <String>[
        'list_question_banks',
        'get_study_overview',
        'get_due_review_summary',
        'search_questions',
        'get_question_detail',
        'get_weak_questions',
      ]) {
        expect(
          source.contains("'$name'"),
          isTrue,
          reason: 'Frozen tool "$name" is not registered.',
        );
      }
    });

    test('composition root owns only runtime configuration and assembly', () {
      final source = File(compositionRootPath).readAsStringSync();
      expect(source, isNot(contains('class ')));
      for (final token in <String>[
        'rawQuery',
        'rawInsert',
        'rawUpdate',
        'question_v2_payloads',
        'CREATE TABLE',
        'SELECT ',
        'INSERT ',
        'UPDATE ',
        'DELETE ',
      ]) {
        expect(
          source,
          isNot(contains(token)),
          reason: 'Composition root must not define SQL or persistence logic.',
        );
      }
      final allowedUris = <String>[
        'package:shiroha_quiz/application/study_query/study_query_service.dart',
        'package:shiroha_quiz/core/database/database_helper.dart',
        'package:shiroha_quiz/core/database/sqflite_runtime.dart',
        'package:shiroha_quiz/data/repositories/question_repository.dart',
        'package:shiroha_quiz/data/repositories/review_repository.dart',
        'study_mcp_adapter.dart',
        'study_mcp_server.dart',
      ];
      for (final uri in _imports(source)) {
        expect(
          allowedUris.contains(uri),
          isTrue,
          reason: 'Composition root import "$uri" is not pure assembly.',
        );
      }
      expect('main('.allMatches(source).length, 1);
      expect(source, contains('StudyQueryService('));
      expect(source, contains('QuestionRepository()'));
      expect(source, contains('ReviewRepository()'));
      expect(source, contains('DatabaseRuntimeProfile.explicitReadOnly'));
      expect(source, contains("'--database-path'"));
    });

    test('M0 transport is local stdio only, never HTTP/OAuth/remote', () {
      final server = File(serverPath).readAsStringSync();
      final root = File(compositionRootPath).readAsStringSync();
      expect(server, contains('StdioServerTransport'));
      expect(server, contains('Future<void> serveStdio()'));
      expect(server, contains('Future<void> close()'));
      // The production surface is stdio-only: no public arbitrary-Transport
      // connect seam may exist on the server.
      expect(server, isNot(contains('connect(Transport')));
      expect(server, isNot(contains('Transport transport')));
      expect(server, isNot(contains('Future<void> connect(')));
      for (final source in <String>[server, root]) {
        expect(source, contains('serveStdio'));
        for (final token in <String>[
          'StreamableHttp',
          'OAuth',
          'Authorization',
          'WebSocket',
          'http://',
          'https://',
        ]) {
          expect(
            source,
            isNot(contains(token)),
            reason: 'M0 must stay stdio-only; forbidden token "$token".',
          );
        }
      }
    });

    test('mcp_dart is pinned exactly to 2.4.0 with no range or prerelease', () {
      final pubspec = File('pubspec.yaml').readAsStringSync();
      final line = RegExp(r'^\s*mcp_dart:.*$', multiLine: true)
          .firstMatch(pubspec)!
          .group(0)!
          .trim();
      expect(line, 'mcp_dart: 2.4.0');
    });

    test('mcp_dart is imported only under lib/mcp and never by T0', () {
      final offenders = <String>[];
      for (final entity in Directory('lib').listSync(recursive: true)) {
        if (entity is! File || !entity.path.endsWith('.dart')) {
          continue;
        }
        final relative = entity.path.replaceAll('\\', '/');
        if (relative.startsWith('lib/mcp/')) {
          continue;
        }
        if (File(entity.path).readAsStringSync().contains('package:mcp_dart')) {
          offenders.add(relative);
        }
      }
      expect(offenders, isEmpty);
    });

    test('M0 acceptance drives the real mcp_dart protocol over stdio', () {
      final acceptance =
          File('test/mcp/study_mcp_server_test.dart').readAsStringSync();
      expect(acceptance, contains("import 'package:mcp_dart/mcp_dart.dart';"));
      expect(acceptance, contains('McpClient('));
      expect(acceptance, contains('await client.listTools()'));
      expect(acceptance, contains('await client.callTool('));
      // The lifecycle runs against a real local stdio subprocess fixture,
      // not an in-process linked transport.
      expect(acceptance, contains('StdioClientTransport('));
      expect(acceptance, contains('study_mcp_stdio_fixture.dart'));
      final fixture = File('test/mcp/fixtures/study_mcp_stdio_fixture.dart');
      expect(fixture.existsSync(), isTrue);
      expect(fixture.readAsStringSync(), contains('serveStdio()'));

      final productionAcceptance = File(
        'test/mcp/study_mcp_production_composition_test.dart',
      );
      expect(productionAcceptance.existsSync(), isTrue);
      final productionSource = productionAcceptance.readAsStringSync();
      expect(productionSource, contains('study_mcp_composition_root.dart'));
      expect(productionSource, contains("'--database-path'"));
      expect(productionSource, contains('StdioClientTransport('));
      expect(productionSource, isNot(contains('_EmptyQuestionQuery')));
      expect(productionSource, isNot(contains('_EmptyMetricsQuery')));
    });
  });
}
