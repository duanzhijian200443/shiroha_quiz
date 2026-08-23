import '../../domain/assets/sourced_asset_ref.dart';

/// Safe result returned after transient bytes have crossed into durable
/// managed storage. The storage key remains infrastructure-only.
final class ContentAssetWriteResult {
  const ContentAssetWriteResult({
    required this.storageKey,
    required this.sha256,
    required this.sizeBytes,
    required this.mimeType,
  });

  final String storageKey;
  final String sha256;
  final int sizeBytes;
  final String mimeType;
}

/// Redacted inventory row used by bounded backup export and restore checks.
final class ContentAssetRecord {
  const ContentAssetRecord({
    required this.sourceId,
    required this.localAssetId,
    required this.storageKey,
    required this.sizeBytes,
    required this.sha256,
  });

  final String sourceId;
  final String localAssetId;
  final String storageKey;
  final int sizeBytes;
  final String sha256;
}

/// Application port for transient OCR bytes and source-qualified durable
/// content asset resolution. Implementations own filesystem and integrity
/// details; callers never receive provider locators or payload bodies.
abstract interface class ContentAssetStore {
  String storageKey({required String sourceId, required String localAssetId});

  Future<ContentAssetWriteResult> storeBytes({
    required String sourceId,
    required String localAssetId,
    required List<int> bytes,
    required String mimeType,
  });

  ContentAssetWriteResult storeBytesSync({
    required String sourceId,
    required String localAssetId,
    required List<int> bytes,
    required String mimeType,
  });

  List<int>? readAssetBytes({
    required String sourceId,
    required String localAssetId,
  });

  Future<bool> assetExists({
    required String sourceId,
    required String localAssetId,
  });

  Future<List<ContentAssetRecord>> listAssets();
}

/// Application port used by the persistence boundary to prove that every
/// reachable typed image already has independently durable bytes.
///
/// The port exposes no path, URL, provider payload, or file-system object.
/// Implementations own integrity checks and may fail closed.
abstract interface class ContentAssetAuthority {
  bool isDurableAssetReady(SourcedAssetRef asset);
}

/// Presentation read port. The renderer receives this dependency explicitly
/// through [ContentAssetResolverScope]; no global URL/path resolver exists.
abstract interface class ContentAssetResolver {
  List<int>? resolveAssetBytes({
    required String sourceId,
    required String localAssetId,
  });
}
