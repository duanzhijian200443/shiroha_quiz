import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

typedef PathPredicate = bool Function(String path);

class LayerBoundaryRule {
  final String name;
  final RegExp pattern;
  final String reason;
  final List<PathPredicate> allowedPaths;

  const LayerBoundaryRule({
    required this.name,
    required this.pattern,
    required this.reason,
    required this.allowedPaths,
  });

  bool isAllowed(String normalizedPath) {
    return allowedPaths.any((predicate) => predicate(normalizedPath));
  }
}

class LayerBoundaryViolation {
  final String ruleName;
  final String path;
  final int line;
  final String source;
  final String reason;

  const LayerBoundaryViolation({
    required this.ruleName,
    required this.path,
    required this.line,
    required this.source,
    required this.reason,
  });

  @override
  String toString() {
    return '$path:$line [$ruleName] $reason\n  $source';
  }
}

PathPredicate _under(String prefix) {
  return (String path) => path.startsWith(prefix);
}

bool _isMain(String path) =>
    path == 'lib/main.dart' || path == 'lib/main_ocr_ui_smoke.dart';

/// M0.1: the stdio composition root owns runtime bootstrap and concrete
/// repository wiring; it is the only MCP-layer file allowed to configure
/// the database runtime.
bool _isStudyMcpCompositionRoot(String path) =>
    path == 'lib/mcp/study_mcp_composition_root.dart';

/// M0.1: the standalone SQLite runtime bridge owns the FFI bootstrap.
bool _isStandaloneDatabaseRuntime(String path) =>
    path == 'lib/core/database/sqflite_runtime_standalone.dart';

final _dbAllowedPaths = <PathPredicate>[
  _under('lib/core/database/'),
  _under('lib/data/repositories/'),
];

final _dbBootstrapAllowedPaths = <PathPredicate>[
  ..._dbAllowedPaths,
  _isMain,
  _isStudyMcpCompositionRoot,
];

final _rules = <LayerBoundaryRule>[
  LayerBoundaryRule(
    name: 'sqflite-import-boundary',
    pattern: RegExp(r'''import\s+['"]package:sqflite/sqflite\.dart['"]'''),
    reason:
        'Only DatabaseHelper and repositories may import the low-level sqflite API.',
    allowedPaths: _dbAllowedPaths,
  ),
  LayerBoundaryRule(
    name: 'sqflite-ffi-bootstrap-boundary',
    pattern: RegExp(
        r'''import\s+['"]package:sqflite_common_ffi/sqflite_ffi\.dart['"]'''),
    reason: 'sqflite FFI setup belongs in app/test bootstrap code and the '
        'standalone database runtime bridge only.',
    allowedPaths: [_isMain, _isStandaloneDatabaseRuntime],
  ),
  LayerBoundaryRule(
    name: 'database-helper-boundary',
    pattern: RegExp(r'\bDatabaseHelper\b'),
    reason: 'UI, service, and domain logic must reach persistence through '
        'repositories; only the MCP stdio composition root may own runtime '
        'bootstrap outside data layers.',
    allowedPaths: _dbBootstrapAllowedPaths,
  ),
  LayerBoundaryRule(
    name: 'raw-sql-boundary',
    pattern: RegExp(r'\brawQuery\s*\('),
    reason:
        'Raw SQL belongs inside DatabaseHelper or repository implementations.',
    allowedPaths: _dbAllowedPaths,
  ),
  LayerBoundaryRule(
    name: 'transaction-boundary',
    pattern: RegExp(r'\.transaction\s*\('),
    reason: 'SQLite transactions are repository/database responsibilities.',
    allowedPaths: _dbAllowedPaths,
  ),
];

final _domainDirectivePattern =
    RegExp(r'''^\s*(?:import|export)\s+['"]([^'"]+)['"]''');

final _applicationImportDirectivePattern = RegExp(
  r'^\s*import\b[\s\S]*?;',
  multiLine: true,
);

final _dartSingleLineStringPattern = RegExp(
  r'''(?:r)?'(?:\\.|[^'\\])*'|(?:r)?"(?:\\.|[^"\\])*"''',
);

