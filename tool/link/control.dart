import 'dart:convert';
import 'dart:io';
import 'package:shiroha_quiz/data/external/windows_local_relay.dart';

Future<void> main(List<String> arguments) async {
  if (arguments.isEmpty ||
      !const {
        'inspect',
        'claim',
        'recover',
        'select',
        'connect',
        'disconnect',
        'shutdown'
      }.contains(arguments.first) ||
      (arguments.first == 'select'
          ? arguments.length != 3
          : arguments.first == 'recover'
              ? arguments.length != 2
              : arguments.length != 1)) {
    stderr.writeln(
        'usage: shiroha_link_control inspect|claim|connect|disconnect|shutdown|select <target> <selection-revision>|recover <state-revision>');
    exitCode = 64;
    return;
  }
  WindowsLocalRelay? connection;
  var phase = 'native_open';
  try {
    connection = WindowsLocalRelay.openLinkControl(server: false);
    phase = 'native_accept';
    await connection.accept();
    phase = 'hello_read';
    final hello = await connection.receive(const Duration(seconds: 5));
    phase = 'hello_validation';
    if (hello.length != 3 ||
        hello['version'] != 1 ||
        hello['ticket'] is! String ||
        hello['runId'] is! String) {
      throw StateError('invalid_protocol');
    }
    phase = 'request_write';
    await connection.send({
      ...hello,
      'action': arguments.first,
      'targetRef': arguments.first == 'select' ? arguments[1] : null,
      'expectedSelectionRevision':
          arguments.first == 'select' ? int.tryParse(arguments[2]) : null,
      'expectedRevision':
          arguments.first == 'recover' ? int.tryParse(arguments[1]) : null,
    }, const Duration(seconds: 5));
    phase = 'result_read';
    final result = await connection.receive(const Duration(seconds: 150));
    stdout.writeln(jsonEncode(result));
    await stdout.flush();
    phase = 'receipt_write';
    await connection
        .send({...hello, 'kind': 'received'}, const Duration(seconds: 5));
    phase = 'close_wait';
    await connection.disconnected.timeout(const Duration(seconds: 6));
    if (result['error'] != null) exitCode = 78;
  } catch (error) {
    final code = error is LocalRelayException &&
            const {1, 2, 3, 4, 5, 6, 10, 11, 12, 20, 21, 22, 23}
                .contains(error.linkDiagnostic)
        ? error.linkDiagnostic
        : 0;
    stderr.writeln('link_control_${phase}_unavailable_d$code');
    exitCode = 78;
  } finally {
    await connection?.close();
  }
}
