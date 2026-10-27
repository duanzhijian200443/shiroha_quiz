import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

/// Public material from the current App's validated P25 owner. This packet is
/// meaningful only after the receiving root independently verifies its parent.
final class WindowsDevelopmentBootstrap {
  WindowsDevelopmentBootstrap({
    required this.pairingUi,
    required this.expiresAtUtcMs,
    required List<int> issuerDer,
    required this.installationId,
    required List<int> serverLeafDigest,
    required this.epoch,
  })  : issuerDer = Uint8List.fromList(issuerDer).asUnmodifiableView(),
        serverLeafDigest =
            Uint8List.fromList(serverLeafDigest).asUnmodifiableView();

  static const maxBytes = 4096;
  static const lifetime = Duration(hours: 8);
  static const _magic = [83, 72, 68, 69, 86, 48, 48, 49];
  final bool pairingUi;
  final int expiresAtUtcMs;
  final Uint8List issuerDer, serverLeafDigest;
  final String installationId;
  final BigInt epoch;

  void requireCurrentPublication(BigInt observedEpoch) {
    if (epoch < BigInt.one || observedEpoch != epoch) {
      throw StateError('Current App publication unavailable');
    }
  }

  void requireCurrent(DateTime now, {required bool expectedPairingUi}) {
    final remaining = expiresAtUtcMs - now.toUtc().millisecondsSinceEpoch;
    if (pairingUi != expectedPairingUi ||
        remaining <= 0 ||
        remaining > lifetime.inMilliseconds ||
        issuerDer.isEmpty ||
        issuerDer.length > 1024 ||
        serverLeafDigest.length != 32 ||
        !RegExp(r'^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$')
            .hasMatch(installationId) ||
        epoch < BigInt.zero ||
        epoch > (BigInt.one << 64) - BigInt.one) {
      throw StateError('Development bootstrap unavailable');
    }
  }

  Uint8List encode(DateTime now) {
    requireCurrent(now, expectedPairingUi: pairingUi);
    final body = utf8.encode(jsonEncode([
      1,
      pairingUi ? 'pairing' : 'business',
      expiresAtUtcMs,
      base64Encode(issuerDer),
      installationId,
      base64Encode(serverLeafDigest),
      epoch.toString(),
    ]));
    if (body.length > maxBytes) {
      throw StateError('Development bootstrap unavailable');
    }
    final bytes = Uint8List(12 + body.length)..setRange(0, 8, _magic);
    ByteData.sublistView(bytes).setUint32(8, body.length, Endian.little);
    bytes.setRange(12, bytes.length, body);
    return bytes;
  }

  static WindowsDevelopmentBootstrap _decode(List<int> bytes) {
    try {
      final value = jsonDecode(utf8.decode(bytes));
      if (value is! List ||
          value.length != 7 ||
          value[0] is! int ||
          value[0] != 1 ||
          !const ['pairing', 'business'].contains(value[1]) ||
          value[2] is! int ||
          value[3] is! String ||
          value[4] is! String ||
          value[5] is! String ||
          value[6] is! String ||
          !RegExp(r'^(0|[1-9][0-9]{0,19})$').hasMatch(value[6] as String)) {
        throw const FormatException();
      }
      final issuer = base64Decode(value[3] as String);
      final digest = base64Decode(value[5] as String);
      if (base64Encode(issuer) != value[3] ||
          base64Encode(digest) != value[5]) {
        throw const FormatException();
      }
      return WindowsDevelopmentBootstrap(
          pairingUi: value[1] == 'pairing',
          expiresAtUtcMs: value[2] as int,
          issuerDer: issuer,
          installationId: value[4] as String,
          serverLeafDigest: digest,
          epoch: BigInt.parse(value[6] as String));
    } catch (_) {
      throw StateError('Development bootstrap unavailable');
    }
  }

  @override
  String toString() => 'WindowsDevelopmentBootstrap(REDACTED)';
}

/// One original stdin subscription. The preface is removed once; all remainder
/// bytes, including a shared chunk's tail, reach the original MCP SDK unchanged.
final class WindowsBootstrapInput {
  WindowsBootstrapInput(Stream<List<int>> input, {required this.isCurrent}) {
    _remainder = StreamController<List<int>>(
        onListen: () {
          _attached = true;
          _subscription.resume();
        },
        onPause: () => _subscription.pause(),
        onResume: () => _subscription.resume(),
        onCancel: () => _subscription.cancel());
    _subscription = input.listen(_data,
        onError: (Object _, StackTrace __) => _fail(), onDone: _done);
    _deadline = Timer(const Duration(seconds: 5), _fail);
    _monitor = Timer.periodic(const Duration(milliseconds: 20), (_) {
      if (!isCurrent()) _fail();
    });
    unawaited(packet
        .catchError(
            (Object _) => throw StateError('Development bootstrap unavailable'))
        .then<void>((_) {}, onError: (Object _, StackTrace __) {}));
  }