const _forbiddenDomainUris = <String>{
  'dart:io',
  'dart:ui',
};

const _forbiddenDomainPackagePrefixes = <String>[
  'package:flutter/',
  'package:http/',
  'package:provider/',
  'package:sqflite/',
  'package:sqflite_common_ffi/',
];

const _allowedApplicationSdkUris = <String>{
  'dart:async',
  'dart:collection',
  'dart:convert',
  'dart:math',
  'dart:typed_data',
};

final _forbiddenProjectLayerPattern =
    RegExp(r'(?:^|/)(?:core|data|services|ui)(?:/|$)');

const _r1bDomainValueObjectPaths = <String>[
  'lib/domain/source/source_ref.dart',
  'lib/domain/assets/asset_ref.dart',
  'lib/domain/import/import_issue.dart',
];

const _forbiddenR1bApiNames = <String>[
  'path',
  'uri',
  'url',
  'base64',
  'bytes',
  'rawText',
  'message',
  'exception',
  'stackTrace',
  'diagnostics',
  'providerResponse',
  'questionIndex',
];

const _r2aSourceModelPaths = <String>[
  'lib/domain/source/source_document.dart',
  'lib/domain/source/source_part.dart',
];

const _forbiddenR2aApiNames = <String>[
  'path',
  'absolutePath',
  'originalPath',
  'resolvedPath',
  'extractedPath',
  'cachePath',
  'temporaryPath',
  'uri',
  'url',
  'base64',
  'bytes',
  'rawText',
  'fullContent',
  'providerText',
  'rawResponse',
  'providerRequest',
  'providerResponse',
  'requestBody',
  'responseBody',
  'diagnostics',
  'preview',
  'exception',
  'stackTrace',
  'credential',
  'apiKey',
  'relationshipId',
  'File',
  'Uri',
  'ImageProvider',
];

