enum ImportDiagnosticSeverity {
  info,
  warning,
  error,
}

class ImportDiagnosticMessage {
  final ImportDiagnosticSeverity severity;
  final String title;
  final String message;
  final String? source;
  final String? code;

  ImportDiagnosticMessage({
    required this.severity,
    required this.title,
    required this.message,
    this.source,
    this.code,
  });

  @override
  String toString() {
    return 'ImportDiagnosticMessage(severity: $severity, title: $title, message: $message, source: $source, code: $code)';
  }
}
