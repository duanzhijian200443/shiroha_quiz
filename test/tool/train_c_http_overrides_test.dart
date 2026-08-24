import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import '../../tool/train_c_http_observer.dart';
import '../../tool/train_c_http_overrides.dart';

void main() {
  test('connectionFactory and findProxy setters delegate unchanged', () {
    final ledger = TrainCRequestLedger();
    final inner = _RecordingHttpClient();
    final observed = TrainCObservedHttpClient(inner, ledger);

    String findProxy(Uri uri) => 'DIRECT';

    Future<ConnectionTask<Socket>> connectionFactory(
      Uri uri,
      String? proxyHost,
      int? proxyPort,
    ) async {
      throw StateError('test callback must not be invoked');
    }

    observed.findProxy = findProxy;
    observed.connectionFactory = connectionFactory;

    expect(inner.findProxyCallback, same(findProxy));
    expect(inner.connectionFactoryCallback, same(connectionFactory));
  });

  test('HttpOverrides observes requests without consuming response body',
      () async {
    final ledger = TrainCRequestLedger();
    ledger.beginParse(expectedLayoutRequests: 1);

    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final handled = Completer<void>();
    final subscription = server.listen((request) {
      request.response.statusCode = 200;
      request.response.add(utf8.encode('SAFE_RESPONSE_BODY'));
      unawaited(
        request.response.close().then((_) {
          if (!handled.isCompleted) handled.complete();
        }),
      );
    });

    try {
      final body = await HttpOverrides.runWithHttpOverrides(
        () async {
          final client = HttpClient()..findProxy = (_) => 'DIRECT';
          final request = await client.getUrl(
            Uri.parse('http://127.0.0.1:${server.port}/opaque'),
          );
          final response = await request.close();
          final responseBody = await utf8.decoder.bind(response).join();
          client.close();
          return responseBody;
        },
        TrainCHttpOverrides(ledger),
      );
      await handled.future;
      await Future<void>.value();

      expect(body, 'SAFE_RESPONSE_BODY');
      expect(ledger.providerDispatchCount, 1);
      expect(ledger.remoteCropRequestCount, 1);
      expect(ledger.providerResponseCount, 1);
      expect(ledger.networkFailureCount, 0);
      expect(ledger.safeSummary(), isNot(contains('127.0.0.1')));
    } finally {
      await subscription.cancel();
      await server.close(force: true);
    }
  });
}

final class _RecordingHttpClient implements HttpClient {
  String Function(Uri)? findProxyCallback;
  Future<ConnectionTask<Socket>> Function(
    Uri,
    String?,
    int?,
  )? connectionFactoryCallback;

  @override
  set findProxy(String Function(Uri)? value) {
    findProxyCallback = value;
  }

  @override
  set connectionFactory(
    Future<ConnectionTask<Socket>> Function(
      Uri,
      String?,
      int?,
    )? value,
  ) {
    connectionFactoryCallback = value;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) {
    throw UnsupportedError('unused fake client member');
  }
}
