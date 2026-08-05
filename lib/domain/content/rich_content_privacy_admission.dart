import 'content_node.dart';
import 'rich_content.dart';

final class RichContentPrivacyAdmission {
  const RichContentPrivacyAdmission();

  void validate(RichContent content) {
    for (final node in content.nodes) {
      if (node case RawFallbackNode(:final rawJson)) {
        _validateFallbackValue(rawJson);
      }
    }
  }
}

final _fallbackKeySeparatorPattern = RegExp(r'[^a-z0-9]');
final _forbiddenFallbackStringPattern = RegExp(
  r'^(?:(?:file|https?)://|data:[^,]*;base64,|[a-z]:[\\/]|\\\\|/)',
  caseSensitive: false,
);

const _forbiddenFallbackKeys = <String>{
  'path',
  'absolutepath',
  'originalpath',
  'resolvedpath',
  'extractedpath',
  'cachepath',
  'temporarypath',
  'relativepath',
  'directorypath',
  'filepath',
  'localpath',
  'sourcepath',
  'assetpath',
  'uri',
  'url',
  'base64',
  'bytes',
  'rawtext',
  'fullcontent',
  'providertext',
  'rawresponse',
  'providerrequest',
  'providerresponse',
  'providerbody',
  'requestbody',
  'responsebody',
  'diagnostic',
  'diagnostics',
  'preview',
  'exception',
  'exceptionmessage',
  'stacktrace',
  'credential',
  'credentials',
  'apikey',
  'accesstoken',
  'refreshtoken',
  'authtoken',
  'bearertoken',
  'authorization',
  'password',
  'secret',
  'clientsecret',
  'relationshipid',
};

void _validateFallbackValue(Object? value) {
  if (value is Map) {
    for (final entry in value.entries) {
      final key = entry.key;
      if (key is String && _isForbiddenFallbackKey(key)) {
        throw const FormatException(
          'Source fallback content contains prohibited side-channel metadata.',
        );
      }
      _validateFallbackValue(entry.value);
    }
    return;
  }
  if (value is Iterable) {
    for (final item in value) {
      _validateFallbackValue(item);
    }
    return;
  }
  if (value is String &&
      _forbiddenFallbackStringPattern.hasMatch(value.trimLeft())) {
    throw const FormatException(
      'Source fallback content contains a prohibited locator value.',
    );
  }
}

bool _isForbiddenFallbackKey(String key) {
  final normalized =
      key.toLowerCase().replaceAll(_fallbackKeySeparatorPattern, '');
  return _forbiddenFallbackKeys.contains(normalized) ||
      normalized.endsWith('url') ||
      normalized.endsWith('uri') ||
      normalized.endsWith('base64') ||
      normalized.endsWith('bytes') ||
      normalized.endsWith('credential') ||
      normalized.endsWith('credentials') ||
      normalized.endsWith('apikey') ||
      (normalized.contains('provider') &&
          (normalized.contains('request') ||
              normalized.contains('response') ||
              normalized.contains('body')));
}
