import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:shiroha_quiz/data/external/windows_local_relay.dart';

void main() {
  test('framing preserves Unicode and exact request/result correlation data',
      () {
    final value = <String, Object?>{
      'version': 1,
      'id': 7,
      'tool': 'search_questions',
      'arguments': <String, Object?>{'query': '开发题库', 'pageSize': 1}
    };
    final bytes = LocalRelayFrame.encode(value);
    expect(ByteData.sublistView(bytes).getUint32(0, Endian.little),
        bytes.length - 4);
    expect(LocalRelayFrame.decode(Uint8List.sublistView(bytes, 4)), value);
  });

  test('malformed UTF-8, scalar JSON, oversize and excessive nesting refuse',
      () {
    for (final bytes in <Uint8List>[
      Uint8List.fromList([0xff]),
      Uint8List.fromList(utf8.encode('[]')),
      Uint8List.fromList(utf8.encode('{broken')),
      Uint8List(LocalRelayFrame.maxBytes + 1),
      Uint8List.fromList(utf8.encode('{"x":${'[' * 40}0${']' * 40}}')),
    ]) {
      expect(() => LocalRelayFrame.decode(bytes),
          throwsA(isA<LocalRelayException>()));
    }
    expect(
        () => LocalRelayFrame.encode({'body': 'x' * LocalRelayFrame.maxBytes}),
        throwsA(isA<LocalRelayException>()));
    final cycle = <String, Object?>{};
    cycle['cycle'] = cycle;
    expect(() => LocalRelayFrame.encode(cycle),
        throwsA(isA<LocalRelayException>()));
  });

  test('normal App owns relay while protected entries retain admission checks',
      () {
    final main = File('lib/main.dart').readAsStringSync();
    final registration =
        File('lib/composition/mcp_vnext_windows_registration.dart')
            .readAsStringSync();
    final bootstrap = File('lib/composition/mcp_vnext_windows_bootstrap.dart')
        .readAsStringSync();
    final adapter =
        File('tool/external/codex_relay_candidate.dart').readAsStringSync();
    expect(main,
        contains('McpVnextWindowsAppRegistration.appOwnedRelay(integration,'));
    expect(registration, contains('await requireSecurityAdmission()'));
    expect(bootstrap, contains('await requireSecurityAdmission()'));
    expect(File('tool/external/bridge_candidate.dart').readAsStringSync(),
        contains('await serveWindowsBridgeStdio();'));
    expect(adapter,
        contains('VnextMcpServer(VnextLocalRelayPort()).serveStdio()'));
    for (final prohibited in [
      'DatabaseHelper',
      'Fake',
      'DirectDatabase',
      'OPENAI_API_KEY'
    ]) {
      expect(adapter, isNot(contains(prohibited)));
    }
  });
}
