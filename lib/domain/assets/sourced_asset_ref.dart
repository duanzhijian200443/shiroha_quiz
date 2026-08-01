import '../source/source_ref.dart';
import 'asset_ref.dart';

/// An asset reference qualified by the source document that owns its local ID.
final class SourcedAssetRef {
  factory SourcedAssetRef({
    required String sourceId,
    required AssetRef asset,
  }) {
    final validatedSourceId = SourceRef.document(sourceId: sourceId).sourceId;
    return SourcedAssetRef._(
      sourceId: validatedSourceId,
      asset: asset,
    );
  }

  const SourcedAssetRef._({
    required this.sourceId,
    required this.asset,
  });

  final String sourceId;
  final AssetRef asset;

  String get localAssetId => asset.assetId;

  @override
  bool operator ==(Object other) {
    return identical(this, other) ||
        other is SourcedAssetRef &&
            sourceId == other.sourceId &&
            asset == other.asset;
  }

  @override
  int get hashCode => Object.hash(sourceId, asset);
}
