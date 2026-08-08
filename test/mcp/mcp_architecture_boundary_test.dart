// mcp.study.v0 layering guard.
//
// Static source-level checks: the adapter and server never reference
// persistence or filesystem APIs, the adapter reaches only the T0
// application layer, the server registers exactly the six frozen tools, and
// the composition root only assembles the T0 service with its production
// ports.
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

    test('composition root only assembles the T0 service and its ports', () {
      final source = File(compositionRootPath).readAsStringSync();
      _expectForbiddenTokensAbsent(compositionRootPath, source);
      expect(source, isNot(contains('class ')));
      final allowedUris = <String>[
        'package:shiroha_quiz/application/study_query/study_query_service.dart',
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
    });
  });
}
