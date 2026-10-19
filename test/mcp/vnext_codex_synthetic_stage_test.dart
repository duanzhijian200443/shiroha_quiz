// Real installed Codex MCP calls against the SAME synthetic App as SDK checks.
// No model turn, production Host, private bank or global configuration access.
import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:shiroha_quiz/application/capabilities/capability.dart';
import 'package:shiroha_quiz/domain/generated_question/generated_question_contract.dart';
import 'package:shiroha_quiz/mcp/vnext_mcp_composition_root.dart';
import 'package:shiroha_quiz/ui/dependencies/generated_question_dependencies_scope.dart';
import 'package:shiroha_quiz/ui/generated_question/generated_proposal_controllers.dart';
import 'package:shiroha_quiz/ui/generated_question/generated_proposal_review_screen.dart';
import '../application/generated_question/generated_test_support.dart';
import '../ui/generated_question/generated_ui_test_support.dart'
    show settleGenerated, tapGenerated;
import 'fixtures/codex_app_server_support.dart';
import 'fixtures/codex_synthetic_app_support.dart';
import 'fixtures/vnext_mcp_test_support.dart' show EndToEndHarness, batch;

const _fixtureName = 'vnext_codex_synthetic_stdio_fixture.dart';

void main() {
  initializeGeneratedTests();
  final executable = Platform.environment['SHIROHA_CODEX_EXE'];
  final skip = Platform.isWindows && executable != null
      ? false
      : 'Windows + explicit SHIROHA_CODEX_EXE required.';
  final repo = Directory.current.path;
  late Directory home;
  late EndToEndHarness h;
  late CodexSyntheticAppLink link;
  InstalledCodex? client;

  setUp(() async {
    final root = Directory(p.join(repo, '.dart_tool', 'codex-client-tests'));
    await root.create(recursive: true);
    home = await root.createTemp('Codex STAGE 合成 ');
    h = EndToEndHarness();
    await h.open();
    // The installed client can time out a cold first content read; warm the
    // real App read path before the asserted Codex calls.
    await h.warmRead();
    final mailbox = await Directory(p.join(home.path, 'app-link')).create();
    link = CodexSyntheticAppLink(mailbox, () => h.composition)..start();
  });

  Future<void> disconnect() async {
    final current = client;
    if (current == null) return;
    expect(await current.rpc.close(), 0);
    expect(current.rpc.forcedClose, isFalse);
    expect(current.rpc.protocolClean, isTrue);
    client = null;
    // Each actual MCP process records its own PID, including reconnects. Check
    // the recorded process identity, not just the PID, because Windows can
    // immediately reuse a PID for an unrelated process such as conhost.exe.
    final pidFiles = await link.directory
        .list()
        .where((entry) =>
            entry is File &&
            RegExp(r'^server-[0-9]+\.pid$').hasMatch(p.basename(entry.path)))
        .cast<File>()
        .toList();
    expect(pidFiles, isNotEmpty, reason: 'Expected a recorded MCP server PID.');
    for (final entry in pidFiles) {
      final serverPid = int.parse(await entry.readAsString());
      final status = await Process.run('powershell.exe', [
        '-NoProfile',
        '-NonInteractive',
        '-Command',
        "(Get-CimInstance Win32_Process -Filter 'ProcessId=$serverPid')"
            '.CommandLine',
      ]);
      expect(status.exitCode, 0);
      expect((status.stderr as String).trim(), isEmpty);
      final commandLine = (status.stdout as String).trim();
      expect(commandLine.contains(_fixtureName), isFalse,
          reason: 'Synthetic MCP process $serverPid must close on Codex EOF.');
      await entry.delete();
    }
  }

  tearDown(() async {
    try {
      await disconnect();
    } finally {
      await link.close();
      await h.close();
      await home.delete(recursive: true);
      expect(home.existsSync(), isFalse);
    }
  });

  Future<InstalledCodex> connect() async {
    if (executable == null ||
        !File(executable).existsSync() ||
        p.extension(executable).toLowerCase() != '.exe') {
      fail('SHIROHA_CODEX_EXE must name an installed codex.exe.');
    }
    final current = InstalledCodex(executable, repo, home);
    client = current;
    await current.configure(
        entrypoint: 'test/mcp/fixtures/$_fixtureName',
        entrypointArguments: [link.directory.path]);
    await current.start();
    final inventory = await current.inventory();
    expect(inventory.containsKey('error'), isFalse);
    expect(inventory['result']['data'].single['tools'], hasLength(7));
    return current;
  }

  Future<Map<String, dynamic>> call(String tool,
      [Map<String, dynamic> arguments = const {}]) async {
    final response = await client!.call(tool, arguments);
    expect(response.containsKey('error'), isFalse);
    final result = response['result'] as Map;
    final envelope =
        (result['structuredContent'] as Map).cast<String, dynamic>();
    expect(envelope.keys.toSet(), {'profileVersion', 'data', 'error'});
    expect(envelope['profileVersion'], 2);
    expect(jsonDecode(result['content'].single['text'] as String), envelope);
    // MCP defaults an omitted isError to false; Codex omits it on success.
    expect(result['isError'] ?? false, envelope['error'] != null);
    return envelope;
  }

  Future<String> openContext() async {
    final targets = await call('open_generation_context');
    expect(targets['error'], isNull);
    final opened = await call('open_generation_context',
        {'targetRef': targets['data']['items'].single['targetRef']});
    expect(opened['error'], isNull);
    return opened['data']['contextRef'] as String;
  }

  Future<Map<String, dynamic>> lifecycle(String key) =>
      call('get_question_proposal', {'submissionKey': key});

  for (final reject in [false, true]) {
    testWidgets(
        'installed Codex: durable STAGE, duplicate/conflict, local UI '
        '${reject ? 'rejects' : 'approves'} and original-key lifecycle',
        (tester) async {
      final id = (await tester.runAsync(() async {
        await connect();
        final ref = await openContext();
        final before = await h.app.h.s.h.count('questions');
        final staged =
            await call('propose_generated_questions', batch(ref, 'codex-ui'));
        expect(staged['error'], isNull);
        expect(staged['data']['publication'], 'STAGED');
        expect(staged['data']['formalCommit'], 'NOT_REPORTED');
        expect(
            await call('propose_generated_questions', batch(ref, 'codex-ui')),
            staged);
        expect(
            (await call('propose_generated_questions',
                batch(ref, 'codex-ui', suffix: ' conflict')))['error'],
            isNotNull);
        expect(await h.app.h.s.h.count('generated_question_proposals'), 1);
        expect(await h.app.h.s.h.count('questions'), before);
        expect((await lifecycle('codex-ui'))['data'], {
          'submissionKey': 'codex-ui',
          'lifecycleStatus': 'pending_review',
          'requestedCount': 3,
          'actualCount': 3,
          'committedCount': 0,
          'rejectedCount': 0
        });
        final inbox = GeneratedProposalInboxController(h.app.h.s.localFactory);
        try {
          await inbox.load();
          expect(inbox.lastError, isNull);
          expect(inbox.proposals.single.lifecycleStatus,
              GeneratedStatus.pendingReview);
          expect(inbox.proposals.single.items.length, 3);
        } finally {
          inbox.dispose();
        }
        // Exercise authorized READ through the same actual client as well.
        final search = await call(
            'search_questions', {'contextRef': ref, 'query': 'needle'});
        expect(
            (await call('get_question_detail', {
              'contextRef': ref,
              'questionRef': search['data']['items'].single['questionRef']
            }))['error'],
            isNull);
        return staged['data']['proposalId'] as String;
      }))!;
      await tester.runAsync(() async {
        await tester.pumpWidget(MaterialApp(
            home: GeneratedProposalReviewScreen(
                proposalId: id,
                dependencies: GeneratedQuestionDependenciesScope(
                    authority: h.app.h.s.localFactory,
                    service: h.app.h.s.h.service,
                    child: const SizedBox()))));
      });
      await settleGenerated(tester);
      expect(find.textContaining('Select one'), findsWidgets);
      final proposal =
          (await tester.runAsync(() => h.app.h.s.localSession.read(id)))!;
      for (final item in proposal.items) {
        final finder = find.byKey(ValueKey(
            'generated-${reject ? 'rejected' : 'accepted'}-${item.itemId}'));
        await tester.scrollUntilVisible(finder, 250,
            scrollable: find.byType(Scrollable).first);
        await tapGenerated(tester, finder);
      }
      await tapGenerated(tester, find.byKey(const ValueKey('generated-save')));
      await tapGenerated(
          tester, find.byKey(const ValueKey('generated-confirm')));
      await tapGenerated(
          tester,
          find.byKey(ValueKey(
              reject ? 'generated-reject-proposal' : 'generated-approve')));
      expect(await tester.runAsync(() => h.app.h.s.h.count('questions')), 2);
      await tapGenerated(
          tester, find.byKey(const ValueKey('generated-confirm')));
      if (!reject) {
        expect(find.byKey(const ValueKey('generated-receipt')), findsOneWidget);
      }
      await tester.pumpWidget(const SizedBox());
      await tester.runAsync(() async {
        expect(await h.app.h.s.h.count('questions'), reject ? 2 : 5);
        expect(await h.app.h.s.h.count('generated_question_commit_receipts'),
            reject ? 0 : 1);
        final terminal = await lifecycle('codex-ui');
        expect(terminal['data'], {
          'submissionKey': 'codex-ui',
          'lifecycleStatus': reject ? 'rejected' : 'committed',
          'requestedCount': 3,
          'actualCount': 3,
          'committedCount': reject ? 0 : 3,
          'rejectedCount': reject ? 3 : 0
        });
        await disconnect();
        await h.restart(); // Real SQLite close/reopen and fresh authentication.
        await connect();
        expect(await lifecycle('codex-ui'), terminal);
        expect(await h.app.h.s.h.count('generated_question_proposals'), 1);
      });
    }, skip: skip != false, timeout: const Timeout(Duration(minutes: 2)));
  }

  test(
      'installed Codex: denied authority, stale Context and unavailable App fail closed',
      () async {
    await connect();
    final ref = await openContext();
    final s = h.app.h.s;
    h.auth.session = null;
    expect(
        (await call(
            'propose_generated_questions', batch(ref, 'no-auth')))['error'],
        'unauthenticated');
    h.auth.session =
        s.trust.openSession(s.trust.authenticate(s.credentials.authentication));
    expect(
        (await call('propose_generated_questions',
            batch(ref, 'other-session')))['error'],
        isNotNull);
    h.auth.session = s.session;
    final approved = h.composition;
    h.composition = VnextMcpAppComposition(
        host: h.app.host,
        reads: h.app.h.read,
        stages: s.service,
        authentication: h.auth,
        approvedTargets: []);
    expect(
        (await call(
            'propose_generated_questions', batch(ref, 'no-approval')))['error'],
        isNotNull);
    h.composition = approved;
    final invalid = batch(ref, 'invalid');
    (invalid['submission']['items'] as List).first['unexpected'] = true;
    expect((await call('propose_generated_questions', invalid))['error'],
        isNotNull);
    s.clock.current = s.clock.current.add(const Duration(minutes: 16));
    expect(
        (await call(
            'propose_generated_questions', batch(ref, 'expired')))['error'],
        isNotNull);
    await s.management.replaceGrant(
        s.profile, 2, s.policy(permissions: [CapabilityPermission.read]));
    final readOnly = await openContext();
    expect(
        (await call('propose_generated_questions',
            batch(readOnly, 'no-stage')))['error'],
        isNotNull);
    await s.management.revokeGrant(s.profile, 3);
    expect((await lifecycle('no-stage'))['error'], isNotNull);
    await h.composition.close();
    expect((await call('open_generation_context'))['error'], 'unavailable');
    expect(await s.h.count('generated_question_proposals'), 0);
    expect(await s.h.count('questions'), 2);
  }, skip: skip, timeout: const Timeout(Duration(minutes: 2)));

  test(
      'installed Codex: physically lost STAGE reply, disconnect, DB reopen and original-key recovery',
      () async {
    await connect();
    final ref = await openContext();
    link.dropStageResponse = true;
    // Attach both branches before closing the protocol with a pending request.
    final reply = client!
        .call('propose_generated_questions', batch(ref, 'lost'))
        .then<Object?>((value) => value, onError: (Object _) => null);
    await link.dropped.future.timeout(const Duration(seconds: 15));
    expect(await h.app.h.s.h.count('generated_question_proposals'), 1);
    expect(await h.app.h.s.h.count('questions'), 2);
    await disconnect();
    final lost = await reply;
    if (lost is Map && lost['result'] != null) {
      expect(lost['result']['isError'], isTrue);
    }
    await h.restart();
    await connect();
    expect(
        (await lifecycle('lost'))['data']['lifecycleStatus'], 'pending_review');
    expect(link.stageCalls, 1,
        reason: 'Recovery queries the key; never restage.');
    expect(await h.app.h.s.h.count('generated_question_proposals'), 1);
    expect(await h.app.h.s.h.count('questions'), 2);
  }, skip: skip, timeout: const Timeout(Duration(minutes: 2)));
}
