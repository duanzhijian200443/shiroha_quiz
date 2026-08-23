import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:shiroha_quiz/domain/assets/asset_ref.dart';
import 'package:shiroha_quiz/domain/assets/sourced_asset_ref.dart';
import 'package:shiroha_quiz/services/file_library/managed_content_asset_store.dart';

void main() {
  late Directory temp;

  setUp(() async {
    temp = await Directory.systemTemp.createTemp('content_asset_store_');
  });

  tearDown(() async {
    if (await temp.exists()) await temp.delete(recursive: true);
  });

  test('stores source-qualified bytes atomically and resolves after reopen',
      () async {
    final first = ManagedContentAssetStore(managedRoot: temp);
    final bytes = <int>[137, 80, 78, 71, 13, 10, 26, 10, 1, 2, 3];

    final result = first.storeBytesSync(
      sourceId: 'source_a',
      localAssetId: 'img_001',
      bytes: bytes,
      mimeType: 'image/png',
    );

    expect(result.storageKey, 'content_assets/source_a/img_001');
    expect(
      first.readAssetBytes(sourceId: 'source_a', localAssetId: 'img_001'),
      bytes,
    );
    expect(
      first.isDurableAssetReady(
        SourcedAssetRef(
          sourceId: 'source_a',
          asset: AssetRef(assetId: 'img_001', kind: AssetKind.image),
        ),
      ),
      isTrue,
    );

    final reopened = ManagedContentAssetStore(managedRoot: temp);
    expect(
      await reopened.listAssets(),
      hasLength(1),
    );
    expect(
      reopened.readAssetBytes(sourceId: 'source_a', localAssetId: 'img_001'),
      bytes,
    );
  });

  test('does not let one local asset id collide across source ids', () async {
    final store = ManagedContentAssetStore(managedRoot: temp);
    store.storeBytesSync(
      sourceId: 'source_a',
      localAssetId: 'img_001',
      bytes: <int>[1, 2, 3],
      mimeType: 'image/png',
    );
    store.storeBytesSync(
      sourceId: 'source_b',
      localAssetId: 'img_001',
      bytes: <int>[4, 5, 6],
      mimeType: 'image/png',
    );

    final records = await store.listAssets();
    expect(
      records.map((record) => '${record.sourceId}/${record.localAssetId}'),
      <String>['source_a/img_001', 'source_b/img_001'],
    );
    expect(
      store.readAssetBytes(sourceId: 'source_a', localAssetId: 'img_001'),
      <int>[1, 2, 3],
    );
    expect(
      store.readAssetBytes(sourceId: 'source_b', localAssetId: 'img_001'),
      <int>[4, 5, 6],
    );
  });

  test('rejects replacement bytes for an existing identity', () {
    final store = ManagedContentAssetStore(managedRoot: temp);
    store.storeBytesSync(
      sourceId: 'source_a',
      localAssetId: 'img_001',
      bytes: <int>[1, 2, 3],
      mimeType: 'image/png',
    );

    expect(
      () => store.storeBytesSync(
        sourceId: 'source_a',
        localAssetId: 'img_001',
        bytes: <int>[9, 8, 7],
        mimeType: 'image/png',
      ),
      throwsA(isA<FormatException>()),
    );
  });

  test('durable readiness uses the same bounded readable bytes as resolver',
      () {
    final store = ManagedContentAssetStore(managedRoot: temp);
    store.storeBytesSync(
      sourceId: 'source_a',
      localAssetId: 'img_001',
      bytes: <int>[1, 2, 3],
      mimeType: 'image/png',
    );
    final file = File(
      p.join(temp.path, 'content_assets', 'source_a', 'img_001'),
    );
    file.writeAsBytesSync(
      List<int>.filled(ManagedContentAssetStore.maxImageBytes + 1, 0),
      flush: true,
    );

    final asset = SourcedAssetRef(
      sourceId: 'source_a',
      asset: AssetRef(assetId: 'img_001', kind: AssetKind.image),
    );
    expect(store.readAssetBytes(sourceId: 'source_a', localAssetId: 'img_001'),
        isNull);
    expect(store.isDurableAssetReady(asset), isFalse);
  });
}
