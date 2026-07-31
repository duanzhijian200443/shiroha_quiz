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

final _dbAllowedPaths = <PathPredicate>[
  _under('lib/core/database/'),
  _under('lib/data/repositories/'),
];

final _dbBootstrapAllowedPaths = <PathPredicate>[
  ..._dbAllowedPaths,
  _isMain,
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
    reason: 'sqflite FFI setup belongs in app/test bootstrap code only.',
    allowedPaths: [_isMain],
  ),
  LayerBoundaryRule(
    name: 'database-helper-boundary',
    pattern: RegExp(r'\bDatabaseHelper\b'),
    reason:
        'UI, service, and domain logic must reach persistence through repositories.',
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
