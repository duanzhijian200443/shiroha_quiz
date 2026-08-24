import 'dart:convert';

/// Detects the bounded image formats admitted by the typed content bridge.
///
/// The detected signature, rather than a provider-declared MIME string, is
/// the byte authority. Callers may compare it with a declared MIME before
/// allowing bytes to enter managed content storage.
final class ImageByteSignature {
  const ImageByteSignature._();

  static String? detectMime(List<int> bytes) {
    if (bytes.length >= 8 &&
        bytes[0] == 0x89 &&
        bytes[1] == 0x50 &&
        bytes[2] == 0x4e &&
        bytes[3] == 0x47 &&
        bytes[4] == 0x0d &&
        bytes[5] == 0x0a &&
        bytes[6] == 0x1a &&
        bytes[7] == 0x0a) {
      return 'image/png';
    }
    if (bytes.length >= 3 && bytes[0] == 0xff && bytes[1] == 0xd8) {
      return 'image/jpeg';
    }
    if (bytes.length >= 6) {
      final prefix = ascii.decode(bytes.sublist(0, 6), allowInvalid: true);
      if (prefix == 'GIF87a' || prefix == 'GIF89a') return 'image/gif';
    }
    if (bytes.length >= 12 &&
        ascii.decode(bytes.sublist(0, 4), allowInvalid: true) == 'RIFF' &&
        ascii.decode(bytes.sublist(8, 12), allowInvalid: true) == 'WEBP') {
      return 'image/webp';
    }
    return null;
  }

  static String? canonicalMime(String mimeType) {
    final normalized = mimeType.trim().toLowerCase().split(';').first;
    return switch (normalized) {
      'image/png' => 'image/png',
      'image/jpeg' || 'image/jpg' => 'image/jpeg',
      'image/webp' => 'image/webp',
      'image/gif' => 'image/gif',
      _ => null,
    };
  }

  static bool matchesMime(List<int> bytes, String mimeType) {
    final declared = canonicalMime(mimeType);
    return declared != null && detectMime(bytes) == declared;
  }
}
