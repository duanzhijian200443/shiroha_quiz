// Test-only byte delivery between OS processes, behind the existing Fake TLS
// seam. These files are NOT a product transport or a security implementation.
import 'dart:async';
import 'dart:io';
import 'dart:typed_data';
import 'package:path/path.dart' as p;
import 'package:shiroha_quiz/data/external/windows_tls_transport.dart';
import '../../data/external/fixtures/public_pairing_process_support.dart';

final class ProcessTestChannel implements TlsChannel {
  ProcessTestChannel(this.root, this.outgoing, this.incoming, this.peerDer);
  final Directory root;
  final String outgoing, incoming;
  @override
  final Uint8List peerDer;
  int _sent = 0, _received = 0;
  Uint8List? _rest;
  bool _open = true;
  Future<void>? _closing;
  @override
  bool get isOpen => _open;
  @override
  Future<void> write(Uint8List bytes) async {
    if (!_open) throw StateError('Test channel closed');
    await publishPublic(root, '$outgoing-${_sent++}', bytes);
  }

  @override
  Future<Uint8List?> read(int maximum) async {
    final deadline = Stopwatch()..start();
    while (_open) {
      final rest = _rest;
      if (rest != null) {
        final count = rest.length < maximum ? rest.length : maximum;
        _rest =
            count == rest.length ? null : Uint8List.sublistView(rest, count);
        return Uint8List.sublistView(rest, 0, count);
      }
      final file = File(p.join(root.path, '$incoming-$_received'));
      if (await file.exists()) {
        _rest = await file.readAsBytes();
        _received++;
      } else if (await File(p.join(root.path, '$incoming-closed')).exists()) {
        _open = false;
      } else {
        if (deadline.elapsed > const Duration(seconds: 15)) {
          throw StateError('Test channel delivery stalled');
        }
        await Future<void>.delayed(const Duration(milliseconds: 5));
      }
    }
    return null;
  }

  @override
  Future<void> close() => _closing ??= () async {
        _open = false;
        await publishPublic(root, '$outgoing-closed', [1]);
      }();
}

final class ProcessTestRawPeer implements TlsRawPeer {
  ProcessTestRawPeer(this.channel);
  final ProcessTestChannel channel;
  @override
  Future<TlsChannel> upgrade(TlsContextPlan plan) async => channel;
  @override
  Future<void> close() => channel.close();
}

final class ProcessTestBridgeIo implements TlsBridgeIo {
  ProcessTestBridgeIo(this.root, this.number, this.serverDer);
  final Directory root;
  final int number;
  final Uint8List serverDer;
  @override
  Future<TlsChannel> connect(int port, TlsContextPlan plan) async {
    await publishPublic(root, 'connect-$number', [1]);
    return ProcessTestChannel(
        root, 'client-$number', 'server-$number', serverDer);
  }
}
