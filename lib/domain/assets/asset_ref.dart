final _assetIdentifierPattern = RegExp(r'^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$');
final _mimeTypePattern = RegExp(
  r'^[a-z0-9][a-z0-9!#$&^_.+-]{0,63}/'
  r'[a-z0-9][a-z0-9!#$&^_.+-]{0,127}$',
);

enum AssetKind { image }

final class AssetRef {
  factory AssetRef({
    required String assetId,
    required AssetKind kind,
    String? mimeType,
    int? pixelWidth,
    int? pixelHeight,
  }) {
    if (!_assetIdentifierPattern.hasMatch(assetId)) {
      throw const FormatException(
        'Asset identifiers must use the bounded opaque token format.',
      );
    }
    if (mimeType != null) {
      if (!_mimeTypePattern.hasMatch(mimeType)) {
        throw const FormatException(
          'Asset media types must use the safe canonical format.',
        );
      }
      if (kind == AssetKind.image && !mimeType.startsWith('image/')) {
        throw const FormatException(
          'Image assets require an image media type.',
        );
      }
    }

    final hasWidth = pixelWidth != null;
    final hasHeight = pixelHeight != null;
    if (hasWidth != hasHeight) {
      throw const FormatException(
        'Asset pixel dimensions must be provided together.',
      );
    }
    if ((pixelWidth != null && pixelWidth <= 0) ||
        (pixelHeight != null && pixelHeight <= 0)) {
      throw const FormatException(
        'Asset pixel dimensions must be positive.',
      );
    }

    return AssetRef._(
      assetId: assetId,
      kind: kind,
      mimeType: mimeType,
      pixelWidth: pixelWidth,
      pixelHeight: pixelHeight,
    );
  }

  const AssetRef._({
    required this.assetId,
    required this.kind,
    required this.mimeType,
    required this.pixelWidth,
    required this.pixelHeight,
  });

  final String assetId;
  final AssetKind kind;
  final String? mimeType;
  final int? pixelWidth;
  final int? pixelHeight;

  @override
  bool operator ==(Object other) {
    return identical(this, other) ||
        other is AssetRef &&
            assetId == other.assetId &&
            kind == other.kind &&
            mimeType == other.mimeType &&
            pixelWidth == other.pixelWidth &&
            pixelHeight == other.pixelHeight;
  }

  @override
  int get hashCode {
    return Object.hash(
      assetId,
      kind,
      mimeType,
      pixelWidth,
      pixelHeight,
    );
  }
}
