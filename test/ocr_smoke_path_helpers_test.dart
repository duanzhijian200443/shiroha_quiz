import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

const _caseScript = r"""
param(
    [Parameter(Mandatory = $true)]
    [string]$HelperPath,
    [Parameter(Mandatory = $true)]
    [string]$RepositoryRoot
)

$ErrorActionPreference = 'Stop'
. $HelperPath

$allowedRoot = Join-Path (Join-Path $RepositoryRoot 'scratch') 'test_pdfs'
$unicodeName = -join ([char]0x4E2D, [char]0x6587, [char]0x8BD5, [char]0x5377) + '.pdf'
$cases = @(
    @{ name = 'shorthand'; argument = 'math/single/sample.pdf' },
    @{ name = 'scratchRelative'; argument = 'scratch/test_pdfs/math/single/sample.pdf' },
    @{ name = 'absoluteInside'; argument = (Join-Path $allowedRoot 'math/single/sample.pdf') },
    @{ name = 'parentTraversal'; argument = '../outside.pdf' },
    @{ name = 'absoluteOutside'; argument = (Join-Path $RepositoryRoot 'outside.pdf') },
    @{ name = 'wrongExtension'; argument = 'math/single/sample.png' },
    @{ name = 'missing'; argument = 'math/single/missing.pdf' },
    @{ name = 'unicode'; argument = 'math/single/' + $unicodeName }
)

$results = foreach ($case in $cases) {
    $r = Resolve-SmokePdfPath `
        -PdfArgument $case.argument `
        -RepositoryRoot $RepositoryRoot `
        -AllowedRoot $allowedRoot
    @{
        name = $case.name
        success = $r.Success
        status = if ($r.Success) { $null } else { $r.Status }
        causeType = if ($r.Success) { $null } else { $r.CauseType }
        path = if ($r.Success) { $r.Path } else { $null }
    } | ConvertTo-Json -Compress
}

$results | ForEach-Object { Write-Output $_ }
""";

void main() {
  group('ocr_smoke_path_helpers.ps1', () {
    final helperPath = p.join(
      Directory.current.path,
      'tool',
      'ocr_smoke_path_helpers.ps1',
    );

    Future<ProcessResult> runCases(String repositoryRoot) async {
      final script = File(
        p.join(repositoryRoot, 'run_helper_cases.ps1'),
      )..writeAsStringSync(_caseScript);
      final executable = await _resolvePowerShellExecutable();
      return Process.run(
        executable,
        [
          '-NoProfile',
          '-ExecutionPolicy',
          'Bypass',
          '-File',
          script.path,
          '-HelperPath',
          helperPath,
          '-RepositoryRoot',
          repositoryRoot,
        ],
      );
    }

    test('resolves the three supported PDF path forms and rejects unsafe ones',
        () async {
      final repository = Directory.systemTemp.createTempSync(
        'ocr-smoke-path-',
      );
      addTearDown(() {
        if (repository.existsSync()) {
          repository.deleteSync(recursive: true);
        }
      });

      final allowedRoot = p.join(repository.path, 'scratch', 'test_pdfs');
      final sampleDir = p.join(allowedRoot, 'math', 'single');
      Directory(sampleDir).createSync(recursive: true);
      final samplePdf = p.join(sampleDir, 'sample.pdf');
      File(samplePdf).writeAsBytesSync(const [0x25, 0x50, 0x44, 0x46]);
      const unicodeName = '中文试卷.pdf';
      File(p.join(sampleDir, unicodeName))
          .writeAsBytesSync(const [0x25, 0x50, 0x44, 0x46]);
      File(p.join(repository.path, 'outside.pdf'))
          .writeAsBytesSync(const [0x25, 0x50, 0x44, 0x46]);

      final result = await runCases(repository.path);
      expect(
        result.exitCode,
        0,
        reason: 'stdout=${result.stdout}\nstderr=${result.stderr}',
      );
      final lines = (result.stdout as String)
          .split(RegExp(r'\r?\n'))
          .where((line) => line.trim().isNotEmpty)
          .map((line) => jsonDecode(line) as Map<String, dynamic>)
          .toList();
      expect(lines, hasLength(8));
      Map<String, dynamic> byName(String name) =>
          lines.singleWhere((line) => line['name'] == name);

      final expectedShorthand =
          p.join(allowedRoot, 'math', 'single', 'sample.pdf');

      final shorthand = byName('shorthand');
      expect(shorthand['success'], isTrue);
      expect(_normalizePath(shorthand['path'] as String),
          _normalizePath(expectedShorthand));

      final scratchRelative = byName('scratchRelative');
      expect(scratchRelative['success'], isTrue);
      expect(_normalizePath(scratchRelative['path'] as String),
          _normalizePath(expectedShorthand));

      final absoluteInside = byName('absoluteInside');
      expect(absoluteInside['success'], isTrue);
      expect(_normalizePath(absoluteInside['path'] as String),
          _normalizePath(expectedShorthand));

      final parentTraversal = byName('parentTraversal');
      expect(parentTraversal['success'], isFalse);
      expect(parentTraversal['status'], 'path_outside_repository_root');
      expect(parentTraversal['causeType'], 'PathOutsideRepositoryRoot');

      final absoluteOutside = byName('absoluteOutside');
      expect(absoluteOutside['success'], isFalse);
      expect(absoluteOutside['status'], 'path_outside_repository_root');
      expect(absoluteOutside['causeType'], 'PathOutsideRepositoryRoot');

      final wrongExtension = byName('wrongExtension');
      expect(wrongExtension['success'], isFalse);
      expect(wrongExtension['status'], 'invalid_pdf_extension');
      expect(wrongExtension['causeType'], 'InvalidPdfExtension');

      final missing = byName('missing');
      expect(missing['success'], isFalse);
      expect(missing['status'], 'pdf_not_found');
      expect(missing['causeType'], 'PdfNotFound');

      final unicode = byName('unicode');
      expect(unicode['success'], isTrue);
      expect(_normalizePath(unicode['path'] as String),
          _normalizePath(p.join(sampleDir, unicodeName)));
      expect(
        (unicode['path'] as String).endsWith('中文试卷.pdf'),
        isTrue,
      );

      // Output must not leak the repository root as a standalone field.
      expect(lines.first.keys, isNot(contains('repositoryRoot')));
    });

    test('helper is pure: dot-sourcing emits no output', () async {
      final executable = await _resolvePowerShellExecutable();
      final result = await Process.run(
        executable,
        [
          '-NoProfile',
          '-ExecutionPolicy',
          'Bypass',
          '-Command',
          ". '$helperPath'",
        ],
      );
      expect(result.exitCode, 0);
      expect((result.stdout as String).trim(), isEmpty);
      expect((result.stderr as String).trim(), isEmpty);
    });
  });
}

String _normalizePath(String path) {
  return path.replaceAll('\\', '/').toLowerCase();
}

Future<String> _resolvePowerShellExecutable() async {
  if (!Platform.isWindows) return 'pwsh';
  try {
    final probe = await Process.run(
      'powershell.exe',
      ['-NoProfile', '-Command', r'$true'],
    );
    if (probe.exitCode == 0) return 'powershell.exe';
  } on ProcessException {
    // Fall through to pwsh.
  }
  return 'pwsh';
}
