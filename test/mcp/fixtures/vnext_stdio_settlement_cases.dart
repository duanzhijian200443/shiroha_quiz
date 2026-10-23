import 'dart:async';
import 'package:flutter_test/flutter_test.dart';
import 'package:mcp_dart/mcp_dart.dart';
import 'package:shiroha_quiz/mcp/vnext_mcp_server.dart';

final class _Port implements VnextMcpPort {
  final reached = Completer<void>();
  final drain = Completer<void>();
  int closes = 0;
  @override
  Future<void> close() {
    closes++;
    if (!reached.isCompleted) reached.complete();
    return drain.future;
  }

  @override
  Future<Map<String, Object?>> call(String tool, Map<String, dynamic> arguments,
          {required Stream<void> cancelled,
          required bool Function() available}) async =>
      vnextFailure('unavailable');
}

void stdioSettlementCases() {
  for (final eof in [false, true]) {
    test('stdio eof=$eof joins one original drain across repeated close',
        () async {
      final port = _Port();
      final protocol =
          McpServer(const Implementation(name: 'probe', version: '1'));
      final server = VnextMcpServer(port, protocolServer: protocol);
      if (eof) protocol.server.onclose!();
      final closing = server.close();
      expect(identical(closing, server.close()), isTrue);
      await port.reached.future;
      var settled = false;
      final result = closing.then((_) => settled = true);
      await Future<void>.value();
      expect(settled, isFalse);
      expect(port.closes, 1);
      port.drain.complete();
      await result;
      await server.close();
      expect(port.closes, 1);
    });
  }
  test('EOF cleanup failure stays failed without another port close', () async {
    final port = _Port();
    final protocol =
        McpServer(const Implementation(name: 'probe', version: '1'));
    final server = VnextMcpServer(port, protocolServer: protocol);
    protocol.server.onclose!();
    await port.reached.future;
    final failure = StateError('synthetic drain failure');
    final assertion = expectLater(server.close(), throwsA(same(failure)));
    port.drain.completeError(failure);
    await assertion;
    await expectLater(server.close(), throwsA(same(failure)));
    expect(port.closes, 1);
  });
}
