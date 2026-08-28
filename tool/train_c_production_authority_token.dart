const trainCFinalLibTreeAuthorityPrefix = 'lib_tree:';

String? trainCFinalLibTreeShaFromAuthorityToken(String value) {
  final normalized = value.trim();
  if (!normalized.startsWith(trainCFinalLibTreeAuthorityPrefix)) return null;
  final sha = normalized.substring(trainCFinalLibTreeAuthorityPrefix.length);
  return RegExp(r'^[0-9a-f]{40}$').hasMatch(sha) ? sha : null;
}

bool trainCIsFinalLibTreeAuthorityToken(String value) =>
    trainCFinalLibTreeShaFromAuthorityToken(value) != null;

String trainCFinalLibTreeAuthorityToken(String treeSha) {
  final normalized = treeSha.trim();
  if (!RegExp(r'^[0-9a-f]{40}$').hasMatch(normalized)) {
    throw ArgumentError.value(treeSha, 'treeSha');
  }
  return '$trainCFinalLibTreeAuthorityPrefix$normalized';
}