  final bool Function() isCurrent;
  final _ready = Completer<WindowsDevelopmentBootstrap>();
  Future<WindowsDevelopmentBootstrap> get packet => _ready.future;
  bool get isOpen => !_closed && !_inputEnded;
  final _prefix = <int>[];
  late final StreamSubscription<List<int>> _subscription;
  late final StreamController<List<int>> _remainder;
  Timer? _deadline, _monitor;
  bool _complete = false,
      _closed = false,
      _attached = false,
      _inputEnded = false;
  Future<void>? _closing, _remainderClosing;
  Stdin get remainingStdin => _BootstrapStdin(_remainder.stream);

  void _data(List<int> chunk) {
    if (_closed) return;
    if (!isCurrent()) {
      _fail();
      return;
    }
    if (_complete) {
      _remainder.add(chunk);
      return;
    }
    var offset = 0;
    while (offset < chunk.length && !_complete) {
      _prefix.add(chunk[offset++]);
      if (_prefix.length <= 8 &&
          _prefix.last !=
              WindowsDevelopmentBootstrap._magic[_prefix.length - 1]) {
        _fail();
        return;
      }
      if (_prefix.length >= 12) {
        final length =
            ByteData.sublistView(Uint8List.fromList(_prefix.take(12).toList()))
                .getUint32(8, Endian.little);
        if (length == 0 || length > WindowsDevelopmentBootstrap.maxBytes) {
          _fail();
          return;
        }
        if (_prefix.length == length + 12) {
          try {
            final value =
                WindowsDevelopmentBootstrap._decode(_prefix.sublist(12));
            _complete = true;
            _deadline?.cancel();
            _subscription.pause();
            if (offset < chunk.length) _remainder.add(chunk.sublist(offset));
            _ready.complete(value);
            _prefix.clear();
          } catch (_) {
            _fail();
          }
        }
      }
    }
  }

  void _done() {
    _inputEnded = true;
    if (!_complete) {
      _fail();
      return;
    }
    _monitor?.cancel();
    _remainderClosing ??= _remainder.close();
  }

  /// Pairing has no business bytes. Keep the original subscription consuming so
  /// parent EOF closes the local window even while the parent process is alive.
  Future<void> watchControlLifetime(Future<void> Function() settle) async {
    try {
      await for (final bytes in remainingStdin) {
        if (bytes.isNotEmpty) throw StateError('Unexpected pairing input');
      }
    } finally {
      await settle();
    }
  }

  void _fail() {
    if (_closed) return;
    if (!_ready.isCompleted) {
      _ready.completeError(StateError('Development bootstrap unavailable'));
    }
    unawaited(close().then((_) {}, onError: (Object _, StackTrace __) {}));
  }

  Future<void> close() {
    _closed = true;
    _deadline?.cancel();
    _monitor?.cancel();
    return _closing ??= () async {
      await _subscription.cancel();
      if (!_ready.isCompleted) {
        _ready.completeError(StateError('Development bootstrap unavailable'));
      }
      if (!_attached) unawaited(_remainder.stream.drain<void>());
      await (_remainderClosing ??= _remainder.close());
    }();
  }
}

final class _BootstrapStdin extends Stream<List<int>> implements Stdin {
  _BootstrapStdin(this._stream);
  final Stream<List<int>> _stream;
  @override
  StreamSubscription<List<int>> listen(void Function(List<int>)? onData,
          {Function? onError, void Function()? onDone, bool? cancelOnError}) =>
      _stream.listen(onData,
          onError: onError, onDone: onDone, cancelOnError: cancelOnError);
  @override
  bool get hasTerminal => false;
  @override
  bool get supportsAnsiEscapes => false;
  @override
  bool get echoMode => false;
  @override
  bool get echoNewlineMode => false;
  @override
  bool get lineMode => false;
  @override
  set echoMode(bool value) => throw UnsupportedError('Bootstrap stream');
  @override
  set echoNewlineMode(bool value) => throw UnsupportedError('Bootstrap stream');
  @override
  set lineMode(bool value) => throw UnsupportedError('Bootstrap stream');
  @override
  int readByteSync() => throw UnsupportedError('Bootstrap stream');
  @override
  String? readLineSync(
          {Encoding encoding = utf8, bool retainNewlines = false}) =>
      throw UnsupportedError('Bootstrap stream');
}
