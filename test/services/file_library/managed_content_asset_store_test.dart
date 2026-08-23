import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:shiroha_quiz/application/content/content_asset_authority.dart';
import 'package:path/path.dart' as p;
import 'package:shiroha_quiz/domain/assets/asset_ref.dart';
import 'package:shiroha_quiz/domain/assets/sourced_asset_ref.dart';
import 'package:shiroha_quiz/services/file_library/managed_content_asset_store.dart';

final _validPng = base64Decode(
  'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk'
  '+A8AAQUBAScY42YAAAAASUVORK5CYII=',
);

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
    final bytes = List<int>.from(_validPng);

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
      bytes: <int>[..._validPng, 1],
      mimeType: 'image/png',
    );
    store.storeBytesSync(
      sourceId: 'source_b',
      localAssetId: 'img_001',
      bytes: <int>[..._validPng, 2],
      mimeType: 'image/png',
    );

    final records = await store.listAssets();
    expect(
      records.map((record) => '${record.sourceId}/${record.localAssetId}'),
      <String>['source_a/img_001', 'source_b/img_001'],
    );
    expect(
      store.readAssetBytes(sourceId: 'source_a', localAssetId: 'img_001'),
      <int>[..._validPng, 1],
    );
    expect(
      store.readAssetBytes(sourceId: 'source_b', localAssetId: 'img_001'),
      <int>[..._validPng, 2],
    );
  });

  test('candidate rollback reports deleted, missing, and failed identities',
      () async {
    final store = ManagedContentAssetStore(managedRoot: temp);
    store.storeBytesSync(
      sourceId: 'source_a',
      localAssetId: 'img_001',
      bytes: _validPng,
      mimeType: 'image/png',
    );

    final outcome = await store.deleteCandidateAssets(
      ContentAssetCandidateLease(
        sourceId: 'source_a',
        localAssetIds: const <String>[
          'img_001',
          'img_missing',
          '../unsafe',
        ],
      ),
    );

    expect(outcome.deletedCount, 1);
    expect(outcome.missingCount, 1);
    expect(outcome.failedCount, 1);
    expect(outcome.isComplete, isFalse);
    expect(
      store.readAssetBytes(sourceId: 'source_a', localAssetId: 'img_001'),
      isNull,
    );
  });

  test('rejects MIME declarations that disagree with image signatures', () {
    final store = ManagedContentAssetStore(managedRoot: temp);
    expect(
      () => store.storeBytesSync(
        sourceId: 'source_a',
        localAssetId: 'img_001',
        bytes: <int>[0xff, 0xd8, 0xff, 0xe0],
        mimeType: 'image/png',
      ),
      throwsA(isA<FormatException>()),
    );
    expect(
      () => store.storeBytesSync(
        sourceId: 'source_a',
        localAssetId: 'img_002',
        bytes: <int>[1, 2, 3],
        mimeType: 'image/png',
      ),
      throwsA(isA<FormatException>()),
    );
  });

  test('rejects replacement bytes for an existing identity', () {
    final store = ManagedContentAssetStore(managedRoot: temp);
    store.storeBytesSync(
      sourceId: 'source_a',
      localAssetId: 'img_001',
      bytes: <int>[..._validPng, 3],
      mimeType: 'image/png',
    );

    expect(
      () => store.storeBytesSync(
        sourceId: 'source_a',
        localAssetId: 'img_001',
        bytes: <int>[..._validPng, 4],
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
      bytes: <int>[..._validPng, 5],
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