void main() {
  group('architecture boundaries', () {
    test('UI and services do not access SQLite directly', () {
      final violations = <LayerBoundaryViolation>[];

      for (final file in _dartFilesUnder('lib')) {
        final normalizedPath = _normalizePath(file.path);
        final lines = file.readAsLinesSync();

        for (var index = 0; index < lines.length; index++) {
          final source = lines[index];
          for (final rule in _rules) {
            if (rule.isAllowed(normalizedPath)) {
              continue;
            }
            if (rule.pattern.hasMatch(source)) {
              violations.add(
                LayerBoundaryViolation(
                  ruleName: rule.name,
                  path: normalizedPath,
                  line: index + 1,
                  source: source.trim(),
                  reason: rule.reason,
                ),
              );
            }
          }
        }
      }

      expect(
        violations,
        isEmpty,
        reason:
            'Architecture boundary violations found:\n${violations.join('\n\n')}',
      );
    });

    test('P5.2 typed repair stays on the typed mutation path', () {
      final repair = File('lib/ui/pages/typed_answer_repair_screen.dart');
      expect(
        repair.existsSync(),
        isTrue,
        reason: 'Required typed repair screen is missing.',
      );
      final source = repair.readAsStringSync();
      expect(
        source,
        isNot(contains('question_edit_screen.dart')),
        reason: 'The typed repair screen must never open the legacy editor.',
      );
      expect(
        source,
        isNot(contains('updateQuestion(')),
        reason: 'The typed mutation path must never call the legacy '
            'updateQuestion(Map) API.',
      );
      expect(
        source,
        isNot(contains('question_v2_persistence_mapper.dart')),
        reason: 'The typed repair UI must never depend on the persistence '
            'mapper or its V1 compatibility projection.',
      );
      expect(
        source,
        isNot(contains('projectLegacyContent')),
        reason: 'The typed repair UI must never seed editor text through the '
            'legacy compatibility projection.',
      );
    });

    test('UI files never reference the raw V2 payload table', () {
      final violations = <String>[];
      for (final file in _dartFilesUnder('lib/ui')) {
        if (file.readAsStringSync().contains('question_v2_payloads')) {
          violations.add(_normalizePath(file.path));
        }
      }
      expect(
        violations,
        isEmpty,
        reason: 'UI must reach persistence only through repositories:\n'
            '${violations.join('\n')}',
      );
    });

    test('PracticePage exposes no typed repair entry', () {
      final practice = File('lib/ui/pages/practice_page.dart');
      expect(practice.existsSync(), isTrue);
      final source = practice.readAsStringSync();
      expect(source, isNot(contains('typed_answer_repair_screen')));
      expect(source, isNot(contains('TypedAnswerRepairScreen')));
      expect(source, isNot(contains('onRepairTypedAnswer')));
    });

    test('domain stays independent from platform and infrastructure layers',
        () {
      final violations = <LayerBoundaryViolation>[];

      for (final file in _dartFilesUnder('lib/domain')) {
        final normalizedPath = _normalizePath(file.path);
        final lines = file.readAsLinesSync();

        for (var index = 0; index < lines.length; index++) {
          final source = lines[index];
          final match = _domainDirectivePattern.firstMatch(source);
          if (match == null) continue;

          final uri = match.group(1)!;
          if (!_isForbiddenDomainUri(uri)) continue;

          violations.add(
            LayerBoundaryViolation(
              ruleName: 'domain-dependency-boundary',
              path: normalizedPath,
              line: index + 1,
              source: source.trim(),
              reason:
                  'Domain code must not depend on platform, infrastructure, '
                  'provider, persistence, service, or UI libraries.',
            ),
          );
        }
      }

      expect(
        violations,
        isEmpty,
        reason: 'Domain boundary violations found:\n${violations.join('\n\n')}',
      );
    });

    test('application stays pure and depends only on domain or application',
        () {
      final violations = <LayerBoundaryViolation>[];

      for (final file in _dartFilesUnder('lib/application')) {
        final normalizedPath = _normalizePath(file.path);
        final source = file.readAsStringSync();

        for (final directive
            in _applicationImportDirectivePattern.allMatches(source)) {
          final directiveSource = directive.group(0)!;
          final line =
              '\n'.allMatches(source.substring(0, directive.start)).length + 1;
          for (final uri in _applicationImportUris(directiveSource)) {
            if (_isAllowedApplicationDependency(normalizedPath, uri)) continue;

            violations.add(
              LayerBoundaryViolation(
                ruleName: 'application-dependency-boundary',
                path: normalizedPath,
                line: line,
                source: directiveSource.trim(),
                reason: 'Application code may depend only on the pure SDK '
                    'allowlist, domain, or the application layer.',
              ),
            );
          }
        }
      }

      expect(
        violations,
        isEmpty,
        reason:
            'Application boundary violations found:\n${violations.join('\n\n')}',
      );
    });

    group('application dependency allowlist', () {
      const importingFile = 'lib/application/import_review/review_session.dart';

      test('rejects non-allowlisted SDK, third-party, and project targets', () {
        const rejectedUris = <String>[
          'dart:ffi',
          'dart:io',
          'dart:ui',
          'package:shared_preferences/shared_preferences.dart',
          'package:file_picker/file_picker.dart',
          'package:flutter/material.dart',
          'package:http/http.dart',
          'package:provider/provider.dart',
          'package:sqflite/sqflite.dart',
          'package:sqflite_common_ffi/sqflite_ffi.dart',
          'package:shiroha_quiz/services/import_service.dart',
          '../../services/import_service.dart',
          '../../core/database/database_helper.dart',
          '../../data/repositories/import_task_repository.dart',
          '../../ui/screens/import_screen.dart',
        ];

        for (final uri in rejectedUris) {
          expect(
            _isAllowedApplicationDependency(importingFile, uri),
            isFalse,
            reason: 'Expected application dependency rejected: $uri',
          );
        }
      });

      test('allows pure SDK, domain, and application targets', () {
        const allowedUris = <String>[
          'dart:async',
          'dart:collection',
          'dart:convert',
          'dart:math',
          'dart:typed_data',
          '../../domain/content/content_node.dart',
          '../../domain/question/question_draft_v2.dart',
          '../review_metrics.dart',
          'package:shiroha_quiz/domain/source/source_document.dart',
          'package:shiroha_quiz/application/import_review/review_session.dart',
        ];

        for (final uri in allowedUris) {
          expect(
            _isAllowedApplicationDependency(importingFile, uri),
            isTrue,
            reason: 'Expected application dependency allowed: $uri',
          );
        }
      });

      test('A rejects a forbidden URI in a multiline conditional import', () {
        const source = """
import '../../domain/content/content_node.dart'
    if (dart.library.io) '../../services/import_service.dart';
""";

        final uris = _applicationImportUris(source);
        expect(uris, hasLength(2));
        expect(
          uris.where(
            (uri) => !_isAllowedApplicationDependency(importingFile, uri),
          ),
          ['../../services/import_service.dart'],
        );
      });

      test('B inspects every URI in multiple conditional branches', () {
        const source = """
import '../../domain/content/content_node.dart'
    if (dart.library.io) '../../services/import_service.dart'
    if (dart.library.html) '../../ui/screens/import_screen.dart';
""";

        expect(
          _applicationImportUris(source),
          [
            '../../domain/content/content_node.dart',
            '../../services/import_service.dart',
            '../../ui/screens/import_screen.dart',
          ],
        );
      });

      test('C allows an unprefixed sibling relative import', () {
        expect(
          _isAllowedApplicationDependency(importingFile, 'review_helper.dart'),
          isTrue,
        );
      });

      test('D rejects normalized paths that resolve to forbidden layers', () {
        const rejectedUris = <String>[
          'package:shiroha_quiz/application/../services/import_service.dart',
          '../import_review/../../services/import_service.dart',
        ];

        for (final uri in rejectedUris) {
          expect(
            _isAllowedApplicationDependency(importingFile, uri),
            isFalse,
            reason: 'Expected normalized forbidden dependency rejected: $uri',
          );
        }
      });

      test('E rejects paths that underflow their logical root', () {
        const rejectedUris = <String>[
          '../../../../../../outside.dart',
          'package:shiroha_quiz/../outside.dart',
        ];

        for (final uri in rejectedUris) {
          expect(
            _isAllowedApplicationDependency(importingFile, uri),
            isFalse,
            reason: 'Expected root-underflow dependency rejected: $uri',
          );
        }
      });

      test('F preserves simple import extraction and allowlist behavior', () {
        const source = "import 'dart:async';";

        expect(_applicationImportUris(source), ['dart:async']);
        expect(
          _isAllowedApplicationDependency(
            importingFile,
            _applicationImportUris(source).single,
          ),
          isTrue,
        );
      });
    });

    test('R1B value objects expose no content or locator payload API', () {
      final violations = <LayerBoundaryViolation>[];

      for (final path in _r1bDomainValueObjectPaths) {
        final file = File(path);
        if (!file.existsSync()) {
          violations.add(
            LayerBoundaryViolation(
              ruleName: 'r1b-safe-api-boundary',
              path: path,
              line: 0,
              source: '<missing>',
              reason: 'Required R1B domain value object is missing.',
            ),
          );
          continue;
        }

        final lines = file.readAsLinesSync();
        for (var index = 0; index < lines.length; index++) {
          final source = lines[index];
          for (final name in _forbiddenR1bApiNames) {
            if (!RegExp('\\b${RegExp.escape(name)}\\b').hasMatch(source)) {
              continue;
            }
            violations.add(
              LayerBoundaryViolation(
                ruleName: 'r1b-safe-api-boundary',
                path: path,
                line: index + 1,
                source: source.trim(),
                reason:
                    'R1B domain value objects must not expose unsafe payload '
                    'or locator fields.',
              ),
            );
          }
        }
      }

      expect(
        violations,
        isEmpty,
        reason:
            'Unsafe R1B API declarations found:\n${violations.join('\n\n')}',
      );
    });

    test('R2A source models expose no locator or side-channel payload API', () {
      final violations = <LayerBoundaryViolation>[];

      for (final path in _r2aSourceModelPaths) {
        final file = File(path);
        if (!file.existsSync()) {
          violations.add(
            LayerBoundaryViolation(
              ruleName: 'r2a-safe-api-boundary',
              path: path,
              line: 0,
              source: '<missing>',
              reason: 'Required R2A source domain model is missing.',
            ),
          );
          continue;
        }

        final lines = file.readAsLinesSync();
        for (var index = 0; index < lines.length; index++) {
          final source = lines[index];
          final declarationSource = _withoutDartStringsAndLineComment(source);
          for (final name in _forbiddenR2aApiNames) {
            if (!RegExp('\\b${RegExp.escape(name)}\\b')
                .hasMatch(declarationSource)) {
              continue;
            }
            violations.add(
              LayerBoundaryViolation(
                ruleName: 'r2a-safe-api-boundary',
                path: path,
                line: index + 1,
                source: source.trim(),
                reason: 'R2A source models must not expose unsafe payload or '
                    'locator fields.',
              ),
            );
          }
        }
      }

      expect(
        violations,
        isEmpty,
        reason:
            'Unsafe R2A API declarations found:\n${violations.join('\n\n')}',
      );
    });

    test('J0 Project layers stay pure and never touch typed persistence', () {
      const j0PureFiles = <String>[
        'lib/domain/projects/project.dart',
        'lib/application/projects/project_repository.dart',
        'lib/application/projects/project_service.dart',
      ];
      for (final path in j0PureFiles) {
        final file = File(path);
        expect(
          file.existsSync(),
          isTrue,
          reason: 'Required J0 Project file is missing: $path',
        );
        final source = file.readAsStringSync();
        expect(
          source,
          isNot(contains('DatabaseHelper')),
          reason: '$path must not reach persistence directly.',
        );
        expect(
          source,
          isNot(contains('sqflite')),
          reason: '$path must not depend on the low-level database API.',
        );
        expect(
          source,
          isNot(contains('rawQuery')),
          reason: '$path must not execute raw SQL.',
        );
        expect(
          source,
          isNot(contains('.transaction(')),
          reason: '$path must not own SQLite transactions.',
        );
      }

      // J0-I5/J0-I8: the data repository may read `library_files` for
      // relation integrity, but must never reference typed persistence or
      // review tables by identifier.
      final dataRepository =
          File('lib/data/repositories/project_repository.dart');
      expect(
        dataRepository.existsSync(),
        isTrue,
        reason: 'Required J0 data repository is missing.',
      );
      final dataSource = dataRepository.readAsStringSync();
      for (final table in const <String>[
        'question_v2_payloads',
        'review_states',
        'review_logs',
      ]) {
        expect(
          dataSource,
          isNot(contains(table)),
          reason: 'The J0 Project repository must never read or write $table.',
        );
      }
    });

    test('F0.1 Folder layers stay pure and Folder-only', () {
      const pureFiles = <String>[
        'lib/domain/assets/library_folder.dart',
        'lib/application/file_library/library_folder_repository.dart',
        'lib/application/file_library/library_folder_service.dart',
      ];
      for (final path in pureFiles) {
        final file = File(path);
        expect(file.existsSync(), isTrue, reason: 'Missing F0.1 file: $path');
        final source = file.readAsStringSync();
        for (final token in const <String>[
          'DatabaseHelper',
          'package:sqflite',
          'rawQuery',
          '.transaction(',
          'package:flutter',
        ]) {
          expect(
            source,
            isNot(contains(token)),
            reason: '$path must not depend on $token.',
          );
        }
      }

      final repository =
          File('lib/data/repositories/library_folder_repository.dart');
      expect(repository.existsSync(), isTrue);
      final source = repository.readAsStringSync();
      for (final forbiddenTable in const <String>[
        'projects',
        'project_files',
        'project_banks',
        'questions',
        'question_v2_payloads',
        'review_states',
        'review_logs',
        'bank_folders',
      ]) {
        expect(
          source,
          isNot(contains("'$forbiddenTable'")),
          reason: 'Folder repository must not reference $forbiddenTable.',
        );
      }
    });

    test('U1 presentation depends only on its application facade', () {
      const u1Paths = <String>[
        'lib/ui/pages/main_screen.dart',
        'lib/ui/assistant/assistant_screen.dart',
        'lib/ui/assistant/assistant_workspace_shell.dart',
        'lib/ui/assistant/global_sidebar.dart',
        'lib/ui/assistant/learning_spaces_screen.dart',
        'lib/ui/assistant/workspace_controller.dart',
        'lib/ui/assistant/workspace_pages.dart',
      ];
      const forbidden = <String>[
        'DatabaseHelper',
        'package:sqflite',
        '/data/repositories/',
        r'\data\repositories\',
        'LibraryFileRepository(',
        'SqliteProjectRepository(',
        'QuestionRepository(',
      ];

      for (final path in u1Paths) {
        final file = File(path);
        expect(file.existsSync(), isTrue, reason: 'Missing U1 file: $path');
        final source = file.readAsStringSync();
        for (final token in forbidden) {
          expect(
            source,
            isNot(contains(token)),
            reason: '$path must not depend on U1-forbidden token $token.',
          );
        }
      }
    });
  });
}

