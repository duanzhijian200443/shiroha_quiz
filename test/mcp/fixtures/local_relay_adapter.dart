// Test-only fixed peer. Raw mode intentionally retains the old client handle.
import 'dart:async';
import 'dart:convert';
import 'dart:ffi';
import 'dart:io';
import 'dart:typed_data';

import 'package:path/path.dart' as p;
import 'package:shiroha_quiz/data/external/windows_local_relay.dart';

Future<void> main(List<String> args) async {
  final root = p.dirname(Platform.resolvedExecutable);
  final label = args.single;
  final scenario = File(p.join(root, 'scenario')).readAsStringSync();
  final events = File(p.join(root, '$label.jsonl'));
  void report(String event) =>
      events.writeAsStringSync('${jsonEncode({'event': event, 'pid': pid})}\n',
          mode: FileMode.append, flush: true);
  final request = <String, Object?>{
    'version': 1,
    'id': 1,
    'tool': 'open_generation_context',
    'arguments': <String, Object?>{}
  };
  WindowsLocalRelay? monitored;
  _RetainedPeer? raw;
  try {
    if (scenario == 'monitored-idle' && label == 'old') {
      monitored = WindowsLocalRelay.openAdapter();
      await monitored.accept();
      await monitored.send(request, const Duration(seconds: 5));
      final response = await monitored.receive(const Duration(seconds: 10));
      if ((response['result'] as Map)['error'] != 'unavailable') {
        throw StateError('Unexpected response');
      }
      report('response');
      await monitored.disconnected;
      await monitored.close();
      report('closedOnLoss');
    } else {
      raw = _RetainedPeer(root);
      raw.send(request);
      if (label == 'old' && scenario.startsWith('pending-peer')) {
        report('requestSent');
        final watch = Stopwatch()..start();
        while (!File(p.join(root, 'disconnect-old')).existsSync() &&
            watch.elapsed < const Duration(seconds: 20)) {
          await Future<void>.delayed(const Duration(milliseconds: 20));
        }
        if (!File(p.join(root, 'disconnect-old')).existsSync()) {
          throw StateError('Peer disconnect was not requested');
        }
        report('peerClosing');
        return; // finally closes this original peer; no forced termination.
      }
      try {
        final response = await raw.receive();
        if ((response['result'] as Map)['error'] != 'unavailable') {
          throw StateError('Unexpected response');
        }
        report('response');
      } on LocalRelayException {
        if (label != 'old' ||
            !['inventory', 'sdk-error', 'failed-close'].contains(scenario)) {
          rethrow;
        }
        report('requestFailed');
      }
      if (label == 'old') {
        if (scenario == 'malformed') raw.send({'version': 0});
        final watch = Stopwatch()..start();
        while (raw.current && watch.elapsed < const Duration(seconds: 10)) {
          await Future<void>.delayed(const Duration(milliseconds: 20));
        }
        if (raw.current) throw StateError('Peer was not disconnected');
        report('lostWithHandleRetained');
      }
    }
    if (label == 'old') {
      final watch = Stopwatch()..start();
      while (!File(p.join(root, 'release-old')).existsSync() &&
          watch.elapsed < const Duration(seconds: 60)) {
        await Future<void>.delayed(const Duration(milliseconds: 20));
      }
    }
  } catch (_) {
    report('failed');
    exitCode = 1;
  } finally {
    await monitored?.close();
    raw?.close();
    report('closed');
  }
}

final class _RetainedPeer {
  _RetainedPeer(String root) {
    final dll = DynamicLibrary.open(p.join(root, 'shiroha_relay_native.dll'));
    final allocate = dll.lookupFunction<Pointer<Uint8> Function(Uint32),
        Pointer<Uint8> Function(int)>('shiroha_relay_allocate');
    _free = dll.lookupFunction<Void Function(Pointer<Uint8>),
        void Function(Pointer<Uint8>)>('shiroha_relay_free');
    _state = dll.lookupFunction<Int32 Function(Uint64), int Function(int)>(
        'shiroha_relay_state');
    _close = dll.lookupFunction<Int32 Function(Uint64), int Function(int)>(
        'shiroha_relay_close');
    _read = dll.lookupFunction<
        Int32 Function(Uint64, Pointer<Uint8>, Uint32, Pointer<Uint32>),
        int Function(
            int, Pointer<Uint8>, int, Pointer<Uint32>)>('shiroha_relay_read');
    _write = dll.lookupFunction<
        Int32 Function(Uint64, Pointer<Uint8>, Uint32, Pointer<Uint32>),
        int Function(
            int, Pointer<Uint8>, int, Pointer<Uint32>)>('shiroha_relay_write');
    _buffer = allocate(65536);
    _id = allocate(8).cast<Uint64>();
    _count = allocate(4).cast<Uint32>();
    final open = dll.lookupFunction<Int32 Function(Uint32, Pointer<Uint64>),
        int Function(int, Pointer<Uint64>)>('shiroha_relay_open');
    if (open(1, _id) != 0) {
      close();
      throw const LocalRelayException();
    }
    final appLaunchState =
        dll.lookupFunction<Int32 Function(Uint64), int Function(int)>(
            'shiroha_relay_app_launch_state');
    if (appLaunchState(_id.value) == 0) {
      close();
      throw StateError('Adapter cannot claim App launch custody');
    }
  }
  late final void Function(Pointer<Uint8>) _free;
  late final int Function(int) _state, _close;
  late final int Function(int, Pointer<Uint8>, int, Pointer<Uint32>) _read,
      _write;
  late final Pointer<Uint8> _buffer;
  late final Pointer<Uint64> _id;
  late final Pointer<Uint32> _count;
  bool get current => _state(_id.value) == 0;
  void send(Map<String, Object?> request) {
    final frame = LocalRelayFrame.encode(request);
    _buffer.asTypedList(frame.length).setAll(0, frame);
    if (_write(_id.value, _buffer, frame.length, _count) != 0 ||
        _count.value != frame.length) {
      throw const LocalRelayException();
    }
  }

  Future<Uint8List> _bytes(int length) async {
    final bytes = BytesBuilder(copy: false);
    final watch = Stopwatch()..start();
    while (
        bytes.length < length && watch.elapsed < const Duration(seconds: 10)) {
      final status = _read(_id.value, _buffer, length - bytes.length, _count);
      if (status == 1) {
        await Future<void>.delayed(const Duration(milliseconds: 10));
        continue;
      }
      if (status != 0) throw const LocalRelayException();
      bytes.add(Uint8List.fromList(_buffer.asTypedList(_count.value)));
    }
    if (bytes.length != length) throw const LocalRelayException();
    return bytes.takeBytes();
  }

  Future<Map<String, Object?>> receive() async {
    final size =
        ByteData.sublistView(await _bytes(4)).getUint32(0, Endian.little);
    if (size == 0 || size > 65536) throw const LocalRelayException();
    return LocalRelayFrame.decode(await _bytes(size));
  }

  void close() {
    if (_id.value != 0 && _close(_id.value) != 0) {
      throw const LocalRelayException(unsettled: true);
    }
    _free(_buffer);
    _free(_id.cast());
    _free(_count.cast());
  }
}
