import 'dart:async';
import 'dart:convert';
import 'dart:ffi';
import 'dart:io';
import 'dart:typed_data';

import 'package:path/path.dart' as p;
import 'bounded_json_object.dart';

/// The local hop has no Application identity or credential authority.
final class LocalRelayException implements Exception {
  const LocalRelayException(
      {this.unsettled = false,
      this.independentAppRequired = false,
      this.busy = false,
      this.linkDiagnostic = 0});
  final bool unsettled;
  final bool independentAppRequired;
  final bool busy;
  final int linkDiagnostic;
  @override
  String toString() => 'Local relay unavailable';
}

/// Bounded framing shared by the two local transport endpoints.
final class LocalRelayFrame {
  static const maxBytes = 2 * 1024 * 1024;
  static const linkBusinessBytes = 6324224;
  static const linkControlBytes = 16384;
  static void _checkTree(Map<String, Object?> value, int limit) {
    // Bound traversal before allocating the encoded body, including cycles.
    var units = 0;
    void visit(Object? node, int depth) {
      if (depth > 32 || ++units > limit) throw const LocalRelayException();
      if (node is String) {
        units += node.length * 6 + 2;
      } else if (node is Map<String, Object?>) {
        for (final entry in node.entries) {
          visit(entry.key, depth + 1);
          visit(entry.value, depth + 1);
        }
      } else if (node is List) {
        for (final item in node) {
          visit(item, depth + 1);
        }
      } else if (node != null && node is! num && node is! bool) {
        throw const LocalRelayException();
      }
      if (units > limit) throw const LocalRelayException();
    }

    visit(value, 0);
  }

  static Uint8List encode(Map<String, Object?> value, {int limit = maxBytes}) {
    if (!{maxBytes, linkBusinessBytes, linkControlBytes}.contains(limit)) {
      throw const LocalRelayException();
    }
    _checkTree(value, limit);
    final body = utf8.encode(jsonEncode(value));
    if (body.isEmpty || body.length > limit) {
      throw const LocalRelayException();
    }
    final result = Uint8List(body.length + 4);
    ByteData.sublistView(result).setUint32(0, body.length, Endian.little);
    result.setRange(4, result.length, body);
    return result;
  }

  static Map<String, Object?> decode(Uint8List bytes, {int limit = maxBytes}) {
    if (!{maxBytes, linkBusinessBytes, linkControlBytes}.contains(limit) ||
        bytes.isEmpty ||
        bytes.length > limit) {
      throw const LocalRelayException();
    }
    try {
      final value = boundedJsonObject(bytes, maxBytes: limit);
      _checkTree(value, limit);
      return value;
    } catch (_) {
      throw const LocalRelayException();
    }
  }
}

/// One nonblocking, kernel-authenticated pipe. The native helper accepts only
/// fixed adjacent App/adapter executable peers in the same user/session.
abstract interface class LocalRelayConnection {
  bool get isCurrent;
  Future<void> accept();
  Future<void> send(Map<String, Object?> message, Duration deadline);
  Future<Map<String, Object?>> receive(Duration deadline);
  Future<void> close();
}

abstract interface class LocalRelayServerConnection
    implements LocalRelayConnection {
  String get linkPeerIdentity;
  Future<void> disconnect();
}

final class WindowsLocalRelay implements LocalRelayServerConnection {
  WindowsLocalRelay._(this._native, this._id, this._server, this._messageLimit);
  static WindowsLocalRelay openApp() => _open(true);
  static WindowsLocalRelay openAdapter() => _open(false);
  static WindowsLocalRelay openLinkBusiness({required bool server}) =>
      _open(server, libraryName: 'shiroha_link_native.dll');
  static WindowsLocalRelay openLinkControl({required bool server}) =>
      _open(server, libraryName: 'shiroha_link_control_native.dll');
  static bool linkProcessCurrent(int pid, String creation) {
    final value = int.tryParse(creation);
    if (value == null || value < 1 || pid < 1) {
      throw const LocalRelayException();
    }
    final native = _RelayNative(libraryName: 'shiroha_link_native.dll');
    try {
      final result = native.linkProcessCurrent!(pid, value);
      if (result < 0) throw const LocalRelayException();
      return result == 1;
    } finally {
      native.dispose();
    }
  }

