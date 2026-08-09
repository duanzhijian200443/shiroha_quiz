library;

import '../study_query/study_query_dtos.dart';

enum FileLibraryView { all, recent, unclassified }

enum McpCapabilityState { configuredAvailable }

enum McpTransport { localStdio }

enum McpPermission { readOnly }

final class McpWorkspaceProjection {
  McpWorkspaceProjection({
    required this.state,
    required this.transport,
    required this.permission,
    required List<String> toolNames,
  }) : toolNames = List<String>.unmodifiable(toolNames);

  final McpCapabilityState state;
  final McpTransport transport;
  final McpPermission permission;
  final List<String> toolNames;
}

final class LibraryFileSummary {
  const LibraryFileSummary({
    required this.fileId,
    required this.displayName,
    required this.mimeType,
    required this.sizeBytes,
    required this.createdAt,
  });

  final String fileId;
  final String displayName;
  final String mimeType;
  final int sizeBytes;
  final DateTime createdAt;
}

final class LearningSpaceSummary {
  const LearningSpaceSummary({
    required this.projectId,
    required this.displayName,
    required this.createdAt,
    required this.fileCount,
    required this.bankCount,
  });

  final String projectId;
  final String displayName;
  final DateTime createdAt;
  final int fileCount;
  final int bankCount;
}

final class LearningSpaceBankReference {
  const LearningSpaceBankReference({
    required this.bankName,
    required this.summary,
  });

  final String bankName;
  final QuestionBankSummary? summary;

  bool get isMissing => summary == null;
}

final class LearningSpaceDetail {
  const LearningSpaceDetail({
    required this.summary,
    required this.files,
    required this.banks,
  });

  final LearningSpaceSummary summary;
  final List<LibraryFileSummary> files;
  final List<LearningSpaceBankReference> banks;
}

final class LibraryFileDetail {
  const LibraryFileDetail({
    required this.file,
    required this.relatedSpaces,
  });

  final LibraryFileSummary file;
  final List<LearningSpaceSummary> relatedSpaces;
}

final class UnclassifiedAssets {
  const UnclassifiedAssets({required this.files, required this.banks});

  final List<LibraryFileSummary> files;
  final List<QuestionBankSummary> banks;
}
