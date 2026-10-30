import 'dart:async';

import '../data/external/windows_local_relay.dart';
import 'vnext_mcp_server.dart';

/// Codex owns only this adapter. Discovery constructs no connection or Owner.
final class VnextLocalRelayPort implements VnextMcpPort {
  VnextLocalRelayPort(
      {LocalRelayConnection Function()? connect, this.profileVersion = 2})
      : _connect = connect ?? WindowsLocalRelay.openAdapter;
  final int profileVersion;
  Map<String, Object?> _failure(String code) =>
      vnextFailure(code, profileVersion: profileVersion);
  final LocalRelayConnection Function() _connect;
  LocalRelayConnection? _connection;
  Future<void>? _closing;
  Future<void>? _retiring;
  bool _busy = false, _closed = false, _cleanupFailed = false;
  int _nextId = 0;

  @override
  Future<Map<String, Object?>> call(String tool, Map<String, dynamic> arguments,
      {required Stream<void> cancelled,
      required bool Function() available}) async {
    if (_closed || _cleanupFailed || !available()) {
      return _failure('unavailable');
    }
    if (_busy) return _failure('busy');
    _busy = true;
    var interrupted = false;
    var sendEntered = false;
    final cancellation = cancelled.listen((_) {
      interrupted = true;
      unawaited(_retire().then((_) {}, onError: (Object _, StackTrace __) {}));
    });
    try {
      if (!VnextMcpServer.schemasFor(profileVersion).containsKey(tool)) {
        return _failure('invalidRequest');
      }
      await _retiring;
      if (_closed || _cleanupFailed || interrupted || !available()) {
        return _failure('unavailable');
      }
      // A new invocation may reconnect only after successful original cleanup.
      // This never retries the invocation that lost its response.
      if (_connection != null && !_connection!.isCurrent) await _retire();
      if (_closed || interrupted || !available()) {
        return _failure('unavailable');
      }
      if (_connection == null) {
        final connection = _connection = _connect();
        await connection.accept();
        if (_closed || interrupted || !available()) {
          throw const LocalRelayException();
        }
        // Correlation is scoped to this authenticated pipe, as on the App.
        _nextId = 0;
      }
      final connection = _connection!;
      if (_nextId >= 0x7fffffff) throw const LocalRelayException();
      final id = ++_nextId;
      sendEntered = true;
      await connection.send({
        'version': profileVersion == 3 ? 2 : 1,
        if (profileVersion == 3) 'profileVersion': 3,
        'id': id,
        'tool': tool,
        'arguments': arguments
      }, const Duration(seconds: 5));
      final response = await connection.receive(
          tool == 'propose_generated_questions'
              ? const Duration(seconds: 150)
              : const Duration(seconds: 15));
      if (_closed ||
          interrupted ||
          !available() ||
          response.length != 3 ||
          response['version'] != (profileVersion == 3 ? 2 : 1) ||
          response['id'] != id ||
          response['result'] is! Map<String, dynamic>) {
        throw const LocalRelayException();
      }
      return response['result']! as Map<String, dynamic>;
    } catch (error) {
      try {
        await _retire();
      } catch (_) {/* Keep the failed cleanup latch. */}
      if (error is LocalRelayException && error.unsettled) {
        _cleanupFailed = true;
      }
      if (error is LocalRelayException && error.busy) return _failure('busy');
      // Unknown writes are never replayed or described as successful/rolled back.
      return _failure(sendEntered && tool == 'propose_generated_questions'
          ? 'outcome_unknown'
          : 'unavailable');
    } finally {
      await cancellation.cancel();
      _busy = false;
    }
  }

  @override
  Future<void> close() {
    _closed = true;
    return _closing ??= _retire();
  }

  Future<void> _retire() {
    if (_cleanupFailed) {
      return _retiring ??
          Future<void>.error(const LocalRelayException(unsettled: true));
    }
    if (_retiring != null) return _retiring!;
    final connection = _connection;
    if (connection == null) return Future<void>.value();
    final done = Completer<void>();
    _retiring = done.future;
    unawaited(() async {
      try {
        await connection.close();
        if (identical(_connection, connection)) _connection = null;
        _retiring = null;
        done.complete();
      } catch (error, stack) {
        _cleanupFailed = true;
        done.completeError(error, stack);
      }
    }());
    return done.future;
  }
}
