import '../../domain/generated_question/generated_question_contract.dart';
import 'generated_question_service.dart';

enum GeneratedLocalIdentityFailure {
  missingWithProposals('local_identity_missing'),
  corrupt('local_identity_corrupt'),
  ownerMismatch('local_identity_mismatch'),
  persistenceFailed('local_identity_persistence_failed');

  const GeneratedLocalIdentityFailure(this.code);
  final String code;
}

final class GeneratedLocalIdentityException implements Exception {
  const GeneratedLocalIdentityException(this.failure);
  final GeneratedLocalIdentityFailure failure;
  @override
  String toString() => 'GeneratedLocalIdentityException(${failure.code})';
}

abstract interface class GeneratedLocalIdentityPort {
  Future<String> loadOrCreateOwner();
}

/// Read authority has no confirmed target and cannot enter an R5A command.
final class GeneratedLocalReadAuthority {
  const GeneratedLocalReadAuthority._(this.localOwner, this.isCurrent);
  final String localOwner;
  final bool Function() isCurrent;
  void validate() {
    if (!isCurrent()) generatedFail(GeneratedFailure.unauthorized);
    generatedToken(localOwner, uuid: true);
  }
}

abstract interface class GeneratedLocalProposalReadPort {
  Future<List<GeneratedQuestionProposal>> pending(
      GeneratedLocalReadAuthority authority);
  Future<GeneratedQuestionProposal> read(
      String proposalId, GeneratedLocalReadAuthority authority);
}

/// First-party UI composition only; never injected into Agent/MCP projections.
/// Identity is loaded on session entry, outside B0's maintenance window.
final class GeneratedLocalAuthorityFactory {
  GeneratedLocalAuthorityFactory({
    required GeneratedLocalIdentityPort identity,
    required GeneratedLocalProposalReadPort proposals,
    required bool Function() compositionIsCurrent,
  })  : _identity = identity,
        _proposals = proposals,
        _compositionIsCurrent = compositionIsCurrent;

  final GeneratedLocalIdentityPort _identity;
  final GeneratedLocalProposalReadPort _proposals;
  final bool Function() _compositionIsCurrent;
  bool _active = true;

  bool get isCurrent => _active && _compositionIsCurrent();

  Future<GeneratedLocalAuthoritySession> openSession() async {
    _validate();
    final owner = await _identity.loadOrCreateOwner();
    _validate();
    return GeneratedLocalAuthoritySession._(owner, this, _proposals);
  }

  void _validate() {
    if (!isCurrent) generatedFail(GeneratedFailure.unauthorized);
  }

  /// Called before the composition is replaced, including B0 restore reload.
  /// Invalidates all outstanding sessions, Contexts and async query releases.
  void invalidate() => _active = false;
}

final class GeneratedLocalAuthoritySession {
  GeneratedLocalAuthoritySession._(
      this.localOwner, this._factory, this._proposals);
  final String localOwner;
  final GeneratedLocalAuthorityFactory _factory;
  final GeneratedLocalProposalReadPort _proposals;
  bool _active = true;
  bool get isCurrent => _active && _factory.isCurrent;

  GeneratedLocalReadAuthority get _readAuthority =>
      GeneratedLocalReadAuthority._(localOwner, () => isCurrent);

  Future<List<GeneratedQuestionProposal>> pending() async {
    final authority = _readAuthority;
    authority.validate();
    final result = await _proposals.pending(authority);
    authority.validate();
    return result;
  }

  Future<GeneratedQuestionProposal> read(String proposalId) async {
    final authority = _readAuthority;
    authority.validate();
    final result = await _proposals.read(proposalId, authority);
    authority.validate();
    return result;
  }

  /// Call only from the UI action confirming the target actually displayed.
  /// Reading a Proposal or opening an Inbox never calls this method.
  GeneratedLocalContext confirmDisplayedTarget(GeneratedTarget target) {
    _readAuthority.validate();
    final snapshot = GeneratedTarget.fromJson(target.toJson());
    return GeneratedLocalContext(
        localOwner: localOwner,
        confirmedTarget: snapshot,
        isCurrent: () => isCurrent);
  }

  void close() => _active = false;
}
