/// Conservative implementation defaults for context-free RichContent
/// admission. These are runtime safety limits, not persisted schema values.
abstract final class RichContentLimits {
  static const int maxDepth = 8;
  static const int maxNodes = 128;
  static const int maxScalars = 8192;
  static const int maxNodeScalars = 4096;
  static const int maxRawCollectionEntries = 256;
  static const int maxTableRows = 64;
  static const int maxTableColumns = 64;
  static const int maxTableLogicalCells = 256;
  static const int maxTableExpandedCells = 4096;
  static const int maxImages = 64;
  static const int maxProjectionScalars = 8192;
}
