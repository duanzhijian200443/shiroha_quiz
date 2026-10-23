// Opt-in installed client evidence for the new product-root transport binding.
// Reuses the existing mailbox; it is not a production IPC or credential adapter.
import 'dart:async';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:shiroha_quiz/data/external/windows_tls_transport.dart';
import '../application/generated_question/generated_test_support.dart'
    show initializeGeneratedTests, submission;
import '../application/study_query/study_query_test_support.dart'
    show insertLegacyQuestion;
import 'fixtures/codex_synthetic_app_support.dart';
import 'fixtures/windows_app_transport_fixture.dart';
import 'dart:convert';

Map<String, dynamic> _data(Map<String, dynamic> result) {
  expect(result['error'], isNull);
  return (result['data'] as Map).cast<String, dynamic>();
}

void main() {
  initializeGeneratedTests();
  final executable = Platform.environment['SHIROHA_CODEX_EXE'];
  test('installed Codex seven tools use product App/P27/Host and owned Bridge',
      () async {
    final f = WindowsAppTransportFixture();
    await f.open();
    addTearDown(f.close);
    await insertLegacyQuestion(f.files.s.h.db,
        id: 'installed-question',
        bankName: 'bank',
        createdAt: 1,
        content: 'Synthetic needle');
    final root = await Directory(
            p.join(Directory.current.path, '.dart_tool', 'codex-client-tests'))
        .create(recursive: true);
    final home = await root.createTemp('Windows App composition ');
    final directory = await Directory(p.join(home.path, 'app-link')).create();
    final mailbox = CodexSyntheticAppLink(directory, () => f.bridge)..start();
    final client = CodexSyntheticClient(executable!, home, directory);
    addTearDown(() async {
      await client.disconnect();
      await mailbox.close();
      await home.delete(recursive: true);
    });
    await client
        .connect(); // Existing discovery/schema check: exactly seven tools.
    final targets = _data(await client.call('open_generation_context'));
    final target = (targets['items'] as List).first as Map;
    final context = _data(await client.call('open_generation_context',
        {'targetRef': target['targetRef']}))['contextRef'];
    final search = _data(await client
        .call('search_questions', {'contextRef': context, 'query': 'needle'}));
    final question = (search['items'] as List).single as Map;
    expect(
        _data(await client.call('get_question_detail', {
          'contextRef': context,
          'questionRef': question['questionRef']
        }))['sourceKind'],
        'legacy');
    final files = _data(
        await client.call('open_generation_context', {'contextRef': context}));
    final file = _data(await client.call('open_generation_context', {
      'contextRef': context,
      'fileRefs': [(files['items'] as List).first['fileRef']]
    }))['contextRef'];
    final retrieval = _data(await client.call(
        'retrieve_file_content', {'contextRef': file, 'query': 'needle'}));
    final hit = (retrieval['items'] as List).single as Map;
    expect(
        _data(await client.call('get_file_passage',
            {'contextRef': file, 'passageRef': hit['passageRef']}))['items'],
        isNotEmpty);
    final waiting = Completer<void>();
    final changes = f.approval.changes.listen((_) {
      if (f.approval.waitingForUser && !waiting.isCompleted) waiting.complete();
    });
    final staged = client.call('propose_generated_questions', {
      'contextRef': context,
      'submission': jsonDecode(submission(key: 'installed-owned'))
    });
    await Future.any([waiting.future, staged.then((_) {})]);
    await changes.cancel();
    expect(f.approval.waitingForUser, isTrue);
    expect(await f.files.s.h.count('generated_question_proposals'), 0);
    await f.approvalView.confirm(f.approvalView.pending!);
    expect(_data(await staged)['publication'], 'STAGED');
    expect(
        _data(await client.call('get_question_proposal',
            {'submissionKey': 'installed-owned'}))['lifecycleStatus'],
        'pending_review');
    expect(await f.files.s.h.count('generated_question_commit_receipts'), 0);
    // EOF closes this process composition. Reconnect gets a new owner and no
    // replay; existing independent-client regression owns its broader matrix.
    await client.disconnect();
    await mailbox.close();
    await f.host.whenConnectionsSettled;
    expect(f.clients.every((c) => c.writes.length == 1), isTrue);
    for (final connection in f.connections) {
      for (final resource in TlsResource.values) {
        expect(connection.budget.used(resource), 0);
      }
    }
  },
      skip: Platform.isWindows && executable != null
          ? false
          : 'UNVERIFIED: Windows and explicit SHIROHA_CODEX_EXE required.');
}