String _withoutDartStringsAndLineComment(String source) {
  final withoutStrings = source.replaceAll(_dartSingleLineStringPattern, '');
  final commentStart = withoutStrings.indexOf('//');
  return commentStart < 0
      ? withoutStrings
      : withoutStrings.substring(0, commentStart);
}

bool _isForbiddenDomainUri(String uri) {
  if (_forbiddenDomainUris.contains(uri)) return true;
  if (_forbiddenDomainPackagePrefixes.any(uri.startsWith)) return true;

  final normalizedUri = _normalizePath(uri);
  return _forbiddenProjectLayerPattern.hasMatch(normalizedUri);
}

bool _isAllowedApplicationDependency(String importingPath, String uri) {
  final resolved = _resolveApplicationDependency(importingPath, uri);
  if (resolved == null) return false;

  if (_allowedApplicationSdkUris.contains(resolved)) return true;
  return resolved.startsWith('lib/application/') ||
      resolved.startsWith('lib/domain/');
}

List<String> _applicationImportUris(String directiveSource) {
  return _dartSingleLineStringPattern
      .allMatches(directiveSource)
      .map((match) => _dartStringValue(match.group(0)!))
      .toList(growable: false);
}

String _dartStringValue(String literal) {
  final quoteIndex = literal.startsWith('r') ? 1 : 0;
  return literal.substring(quoteIndex + 1, literal.length - 1);
}

