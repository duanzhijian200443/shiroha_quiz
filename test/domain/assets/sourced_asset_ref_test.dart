import 'package:flutter_test/flutter_test.dart';
import 'package:shiroha_quiz/domain/assets/asset_ref.dart';
import 'package:shiroha_quiz/domain/assets/sourced_asset_ref.dart';

void main() {
  group('SourcedAssetRef', () {
    test('uses source ID plus local asset ID as stable identity', () {
      final first = SourcedAssetRef(
        sourceId: 'source_001',
        asset: AssetRef(
          assetId: 'asset_000001',
          kind: AssetKind.image,
          mimeType: 'image/png',
        ),
      );
      final equal = SourcedAssetRef(
        sourceId: 'source_001',
        asset: AssetRef(
          assetId: 'asset_000001',
          kind: AssetKind.image,
          mimeType: 'image/png',
        ),
      );
      final otherSource = SourcedAssetRef(
        sourceId: 'source_002',
        asset: AssetRef(
          assetId: 'asset_000001',
          kind: AssetKind.image,
          mimeType: 'image/png',
        ),
      );

      expect(first.localAssetId, 'asset_000001');
      expect(equal, first);
      expect(equal.hashCode, first.hashCode);
      expect(otherSource, isNot(first));
      expect(<SourcedAssetRef>{first, otherSource}, hasLength(2));
    });

    test('rejects unsafe source IDs through the SourceRef contract', () {
      final asset = AssetRef(
        assetId: 'asset_000001',
        kind: AssetKind.image,
      );

      for (final sourceId in <String>[
        '',
        'source id',
        'folder/source',
        r'C:\private\source',
        'https://example.invalid/source',
      ]) {
        expect(
          () => SourcedAssetRef(sourceId: sourceId, asset: asset),
          throwsFormatException,
        );
      }
    });
  });
}
