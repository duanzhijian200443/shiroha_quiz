import 'package:flutter_test/flutter_test.dart';
import 'package:shiroha_quiz/domain/assets/asset_ref.dart';

void main() {
  group('AssetRef valid construction', () {
    test('represents images with optional safe metadata', () {
      final minimal = AssetRef(
        assetId: 'asset_001',
        kind: AssetKind.image,
      );
      final png = AssetRef(
        assetId: 'asset_002',
        kind: AssetKind.image,
        mimeType: 'image/png',
        pixelWidth: 1200,
        pixelHeight: 800,
      );
      final svg = AssetRef(
        assetId: 'asset_003',
        kind: AssetKind.image,
        mimeType: 'image/svg+xml',
      );

      expect(minimal.mimeType, isNull);
      expect(minimal.pixelWidth, isNull);
      expect(minimal.pixelHeight, isNull);
      expect(png.pixelWidth, 1200);
      expect(png.pixelHeight, 800);
      expect(svg.mimeType, 'image/svg+xml');
    });

    test('uses stable value equality and distinguishes asset IDs', () {
      final first = AssetRef(
        assetId: 'asset_001',
        kind: AssetKind.image,
        mimeType: 'image/png',
        pixelWidth: 1200,
        pixelHeight: 800,
      );
      final equal = AssetRef(
        assetId: 'asset_001',
        kind: AssetKind.image,
        mimeType: 'image/png',
        pixelWidth: 1200,
        pixelHeight: 800,
      );
      final different = AssetRef(
        assetId: 'asset_002',
        kind: AssetKind.image,
        mimeType: 'image/png',
        pixelWidth: 1200,
        pixelHeight: 800,
      );

      expect(equal, first);
      expect(equal.hashCode, first.hashCode);
      expect(<AssetRef>{first}, contains(equal));
      expect(different, isNot(first));
    });
  });

  group('AssetRef invalid construction', () {
    test('rejects unsafe asset identifiers', () {
      final invalidIds = <String>[
        '',
        ' ',
        'asset id',
        'a' * 129,
        r'C:\private\image.png',
        '/private/image.png',
        'file://image.png',
        'https://example.invalid/image.png',
        'data:image/png;base64,synthetic',
      ];

      for (final assetId in invalidIds) {
        expect(
          () => AssetRef(assetId: assetId, kind: AssetKind.image),
          throwsFormatException,
          reason: assetId.isEmpty ? 'empty asset ID' : 'unsafe asset ID',
        );
      }
    });

    test('rejects unsafe or incompatible MIME types', () {
      final invalidMimeTypes = <String>[
        '',
        'Image/PNG',
        'image',
        'image/png; charset=utf-8',
        'image/ png',
        'text/plain',
      ];

      for (final mimeType in invalidMimeTypes) {
        expect(
          () => AssetRef(
            assetId: 'asset_001',
            kind: AssetKind.image,
            mimeType: mimeType,
          ),
          throwsFormatException,
        );
      }
    });

    test('rejects zero, negative, or incomplete pixel dimensions', () {
      final invalidDimensions = <(int?, int?)>[
        (0, 1),
        (1, 0),
        (-1, 1),
        (1, -1),
        (100, null),
        (null, 100),
      ];

      for (final dimensions in invalidDimensions) {
        expect(
          () => AssetRef(
            assetId: 'asset_001',
            kind: AssetKind.image,
            pixelWidth: dimensions.$1,
            pixelHeight: dimensions.$2,
          ),
          throwsFormatException,
        );
      }
    });
  });
}