  static WindowsLocalRelay _open(bool server,
      {String libraryName = 'shiroha_relay_native.dll'}) {
    final native = _RelayNative(libraryName: libraryName);
    try {
      final result = native.open(server ? 0 : 1, native.id);
      if (result != 0 || native.id.value == 0) {
        throw LocalRelayException(
            independentAppRequired: result == 6,
            busy: result == 5,
            linkDiagnostic: native.linkDiagnostic?.call() ?? 0);
      }
      return WindowsLocalRelay._(
          native,
          native.id.value,
          server,
          libraryName == 'shiroha_link_native.dll'
              ? LocalRelayFrame.linkBusinessBytes
              : libraryName == 'shiroha_link_control_native.dll'
                  ? LocalRelayFrame.linkControlBytes
                  : LocalRelayFrame.maxBytes);
    } catch (error) {
      native.dispose();
      if (error is LocalRelayException) rethrow;
      throw const LocalRelayException();
    }
  }

  final _RelayNative _native;
  final int _id;
  final bool _server;
  final int _messageLimit;
  bool _closed = false, _reading = false, _writing = false;
  bool _accepted = false;
  Future<void>? _closing, _disconnecting;
  Timer? _monitor;
  var _lost = Completer<void>();
  Future<void> get disconnected => _lost.future;
  @override
  bool get isCurrent => !_closed && _accepted;

  @override
  String get linkPeerIdentity {
    final value = isCurrent ? _native.linkPeerIdentity?.call(_id) : null;
    if (value == null || value == 0) throw const LocalRelayException();
    return 'peer-${value.toRadixString(16)}';
  }

  /// Original independently launched App, including while awaiting a peer.
  /// This is provenance/liveness only, never credential or business admission.
  bool get appLaunchCurrent {
    if (!_server || _closed) return false;
    return _native.appLaunchState(_id) == 0;
  }

  void _observe() {
    _accepted = true;
    _monitor = Timer.periodic(const Duration(milliseconds: 20), (_) {
      if (!_closed && _native.state(_id) != 0) {
        _noticeLost();
        if (!_server) {
          // An idle adapter must release its handle without another tool call.
          // close() retains any failure for its original owner to observe.
          unawaited(
              close().then((_) {}, onError: (Object _, StackTrace __) {}));
        }
      }
    });
  }

  void _noticeLost() {
    _accepted = false;
    if (!_lost.isCompleted) _lost.complete();
  }

  @override
  Future<void> accept() async {
    if (_closed || _accepted) throw const LocalRelayException();
    await _disconnecting;
    if (_closed) throw const LocalRelayException();
    _disconnecting = null;
    _lost = Completer<void>();
    if (!_server) {
      _observe();
      return;
    }
    while (!_closed) {
      final result = _native.accept(_id);
      if (result == 0) {
        _observe();
        return;
      }
      if (result != 1) throw const LocalRelayException();
      await Future<void>.delayed(const Duration(milliseconds: 20));
    }
    throw const LocalRelayException();
  }

  @override
  Future<Map<String, Object?>> receive(Duration deadline) async {
    if (!isCurrent || _reading) throw const LocalRelayException();
    _reading = true;
    final watch = Stopwatch()..start();
    final header = Uint8List(4);
    Uint8List? body;
    var used = 0;
    try {
      while (isCurrent && watch.elapsed < deadline) {
        final destination = body ?? header;
        final wanted = destination.length - used;
        final result = _native.read(
            _id,
            _native.buffer,
            wanted < _RelayNative.capacity ? wanted : _RelayNative.capacity,
            _native.count);
        if (result == 1) {
          await Future<void>.delayed(const Duration(milliseconds: 10));
          continue;
        }
        if (result != 0) throw const LocalRelayException();
        final length = _native.count.value;
        if (length < 1 || length > wanted || length > _RelayNative.capacity) {
          throw const LocalRelayException();
        }
        destination.setRange(
            used, used + length, _native.buffer.asTypedList(length));
        used += length;
        if (used != destination.length) continue;
        if (body != null) {
          return LocalRelayFrame.decode(body, limit: _messageLimit);
        }
        final size = ByteData.sublistView(header).getUint32(0, Endian.little);
        if (size == 0 || size > _messageLimit) {
          throw const LocalRelayException();
        }
        body = Uint8List(size);
        used = 0;
      }
      throw const LocalRelayException();
    } finally {
      _reading = false;
    }
  }

