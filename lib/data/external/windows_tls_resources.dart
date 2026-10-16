part of 'windows_tls_transport.dart';

enum TlsResource {
  socket,
  handshake,
  pipeline,
  protocolBytes,
  stringBytes,
  writeBytes
}

/// Frozen FIRST CANDIDATE ceilings, not measured production capacity. A test or
/// future bounded experiment may reduce a ceiling, never silently enlarge it.
final class TlsBudgets {
  TlsBudgets(
      {this.sockets = 8,
      this.handshakes = 2,
      this.pipelines = 2,
      this.protocolBytes = 16 * 1024 * 1024,
      this.stringBytes = 32 * 1024 * 1024,
      this.writeBytes = 512 * 1024}) {
    final ceilings = [8, 2, 2, 16 * 1024 * 1024, 32 * 1024 * 1024, 512 * 1024];
    for (var i = 0; i < ceilings.length; i++) {
      if (_limits[i] < 1 || _limits[i] > ceilings[i]) {
        credentialFail(ExternalCredentialFailure.invalidInput);
      }
    }
  }
  final int sockets,
      handshakes,
      pipelines,
      protocolBytes,
      stringBytes,
      writeBytes;
  List<int> get _limits =>
      [sockets, handshakes, pipelines, protocolBytes, stringBytes, writeBytes];
}

final class TlsResourceBudget {
  TlsResourceBudget(TlsBudgets limits) : _limits = limits._limits;
  final List<int> _limits;
  final _used = List<int>.filled(TlsResource.values.length, 0);
  bool _poisoned = false;
  bool get isUsable => !_poisoned;
  int used(TlsResource resource) => _used[resource.index];
  int limit(TlsResource resource) => _limits[resource.index];
  void invalidate() => _poisoned = true;

  TlsReservation reserve(TlsResource resource, [int count = 1]) {
    if (_poisoned ||
        count < 1 ||
        count > _limits[resource.index] - _used[resource.index]) {
      credentialFail(ExternalCredentialFailure.resourceLimit);
    }
    // Synchronous, before the operation/Future is created. No waiter queue.
    _used[resource.index] += count;
    return TlsReservation._(this, resource, count);
  }
}

final class TlsReservation {
  TlsReservation._(this._budget, this.resource, this.count);
  final TlsResourceBudget _budget;
  final TlsResource resource;
  final int count;
  bool _released = false;
  bool get isReleased => _released;

  /// Caller must first establish actual operation/close settlement. Timeouts do
  /// not invoke this method. Duplicate release cannot decrement another owner.
  void release() {
    if (_released) return;
    _released = true;
    _budget._used[resource.index] -= count;
  }
}