/// Resolves an import/export URI to a canonical project path or SDK URI.
///
/// Returns null for any URI that cannot resolve inside this project, such as
/// third-party packages or absolute paths.
String? _resolveApplicationDependency(String importingPath, String uri) {
  if (uri.startsWith('dart:')) {
    return uri;
  }
  if (uri.startsWith('package:shiroha_quiz/')) {
    return _normalizeSegments(
      const ['lib'],
      uri.substring('package:shiroha_quiz/'.length),
      minimumDepth: 1,
    );
  }
  if (uri.startsWith('package:')) {
    return null;
  }
  if (uri.startsWith('/') || uri.contains(':')) {
    return null;
  }

  final importingDirectory = _parentDirectory(importingPath);
  return _normalizeSegments(importingDirectory.split('/'), uri);
}

String _parentDirectory(String path) {
  final normalized = _normalizePath(path);
  final slash = normalized.lastIndexOf('/');
  return slash < 0 ? '' : normalized.substring(0, slash);
}

String? _normalizeSegments(
  Iterable<String> baseSegments,
  String path, {
  int minimumDepth = 0,
}) {
  final resolved = baseSegments
      .where((segment) => segment.isNotEmpty && segment != '.')
      .toList();
  for (final segment in _normalizePath(path).split('/')) {
    if (segment == '..') {
      if (resolved.length <= minimumDepth) return null;
      resolved.removeLast();
    } else if (segment == '.' || segment.isEmpty) {
      continue;
    } else {
      resolved.add(segment);
    }
  }
  return resolved.join('/');
}

Iterable<File> _dartFilesUnder(String rootPath) {
  final root = Directory(rootPath);
  if (!root.existsSync()) {
    return const Iterable<File>.empty();
  }

  return root
      .listSync(recursive: true)
      .whereType<File>()
      .where((file) => file.path.endsWith('.dart'));
}

String _normalizePath(String path) {
  return path.replaceAll(r'\', '/');
}
