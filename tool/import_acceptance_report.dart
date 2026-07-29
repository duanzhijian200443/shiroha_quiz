import 'dart:convert';
import 'dart:io';
import 'package:path/path.dart' as p;

import 'import_acceptance.dart';

/// Writes acceptance reports to `scratch/import_acceptance/<run-id>/`.
class AcceptanceReportWriter {
  AcceptanceReportWriter({
    required this.repositoryRoot,
    String? runId,
  }) : runId = runId ?? _generateRunId();

  final String repositoryRoot;
  final String runId;

  static String _generateRunId() {
    final now = DateTime.now();
    final ts = '${now.year}'
        '${now.month.toString().padLeft(2, '0')}'
        '${now.day.toString().padLeft(2, '0')}'
        '-'
        '${now.hour.toString().padLeft(2, '0')}'
        '${now.minute.toString().padLeft(2, '0')}'
        '${now.second.toString().padLeft(2, '0')}';
    final short = now.microsecondsSinceEpoch.toRadixString(16).padLeft(8, '0');
    return 'acceptance-$ts-${short.substring(short.length - 8)}';
  }

  Future<String> write({
    required Map<String, dynamic> summary,
    required List<AcceptanceQuestionReport> questionReports,
    required List? candidateTrace,
    required AcceptanceVerdict verdict,
  }) async {
    final runDir = p.join(
      repositoryRoot,
      'scratch',
      'import_acceptance',
      runId,
    );
    Directory(runDir).createSync(recursive: true);

    // summary.json
    final summaryWithPath = Map<String, dynamic>.from(summary)
      ..['relativeReportDirectory'] = 'scratch/import_acceptance/$runId';
    await _writeJson(runDir, 'summary.json', summaryWithPath);

    // question_quality.json
    await _writeJson(
      runDir,
      'question_quality.json',
      questionReports.map((r) => r.toJson()).toList(),
    );

    // candidate_trace.json
    if (candidateTrace != null) {
      await _writeJson(runDir, 'candidate_trace.json', candidateTrace);
    }

    // agent_brief.md
    final brief = _buildAgentBrief(
      summary: summaryWithPath,
      questionReports: questionReports,
      verdict: verdict,
    );
    File(p.join(runDir, 'agent_brief.md')).writeAsStringSync(brief);

    return runDir;
  }

  Future<void> _writeJson(String dir, String name, Object data) async {
    final encoder = const JsonEncoder.withIndent('  ');
    File(p.join(dir, name)).writeAsStringSync(encoder.convert(data));
  }

  String _buildAgentBrief({
    required Map<String, dynamic> summary,
    required List<AcceptanceQuestionReport> questionReports,
    required AcceptanceVerdict verdict,
  }) {
    final buf = StringBuffer();
    buf.writeln('# Import Acceptance Report');
    buf.writeln();
    buf.writeln(
        'Verdict: **${verdict.verdict}** (exit code ${verdict.exitCode})');
    buf.writeln();
    final expected = summary['expectedQuestionCount'] ?? '?';
    final actual = summary['actualQuestionCount'] ?? '?';
    buf.writeln('Questions: $actual/$expected');
    buf.writeln('Source: ${summary['sourceMode'] ?? 'unknown'}');
    buf.writeln('Duration: ${summary['durationMs'] ?? '?'}ms');
    buf.writeln(
        'Repair: ${summary['repairMode']} (${summary['repairCandidateCount']} candidates)');
    buf.writeln();

    final hardIssues = questionReports.where((r) => r.hasHardIssue).toList();
    final reviewIssues = questionReports
        .where((r) => r.hasReviewIssue && !r.hasHardIssue)
        .toList();

    if (hardIssues.isNotEmpty) {
      buf.writeln('## Hard Failures');
      buf.writeln();
      for (final r in hardIssues) {
        final codes = r.issues
            .where((i) => i.severity == 'hard')
            .map((i) => i.code)
            .join(', ');
        buf.writeln('- Q${r.questionNumber}: $codes');
      }
      buf.writeln();
    }

    if (reviewIssues.isNotEmpty) {
      buf.writeln('## Review Required');
      buf.writeln();
      for (final r in reviewIssues) {
        final codes = r.issues
            .where((i) => i.severity == 'review')
            .map((i) => i.code)
            .join(', ');
        buf.writeln('- Q${r.questionNumber}: $codes');
      }
      buf.writeln();
    }

    if (hardIssues.isEmpty && reviewIssues.isEmpty) {
      buf.writeln('All questions passed quality checks.');
      buf.writeln();
    }

    // Suggested next task
    buf.writeln('## Suggested Next Task');
    buf.writeln();
    if (verdict.verdict == 'PASS') {
      buf.writeln('No action required. All acceptance criteria met.');
    } else if (verdict.verdict == 'REVIEW') {
      if (summary['repairMode'] == 'skipped' &&
          (summary['repairCandidateCount'] as int? ?? 0) > 0) {
        buf.writeln(
            'Run with AI repair enabled to resolve cross-page assembly issues.');
      }
      if (reviewIssues.any(
          (r) => r.issues.any((i) => i.code == 'missing_explicit_answer'))) {
        buf.writeln('Improve subjective answer extraction before other fixes.');
      }
      if (reviewIssues
          .any((r) => r.issues.any((i) => i.code == 'latex_unrenderable'))) {
        buf.writeln('Fix LaTeX delimiter balance in affected questions.');
      }
      if (reviewIssues
          .any((r) => r.issues.any((i) => i.code == 'raw_html_tag'))) {
        buf.writeln('Add HTML tag stripping to post-processing pipeline.');
      }
    } else {
      buf.writeln(
          'Fix structural failures (missing/duplicate questions) first.');
    }
    buf.writeln();

    return buf.toString();
  }
}