  @override
  Future<void> send(Map<String, Object?> message, Duration deadline) async {
    if (!isCurrent || _writing) throw const LocalRelayException();
    _writing = true;
    try {
      final frame = LocalRelayFrame.encode(message, limit: _messageLimit);
      final watch = Stopwatch()..start();
      var offset = 0;
      while (isCurrent && watch.elapsed < deadline && offset < frame.length) {
        final remaining = frame.length - offset;
        final size = remaining < _RelayNative.capacity
            ? remaining
            : _RelayNative.capacity;
        _native.writeBuffer.asTypedList(size).setRange(0, size, frame, offset);
        final result =
            _native.write(_id, _native.writeBuffer, size, _native.writeCount);
        if (result == 1) {
          await Future<void>.delayed(const Duration(milliseconds: 10));
          continue;
        }
        if (result != 0) throw const LocalRelayException();
        final count = _native.writeCount.value;
        if (count < 1 || count > size) throw const LocalRelayException();
        offset += count;
      }
      if (offset != frame.length) throw const LocalRelayException();
    } finally {
      _writing = false;
    }
  }

  void _endConnection() {
    _monitor?.cancel();
    _noticeLost();
  }

  Future<void> _joinIo() async {
    while (_reading || _writing) {
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
  }

  /// Retire this peer while retaining the App's first-instance exclusion.
  /// The caller must settle original Bridge custody before accepting again.
  @override
  Future<void> disconnect() {
    if (!_server) return close();
    _endConnection();
    return _disconnecting ??= () async {
      await _joinIo();
      if (_closed) return; // Full close owns native disposal.
      if (_native.disconnect(_id) != 0) {
        throw const LocalRelayException(unsettled: true);
      }
    }();
  }

  @override
  Future<void> close() {
    _closed = true;
    _endConnection();
    return _closing ??= () async {
      // Every native I/O call is nonblocking and completes synchronously. Join
      // Dart waiters before freeing their buffers; failure never reopens a pipe.
      await _disconnecting;
      await _joinIo();
      if (_native.close(_id) != 0) {
        throw const LocalRelayException(unsettled: true);
      }
      _native.dispose();
    }();
  }
}

/// Retains the original App parent and desktop Explorer/image handles. It has
/// no pipe, protected-store, credential or TLS operation. Each child can acquire
/// this guard only once, before reading its private startup preface.
final class WindowsAppParentGuard {
  WindowsAppParentGuard._(this._native, this._id);
  factory WindowsAppParentGuard.open({required bool pairingUi}) {
    final native = _RelayNative();
    try {
      final status = native.open(pairingUi ? 3 : 2, native.id);
      if (status != 0 || native.id.value == 0) {
        throw const LocalRelayException();
      }
      return WindowsAppParentGuard._(native, native.id.value);
    } catch (_) {
      native.dispose();
      rethrow;
    }
  }
  final _RelayNative _native;
  final int _id;
  bool _closed = false;
  bool get isCurrent => !_closed && _native.state(_id) == 0;
  void close() {
    if (_closed) return;
    _closed = true;
    if (_native.close(_id) != 0) {
      throw const LocalRelayException(unsettled: true);
    }
    _native.dispose();
  }
}

final class _RelayNative {
  _RelayNative({String libraryName = 'shiroha_relay_native.dll'}) {
    if (!Platform.isWindows) throw const LocalRelayException();
    try {
      final library = DynamicLibrary.open(
          p.join(p.dirname(Platform.resolvedExecutable), libraryName));
      final version = library.lookupFunction<Uint32 Function(), int Function()>(
          'shiroha_relay_version');
      if (version() != 1) throw const LocalRelayException();
      if (libraryName != 'shiroha_relay_native.dll') {
        linkDiagnostic =
            library.lookupFunction<Uint32 Function(), int Function()>(
                'shiroha_link_diagnostic');
        linkPeerIdentity =
            library.lookupFunction<Uint64 Function(Uint64), int Function(int)>(
                'shiroha_link_peer_identity');
        linkProcessCurrent = library.lookupFunction<
            Int32 Function(Uint32, Uint64),
            int Function(int, int)>('shiroha_link_process_current');
      }
      _healthy = library.lookupFunction<Uint32 Function(), int Function()>(
          'shiroha_relay_healthy');
      _allocate = library.lookupFunction<Pointer<Uint8> Function(Uint32),
          Pointer<Uint8> Function(int)>('shiroha_relay_allocate');
      _free = library.lookupFunction<Void Function(Pointer<Uint8>),
          void Function(Pointer<Uint8>)>('shiroha_relay_free');
      open = library.lookupFunction<Int32 Function(Uint32, Pointer<Uint64>),
          int Function(int, Pointer<Uint64>)>('shiroha_relay_open');
      accept =
          library.lookupFunction<Int32 Function(Uint64), int Function(int)>(
              'shiroha_relay_accept');
      state = library.lookupFunction<Int32 Function(Uint64), int Function(int)>(
          'shiroha_relay_state');
      appLaunchState =
          library.lookupFunction<Int32 Function(Uint64), int Function(int)>(
              'shiroha_relay_app_launch_state');
      close = library.lookupFunction<Int32 Function(Uint64), int Function(int)>(
          'shiroha_relay_close');
      disconnect =
          library.lookupFunction<Int32 Function(Uint64), int Function(int)>(
              'shiroha_relay_disconnect');
      read = library.lookupFunction<
          Int32 Function(Uint64, Pointer<Uint8>, Uint32, Pointer<Uint32>),
          int Function(
              int, Pointer<Uint8>, int, Pointer<Uint32>)>('shiroha_relay_read');
      write = library.lookupFunction<
          Int32 Function(Uint64, Pointer<Uint8>, Uint32, Pointer<Uint32>),
          int Function(int, Pointer<Uint8>, int,
              Pointer<Uint32>)>('shiroha_relay_write');
      buffer = _newBuffer(capacity);
      writeBuffer = _newBuffer(capacity);
      id = _newBuffer(8).cast<Uint64>();
      count = _newBuffer(4).cast<Uint32>();
      writeCount = _newBuffer(4).cast<Uint32>();
    } catch (_) {
      dispose();
      throw const LocalRelayException();
    }
  }
  static const capacity = 65536;
  final _buffers = <Pointer<Uint8>>[];
  late final Pointer<Uint8> Function(int) _allocate;
  late final void Function(Pointer<Uint8>) _free;
  late final int Function() _healthy;
  late final int Function(int, Pointer<Uint64>) open;
  late final int Function(int) accept, state, appLaunchState, close, disconnect;
  int Function(int)? linkPeerIdentity;
  int Function()? linkDiagnostic;
  int Function(int, int)? linkProcessCurrent;
  late final int Function(int, Pointer<Uint8>, int, Pointer<Uint32>) read,
      write;
  late final Pointer<Uint8> buffer, writeBuffer;
  late final Pointer<Uint64> id;
  late final Pointer<Uint32> count, writeCount;
  Pointer<Uint8> _newBuffer(int length) {
    final result = _allocate(length);
    if (result == nullptr) throw const LocalRelayException();
    _buffers.add(result);
    return result;
  }

  void dispose() {
    if (_buffers.isEmpty) return;
    for (final buffer in _buffers.reversed) {
      _free(buffer);
    }
    _buffers.clear();
    if (_healthy() != 1) throw const LocalRelayException(unsettled: true);
  }
}
