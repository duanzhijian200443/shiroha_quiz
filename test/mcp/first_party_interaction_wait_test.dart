import 'dart:async';
import 'package:flutter_test/flutter_test.dart';
import 'fixtures/first_party_interaction_cases.dart' show interactionRead;

void main() {
  testWidgets(
      'interaction read joins real delayed I/O and propagates its result',
      (tester) async {
    var finished = false;
    final value = await interactionRead(tester, () async {
      await Future<void>.delayed(const Duration(milliseconds: 300));
      finished = true;
      return 17;
    });
    expect(finished, isTrue);
    expect(value, 17);
  });

  testWidgets('an unsettled original still fails the bounded interaction wait',
      (tester) async {
    final original = Completer<int>();
    await expectLater(
        interactionRead(tester, () => original.future,
            timeout: const Duration(milliseconds: 30)),
        throwsA(isA<TestFailure>()));
    expect(original.isCompleted, isFalse);
    original.complete(1);
    await tester.runAsync(() => original.future);
  });
}
