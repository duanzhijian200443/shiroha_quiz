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
  });
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
