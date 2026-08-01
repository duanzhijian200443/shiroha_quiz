import 'document_image_asset.dart';
import 'document_part.dart';
import 'document_signals.dart';
import 'import_format.dart';

enum ParsedDocumentContentStatus {
  usable,
  infrastructureFailure,
}

class ParsedDocument {
  final String sourceName;
  final ImportFormat format;
  final List<DocumentPart> parts;
  final DocumentSignals signals;
  final bool fallbackUsed;
  final ParsedDocumentContentStatus contentStatus;
  final Map<String, dynamic> diagnostics;
  final List<DocumentImageAsset> imageAssets;

  ParsedDocument({
    required this.sourceName,
    required this.format,
    required this.parts,
    required this.signals,
    required this.contentStatus,
    this.fallbackUsed = false,
    Map<String, dynamic>? diagnostics,
    List<DocumentImageAsset>? imageAssets,
  })  : diagnostics = diagnostics ?? {},
        imageAssets = imageAssets ?? [];

  String toPlainTextForParsing({bool includeImages = true}) {
    final buffer = StringBuffer();
    for (final part in parts) {
      if (part is TextPart) {
        buffer.writeln(part.text);
      } else if (part is TablePart) {
        buffer.writeln();
        for (int i = 0; i < part.rows.length; i++) {
          final row = part.rows[i];
          buffer.writeln('| ${row.join(' | ')} |');
          if (i == 0) {
            buffer.writeln('|${List.filled(row.length, '---').join('|')}|');
          }
        }
        buffer.writeln();
      } else if (part is ImagePart) {
        if (includeImages) {
          // Emit a stable, readable placeholder that LLMs can reference
          if (part.assetId != null) {
            final alt = part.altText ?? part.relationshipId;
            final src = part.resolvedPath ?? part.path;
            if (alt != null && alt.isNotEmpty) {
              buffer.writeln(
                  '[Image asset=${part.assetId} alt=$alt source=$src]');
            } else {
              buffer.writeln('[Image asset=${part.assetId} source=$src]');
            }
          } else {
            buffer.writeln('[Image source=${part.path}]');
          }
        }
      }
    }
    return buffer.toString();
  }

  Map<String, dynamic> toDiagnostics() {
    return {
      'sourceName': sourceName,
      'format': format.name,
      'partCount': parts.length,
      'fallbackUsed': fallbackUsed,
      'signals': signals.toMap(),
      'imageAssets': imageAssets.map((e) => e.toDiagnostics()).toList(),
      // Include any custom diagnostics/warnings set by the adapter
      ...diagnostics,
    };
  }
}
