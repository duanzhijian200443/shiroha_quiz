enum ImportDocumentRole {
  stemOnly,
  answerBearing,
  ambiguous,
}

ImportDocumentRole? tryParseImportDocumentRole(Object? raw) {
  final name = raw?.toString().trim();
  if (name == null || name.isEmpty) return null;
  for (final role in ImportDocumentRole.values) {
    if (role.name == name) return role;
  }
  return null;
}
