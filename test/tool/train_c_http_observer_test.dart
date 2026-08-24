import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;

import '../../tool/train_c_http_observer.dart';
import '../../tool/train_c_live_entrypoint.dart';

void main() {
  test('observer records only safe request aggregates', () async {
    final client = _FakeClient();
    final ledger = TrainCRequestLedger();
    ledger.beginParse(expectedLayoutRequests: 1);
    final observer = TrainCHttpObserver(innerClient: client, ledger: ledger);

    final response = await observer.post(
      Uri.parse('https://provider.example/layout'),
      body: 'PRIVATE_REQUEST_BODY',
    );

    expect(response.statusCode, 200);
    expect(client.sendCount, 1);
    final encoded = jsonEncode(ledger.safeSummary());
    expect(encoded, isNot(contains('provider.example')));
    expect(encoded, isNot(contains('PRIVATE_REQUEST_BODY')));
    expect(ledger.providerDispatchCount, 1);
    expect(ledger.providerResponseCount, 1);
    expect(ledger.remoteCropRequestCount, 0);
    expect(ledger.unexpectedProviderRequestCount, 0);
  });

  test('observer classifies crop GET without reading its URL', () async {
    final client = _FakeClient();
    final ledger = TrainCRequestLedger();
    ledger.beginParse(expectedLayoutRequests: 1);
    final observer = TrainCHttpObserver(innerClient: client, ledger: ledger);

    await observer.post(Uri.parse('https://provider.example/layout'));
    await observer.get(Uri.parse('https://cdn.example/crop'));

    expect(ledger.providerDispatchCount, 2);
    expect(ledger.remoteCropRequestCount, 1);
    expect(ledger.providerResponseCount, 2);
    expect(ledger.safeSummary()['responseStatusCounts'], <String, int>{
      'success': 2,
    });
  });

  test('second layout request is rejected before transport dispatch', () async {
    final client = _FakeClient();
    final ledger = TrainCRequestLedger();
    ledger.beginParse(expectedLayoutRequests: 1);
    final observer = TrainCHttpObserver(innerClient: client, ledger: ledger);

    await observer.post(Uri.parse('https://provider.example/layout'));
    expect(
      () => observer.post(Uri.parse('https://provider.example/retry')),
      throwsA(
        isA<TrainCProtocolException>().having(
          (error) => error.code,
          'code',
          'TRAIN_C_PROVIDER_REQUEST_COUNT_FAILURE',
        ),
      ),
    );
    expect(client.sendCount, 1);
  });

  test('provider dispatch is forbidden after parse', () async {
    final client = _FakeClient();
    final ledger = TrainCRequestLedger();
    ledger.beginParse(expectedLayoutRequests: 1);
    final observer = TrainCHttpObserver(innerClient: client, ledger: ledger);

    await observer.post(Uri.parse('https://provider.example/layout'));
    ledger.finishParse(successful: true);
    ledger.enterPhase(TrainCPhase.commit);
    ledger.enterPhase(TrainCPhase.restart);

    expect(
      () => observer.get(Uri.parse('https://provider.example/late')),
      throwsA(
        isA<TrainCProtocolException>().having(
          (error) => error.code,
          'code',
          'TRAIN_C_PROVIDER_REQUEST_COUNT_FAILURE',
        ),
      ),
    );
    expect(client.sendCount, 1);
  });

  test('offline entrypoint proves provider dispatch is zero', () {
    final proof = TrainCLiveEntrypoint.offlineProof();

    expect(proof['stage'], 'TRAIN-C-H0');
    expect(proof['status'], 'PASS');
    expect(proof['liveRun'], 'BLOCKED');
    expect(proof['providerDispatchCount'], 0);
    expect(proof['providerResponseCount'], 0);
  });
}

final class _FakeClient extends http.BaseClient {
  var sendCount = 0;

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    sendCount++;
    return http.StreamedResponse(
      Stream<List<int>>.fromIterable(<List<int>>[
        utf8.encode('PRIVATE_RESPONSE_BODY'),
      ]),
      200,
      request: request,
    );
  }
}
