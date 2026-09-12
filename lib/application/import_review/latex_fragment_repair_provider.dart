import 'latex_fragment_repair.dart';

enum LatexFragmentProviderFailure {
  providerUnconfigured('provider_unconfigured'),
  providerAuthenticationFailed('provider_authentication_failed'),
  providerRateLimited('provider_rate_limited'),
  providerTimeout('provider_timeout'),
  providerUnavailable('provider_unavailable'),
  providerRejected('provider_rejected'),
  providerEmptyContent('provider_empty_content'),
  providerReasoningOnly('provider_reasoning_only'),
  providerFinishLength('provider_finish_length'),
  providerInvalidEnvelope('provider_invalid_envelope'),
  providerOutputInvalid('provider_output_invalid'),
  internalError('provider_internal_error');

  const LatexFragmentProviderFailure(this.wireName);
  final String wireName;
}

final class LatexFragmentProviderException implements Exception {
  const LatexFragmentProviderException(this.failure);

  final LatexFragmentProviderFailure failure;

  @override
  String toString() =>
      'LatexFragmentProviderException(${failure.wireName}): [REDACTED]';
}

final class LatexFragmentProviderRequest {
  LatexFragmentProviderRequest({
    required this.nodeKind,
    required this.originalLatex,
    required this.precedingContext,
    required this.followingContext,
  }) {
    if (originalLatex.trim().isEmpty || originalLatex.runes.length > 4096) {
      throw const FormatException('Invalid bounded LaTeX fragment request.');
    }
    if (precedingContext.runes.length > 256 ||
        followingContext.runes.length > 256) {
      throw const FormatException('Invalid bounded LaTeX context.');
    }
  }

  final LatexFragmentNodeKind nodeKind;
  final String originalLatex;
  final String precedingContext;
  final String followingContext;

  int get maximumOutputScalars {
    final calculated = originalLatex.runes.length * 4 + 256;
    return calculated > 4096 ? 4096 : calculated;
  }

  @override
  String toString() => 'LatexFragmentProviderRequest([REDACTED])';
}

final class LatexFragmentProviderResult {
  const LatexFragmentProviderResult({
    required this.correctedLatex,
    required this.providerProfileId,
  });

  final String correctedLatex;
  final String providerProfileId;

  @override
  String toString() => 'LatexFragmentProviderResult([REDACTED])';
}

abstract interface class LatexFragmentRepairProviderPort {
  Future<LatexFragmentProviderResult> repair(
    LatexFragmentProviderRequest request, {
    Duration timeout = const Duration(seconds: 90),
  });
}
