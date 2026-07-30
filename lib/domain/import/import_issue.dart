import '../source/source_ref.dart';

final _issueCodePattern = RegExp(r'^[a-z][a-z0-9]*(?:_[a-z0-9]+)*$');

enum ImportIssueSeverity { error, warning, info }

enum ImportIssueField {
  stem,
  options,
  answer,
  explanation,
  asset,
  source,
  question,
}

final class ImportIssue {
  factory ImportIssue({
    required String code,
    required ImportIssueSeverity severity,
    ImportIssueField? field,
    SourceRef? sourceRef,
  }) {
    if (code.length > 64 || !_issueCodePattern.hasMatch(code)) {
      throw const FormatException(
        'Import issue codes must use bounded lower snake case.',
      );
    }
    return ImportIssue._(
      code: code,
      severity: severity,
      field: field,
      sourceRef: sourceRef,
    );
  }

  const ImportIssue._({
    required this.code,
    required this.severity,
    required this.field,
    required this.sourceRef,
  });

  final String code;
  final ImportIssueSeverity severity;
  final ImportIssueField? field;
  final SourceRef? sourceRef;

  @override
  bool operator ==(Object other) {
    return identical(this, other) ||
        other is ImportIssue &&
            code == other.code &&
            severity == other.severity &&
            field == other.field &&
            sourceRef == other.sourceRef;
  }

  @override
  int get hashCode => Object.hash(code, severity, field, sourceRef);
}
