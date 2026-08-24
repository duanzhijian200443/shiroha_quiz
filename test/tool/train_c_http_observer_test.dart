import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:shiroha_quiz/services/llm_providers/zhipu_ocr_client.dart';

import '../../tool/train_c_http_observer.dart';
import '../../tool/train_c_live_entrypoint.dart';

void main() {
  test('ledger exposes safe request aggregates only', () {
    final ledger = TrainCRequestLedger();
    ledger.beginParse(expectedLayoutRequests: 1);

    final layout = ledger.recordDispatchMethod('POST');
    final crop = ledger.recordDispatchMethod('GET');
    ledger.recordResponse(eventIndex: layout, statusCode: 200, durationMs: 2);
    ledger.recordResponse(eventIndex: crop, statusCode: 302, durationMs: 3);

    final encoded = jsonEncode(ledger.safeSummary());
    expect(encoded, isNot(contains('provider.example')));
    expect(encoded, isNot(contains('PRIVATE_REQUEST_BODY')));
    expect(ledger.layoutPostCount, 1);
    expect(ledger.providerDispatchCount, 2);
    expect(ledger.providerResponseCount, 2);
    expect(ledger.remoteCropRequestCount, 1);
    expect(ledger.unexpectedProviderRequestCount, 0);
    expect(ledger.networkFailureCount, 0);
  });

  test('layout expectation is bound to the production 30-page chunk', () {
    expect(const ZhipuOcrClient().pdfPageChunkSize, 30);
    expect(
      const ZhipuOcrClient().pdfPageChunkSize,
      trainCProductionPdfPageChunkSize,
    );

    for (final expectation in <(int, int)>[
      (21, 1),
      (22, 1),
      (30, 1),
      (31, 2),
    ]) {
      expect(
        trainCExpectedLayoutRequestCount(
          pageCount: expectation.$1,
          pageChunkSize: trainCProductionPdfPageChunkSize,
        ),
        expectation.$2,
      );
    }

    // A caller-reported chunk of 20 cannot change the acceptance oracle.
    expect(
      trainCExpectedLayoutRequestCount(pageCount: 25, pageChunkSize: 20),
      1,
    );

    final ledger = TrainCRequestLedger();
    ledger.beginParse(
      expectedLayoutRequests: trainCExpectedLayoutRequestCount(
        pageCount: 22,
        pageChunkSize: trainCProductionPdfPageChunkSize,
      ),
    );
    final events = <int>[
      ledger.recordDispatchMethod('POST'),
      ledger.recordDispatchMethod('GET'),
      ledger.recordDispatchMethod('GET'),
      ledger.recordDispatchMethod('GET'),
    ];
    for (final event in events) {
      ledger.recordResponse(eventIndex: event, statusCode: 200, durationMs: 1);
    }

    expect(ledger.providerDispatchCount, 4);
    expect(ledger.providerResponseCount, 4);
    expect(ledger.safeSummary()['layoutPostCount'], 1);
    expect(ledger.safeSummary()['remoteCropRequestCount'], 3);
    expect(ledger.safeSummary()['networkFailureCount'], 0);
  });

  test('second layout request is rejected before a new event is recorded', () {
    final ledger = TrainCRequestLedger();
    ledger.beginParse(expectedLayoutRequests: 1);
    ledger.recordDispatchMethod('POST');

    expect(
      () => ledger.recordDispatchMethod('POST'),
      throwsA(
        isA<TrainCProtocolException>().having(
          (error) => error.code,
          'code',
          'TRAIN_C_PROVIDER_REQUEST_COUNT_FAILURE',
        ),
      ),
    );
    expect(ledger.providerDispatchCount, 1);
  });

  test('provider dispatch is forbidden after parse', () {
    final ledger = TrainCRequestLedger();
    ledger.beginParse(expectedLayoutRequests: 1);
    final event = ledger.recordDispatchMethod('POST');
    ledger.recordResponse(eventIndex: event, statusCode: 200, durationMs: 1);
    ledger.finishParse(successful: true);
    ledger.enterPhase(TrainCPhase.commit);
    ledger.enterPhase(TrainCPhase.restart);

    expect(
      () => ledger.recordDispatchMethod('GET'),
      throwsA(
        isA<TrainCProtocolException>().having(
          (error) => error.code,
          'code',
          'TRAIN_C_PROVIDER_REQUEST_COUNT_FAILURE',
        ),
      ),
    );
    expect(ledger.providerDispatchCount, 2);
    expect(ledger.unexpectedProviderRequestCount, 1);
  });

  test('offline entrypoint proves provider dispatch is zero', () {
    final proof = TrainCLiveEntrypoint.offlineProof();

    expect(proof['stage'], 'TRAIN-C-H0');
    expect(proof['status'], 'PASS');
    expect(proof['liveRun'], 'BLOCKED');
    expect(proof['authority'], 'offline_harness_only');
    expect(proof['providerDispatchCount'], 0);
    expect(proof['providerResponseCount'], 0);
  });
}
