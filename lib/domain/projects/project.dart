/// Frozen J0 Project metadata model.
///
/// A [Project] is an optional, long-lived learning context. It is metadata
/// only: it never owns or duplicates file bytes, question banks, questions,
/// sidecars, or review state. [projectId] is stable for the lifetime of the
/// project; [displayName] is the user-visible, renameable label.
///
/// Project-to-asset membership lives in the persistence relation tables
/// (`project_files` / `project_banks`), never on `LibraryFile` or on
/// question/review rows, so unassigned assets always remain valid.
final class Project {
  factory Project({
    required String projectId,
    required String displayName,
    required DateTime createdAt,
  }) {
    if (!_projectIdPattern.hasMatch(projectId)) {
      throw const FormatException(
        'Project identifiers must use the bounded opaque token format.',
      );
    }
    validateDisplayName(displayName);
    // Persistence stores integer milliseconds; normalizing here keeps the
    // model equal to its own durable round trip.
    final normalizedCreatedAt = DateTime.fromMillisecondsSinceEpoch(
      createdAt.millisecondsSinceEpoch,
      isUtc: true,
    );
    return Project._(
      projectId: projectId,
      displayName: displayName,
      createdAt: normalizedCreatedAt,
    );
  }

  const Project._({
    required this.projectId,
    required this.displayName,
    required this.createdAt,
  });

  static final RegExp _projectIdPattern = RegExp(
    r'^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$',
  );

  /// Validates the renameable display label without constructing a model.
  /// Shared by the factory and the rename path so validation stays
  /// single-sourced in the domain.
  static void validateDisplayName(String displayName) {
    if (displayName.trim().isEmpty) {
      throw const FormatException('Project display names must not be empty.');
    }
  }

  final String projectId;
  final String displayName;
  final DateTime createdAt;

  @override
  bool operator ==(Object other) {
    return identical(this, other) ||
        other is Project &&
            projectId == other.projectId &&
            displayName == other.displayName &&
            createdAt == other.createdAt;
  }

  @override
  int get hashCode {
    return Object.hash(projectId, displayName, createdAt);
  }
}
