import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:shiroha_quiz/services/file_library/managed_content_asset_store.dart';

void main() {
  late Directory tempDir;
  late ManagedContentAssetStore store;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('content_asset_test_');
    store = ManagedContentAssetStore(managedRoot: tempDir);
  });

  tearDown(() async {
    if (await tempDir.exists()) {
      await tempDir.delete(recursive: true);
    }
  });

  group('ManagedContentAssetStore', () {
    test('stores bytes and deduplicates by sha256', () async {
      final sampleBytes = Uint8List.fromList([1, 2, 3, 4, 5]);
      final key1 = await store.storeBytes(
        bytes: sampleBytes,
        mimeType: 'image/png',
      );
      final key2 = await store.storeBytes(
        bytes: sampleBytes,
        mimeType: 'image/png',
      );

      expect(key1, startsWith('content_assets/'));
      expect(key1, endsWith('.png'));
      expect(key1, equals(key2));

      final file = store.resolveAsset(key1);
      expect(file, isNotNull);
      expect(file!.existsSync(), isTrue);
      expect(file.readAsBytesSync(), equals(sampleBytes));
    });

    test('stores and parses data URL successfully', () async {
      final rawBytes = utf8.encode('fake-image-bytes');
      final base64String = base64Encode(rawBytes);
      final dataUrl = 'data:image/jpeg;base64,$base64String';

      final key = await store.storeDataUrl(dataUrl);
      expect(key, startsWith('content_assets/'));
      expect(key, endsWith('.jpg'));

      final file = store.resolveAsset(key);
      expect(file, isNotNull);
      expect(file!.existsSync(), isTrue);
      expect(file.readAsBytesSync(), equals(rawBytes));
    });

    test('throws on invalid data URL', () async {
      expect(
        () => store.storeDataUrl('invalid_string'),
        throwsFormatException,
      );
      expect(
        () => store.storeDataUrl('data:text/plain;base64,abc'),
        throwsFormatException,
      );
      expect(
        () => store.storeDataUrl('data:image/png;notbase64,abc'),
        throwsFormatException,
      );
    });

    test('prevents path traversal in resolveAsset', () {
      expect(store.resolveAsset('../secret.txt'), isNull);
      expect(store.resolveAsset('/absolute/path/file.png'), isNull);
      expect(store.resolveAsset(r'..\windows\secret.txt'), isNull);
      expect(store.resolveAsset('content_assets/../../secret.txt'), isNull);
    });

    test('DefaultContentAssetResolver delegates to configured store', () async {
      DefaultContentAssetResolver.instance.setStore(store);
      final bytes = Uint8List.fromList([10, 20, 30]);
      final key = await store.storeBytes(
        bytes: bytes,
        mimeType: 'image/png',
      );

      final resolved = DefaultContentAssetResolver.instance.resolveAsset(key);
      expect(resolved, isNotNull);
      expect(resolved!.existsSync(), isTrue);
      expect(resolved.readAsBytesSync(), equals(bytes));
    });
  });
}
