import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:shiroha_quiz/application/capabilities/capability.dart';
import 'package:shiroha_quiz/application/external/external_authorization.dart';
import 'package:shiroha_quiz/application/external/external_read_context.dart';
import 'package:shiroha_quiz/application/external/external_runtime_admission.dart';
import 'package:shiroha_quiz/application/external/external_trust_core.dart';
import 'package:shiroha_quiz/data/repositories/external_target_read_repository.dart';
import 'package:shiroha_quiz/domain/generated_question/generated_question_contract.dart';
import 'durable_stage_test_support.dart';

Matcher readFailure(ExternalReadFailure code) =>
    throwsA(isA<ExternalReadException>()
        .having((e) => e.failure, 'safe category', code));

final class _MultiCredentials implements ExternalCredentialPort {
  final first = Object(), second = Object();
  String? identity(Object key) => identical(key, first)
      ? 'first'
      : identical(key, second)
          ? 'second'
          : null;
  @override
  AuthenticatedPeerEvidence? authenticate(Object attempt) {
    final id = identity(attempt);
    return id == null ? null : AuthenticatedPeerEvidence(id);
  }

  @override
  PairingProof? provePossession(Object attempt) {
    final id = identity(attempt);
    return id == null ? null : PairingProof(id, id);
  }
}

/// Barrier around the real SQLite adapter; no sleeps or mocked authorization.
final class _Barrier implements ExternalTargetReadPort {
  _Barrier(this.inner);
  final ExternalTargetReadPort inner;
  final entered = Completer<void>(), resume = Completer<void>();
  int calls = 0;
  Future<void> Function(int)? after;
  bool pause = false;
  @override
  Future<ExternalReadSnapshot> query(ExternalRuntimeAccess access,
      int? revision, void Function() check) async {
    calls++;
    if (pause) {
      if (!entered.isCompleted) entered.complete();
      await resume.future;
    }
    final result = await inner.query(access, revision, check);
    await after?.call(calls);
    return result;
  }
}

void main() {
  initializeGeneratedTests();
  late DurableStageHarness s;
  late ExternalReadContextService read;
  late _Barrier port;
  setUp(() async {
    s = DurableStageHarness();
    await s.open();
    await s.management.replaceGrant(
        s.profile,
        1,
        s.policy(permissions: [
          CapabilityPermission.read,
          CapabilityPermission.stage
        ]));
    port = _Barrier(
        SqliteExternalTargetReadRepository(databaseHelper: s.h.helper));
    read = ExternalReadContextService(
        admission: s.service.runtimeAdmission, targets: port);
  });
  tearDown(() async {
    read.close();
    if (port.pause && !port.resume.isCompleted) port.resume.complete();
    await read.whenIdle;
    await s.close();
  });
  Future<String> context() async => read.createContext(
      session: s.session,
      targetRef:
          (await read.listTargets(session: s.session)).items.single.targetRef);
  Future<void> grant(ExternalGrantPolicy policy) async {
    final revision = (await s.management.read(s.profile)).profile.grantRevision;
    await s.management.replaceGrant(s.profile, revision, policy);
  }

  Future<ExternalSession> foreign({String? profileId}) async {
    final trust = ExternalTrustCore(
        credentials: s.credentials,
        clock: s.clock,
        mintProfileId: () => profileId ?? s.profile.profileId);
    final principal = trust.createProfile();
    trust.requestPairing(principal,
        requestId: 'synthetic-pairing',
        credentialIdentity: 'synthetic-credential');
    trust.approvePairing(principal);
    trust.completePairing(principal, s.credentials.proof);
    trust.enable(principal, const Duration(minutes: 30));
    return trust.openSession(trust.authenticate(s.credentials.authentication));
  }

  test('T1/T3 credential proof and runtime enablement precede READ admission',
      () async {
    expect(
        () => s.trust
            .authenticate({'trusted': true, 'profileId': s.profile.profileId}),
        throwsA(isA<ExternalCoreException>()));
    s.trust.disable(s.principal);
    await expectLater(read.listTargets(session: s.session),
        readFailure(ExternalReadFailure.denied));
    final peer = s.trust.authenticate(s.credentials.authentication);
    expect(
        () => s.trust.openSession(peer), throwsA(isA<ExternalCoreException>()));
    s.trust.enable(s.principal, const Duration(minutes: 30));
    s.session = s.trust.openSession(peer);
    expect(await context(), hasLength(43));
  });

  test(
      'T2/T13 another TrustCore with the same durable id cannot copy any handle',
      () async {
    final token = await context();
    final session = await foreign();
    expect(await read.contextStatus(session: session, context: token),
        ExternalReadValidity.invalid);
    await expectLater(read.listTargets(session: session),
        readFailure(ExternalReadFailure.denied));
    await expectLater(read.createContext(session: s.session, targetRef: token),
        readFailure(ExternalReadFailure.denied));
    for (final fake in [
      s.profile.profileId,
      '2',
      'questionContent',
      'proposalMetadata',
      'A' * 43
    ]) {
      await expectLater(read.createContext(session: s.session, targetRef: fake),
          readFailure(ExternalReadFailure.denied));
    }
  });

  test(
      'T2 other authenticated Profile cannot use target/context/cursor references',
      () async {
    final ref =
        (await read.listTargets(session: s.session)).items.single.targetRef;
    final token = await read.createContext(session: s.session, targetRef: ref);
    final other = await s.management.createProfile(
        displayName: 'Other', adapter: 'bridge', protocol: 'tcp-v1');
    await s.management.replaceGrant(
        other, 0, s.policy(permissions: [CapabilityPermission.read]));
    final authenticated = await foreign(profileId: other.profileId);
    expect(await read.contextStatus(session: authenticated, context: token),
        ExternalReadValidity.invalid);
    await expectLater(
        read.createContext(session: authenticated, targetRef: ref),
        readFailure(ExternalReadFailure.denied));
  });

  test(
      'T2/T7 same TrustCore independently admitted Profiles isolate handles and capacity',
      () async {
    final second = await s.management.createProfile(
        displayName: 'Second', adapter: 'bridge', protocol: 'tcp-v1');
    await s.management.replaceGrant(
        second, 0, s.policy(permissions: [CapabilityPermission.read]));
    final credentials = _MultiCredentials();
    var nextId = s.profile.profileId;
    final trust = ExternalTrustCore(
        credentials: credentials, clock: s.clock, mintProfileId: () => nextId);
    final admission = ExternalRuntimeAdmission(
        trust: trust,
        management: s.management,
        compositionIsCurrent: () => true);
    final service = ExternalReadContextService(
        admission: admission,
        targets: port,
        maxHandlesPerProfile: 3,
        maxContextsPerProfile: 1);
    Future<ExternalSession> authenticate(
        ExternalProfileReference ref, Object key) async {
      nextId = ref.profileId;
      final principal = trust.createProfile();
      await admission.bindIdentity(ref, principal);
      final id = credentials.identity(key)!;
      trust.requestPairing(principal, requestId: id, credentialIdentity: id);
      trust.approvePairing(principal);
      trust.completePairing(principal, key);
      trust.enable(principal, const Duration(minutes: 30));
      return trust.openSession(trust.authenticate(key));
    }

    try {
      final firstSession = await authenticate(s.profile, credentials.first);
      final secondSession = await authenticate(second, credentials.second);
      final ref = (await service.listTargets(session: firstSession))
          .items
          .single
          .targetRef;
      final token =
          await service.createContext(session: firstSession, targetRef: ref);
      expect(
          await service.contextStatus(session: secondSession, context: token),
          ExternalReadValidity.invalid);
      await expectLater(
          service.createContext(session: secondSession, targetRef: ref),
          readFailure(ExternalReadFailure.denied));
      await service.listTargets(session: firstSession);
      await expectLater(service.listTargets(session: firstSession),
          readFailure(ExternalReadFailure.resourceLimit));
      final secondRef = (await service.listTargets(session: secondSession))
          .items
          .single
          .targetRef;
      expect(
          await service.createContext(
              session: secondSession, targetRef: secondRef),
          hasLength(43));
      await expectLater(
          service.createContext(session: secondSession, targetRef: secondRef),
          readFailure(ExternalReadFailure.resourceLimit));
    } finally {
      service.close();
      admission.close();
    }
  });

  test('T4 only STAGE and proposalMetadata never imply Target READ', () async {
    await grant(s.policy());
    await expectLater(read.listTargets(session: s.session),
        readFailure(ExternalReadFailure.denied));
    final staged = await s.stage();
    expect(staged.output, isNotNull);
    expect((await s.reconcile('external-key')).output!.proposalId,
        staged.output!.proposalId);
    await grant(s.policy(
        permissions: [CapabilityPermission.read],
        categories: [ExternalContentCategory.proposalMetadata]));
    await expectLater(read.listTargets(session: s.session),
        readFailure(ExternalReadFailure.denied));
  });

  test('T4 READ-only Context cannot grant STAGE or formal mutation', () async {
    await grant(s.policy(
        permissions: [CapabilityPermission.read],
        categories: [ExternalContentCategory.questionContent]));
    final token = await context();
    expect(await read.contextStatus(session: s.session, context: token),
        ExternalReadValidity.authorized);
    await expectLater(s.context(), failure(GeneratedFailure.unauthorized));
    expect(await s.h.count('generated_question_proposals'), 0);
    expect(await s.h.count('questions'), 0);
    expect(await s.h.count('review_states'), 0);
  });

  test(
      'T5/T6 real SQLite exact Scope excludes unrelated banks/projects/files and fields',
      () async {
    await s.h.db.insert('bank_folders',
        {'bank_name': 'private-bank', 'folder_name': 'private-folder'});
    await s.h.db.insert('projects', {
      'project_id': 'allowed-project',
      'display_name': 'Synthetic',
      'created_at': 1
    });
    for (final bank in ['bank', 'private-bank']) {
      await s.h.db.insert('project_banks',
          {'project_id': 'allowed-project', 'bank_name': bank});
    }
    final scoped = ExternalGrantScope(
        kind: ExternalTargetKind.bank,
        targetId: 'bank',
        projectId: 'allowed-project');
    await grant(
        s.policy(permissions: [CapabilityPermission.read], scopes: [scoped]));
    final page = await read.listTargets(session: s.session);
    expect(page.items, hasLength(1));
    expect(page.items.single.toJson().keys.toSet(),
        {'targetRef', 'bankName', 'projectId', 'folderName'});
    expect(page.items.single.projectId, 'allowed-project');
    final wire = jsonEncode(page.toJson());
    for (final forbidden in [
      'private-bank',
      'private-folder',
      'projectBankNames',
      'grantRevision',
      'principal',
      'session',
      'count'
    ]) {
      expect(wire, isNot(contains(forbidden)));
    }
    for (final id in ['private-bank', 'missing-bank']) {
      await expectLater(read.createContext(session: s.session, targetRef: id),
          readFailure(ExternalReadFailure.denied));
    }
    await grant(s.policy(permissions: [CapabilityPermission.read], scopes: []));
    expect((await read.listTargets(session: s.session)).items, isEmpty);
  });

  test('T7 stable default/max paging and cursor revision/target binding',
      () async {
    final scopes = <ExternalGrantScope>[];
    for (var i = 0; i < 55; i++) {
      final bank = 'b${i.toString().padLeft(2, '0')}';
      await s.h.db
          .insert('bank_folders', {'bank_name': bank, 'folder_name': 'folder'});
      scopes.add(
          ExternalGrantScope(kind: ExternalTargetKind.bank, targetId: bank));
    }
    await grant(s.policy(
        permissions: [CapabilityPermission.read], scopes: scopes.reversed));
    final first = await read.listTargets(session: s.session);
    expect(first.items, hasLength(20));
    expect(first.items.first.bankName, 'b00');
    final second = await read.listTargets(
        session: s.session, cursor: first.nextCursor, pageSize: 50);
    expect(second.items, hasLength(35));
    expect(second.items.first.bankName, 'b20');
    expect(second.nextCursor, isNull);
    for (final size in [0, 51]) {
      await expectLater(read.listTargets(session: s.session, pageSize: size),
          readFailure(ExternalReadFailure.resourceLimit));
    }
    await s.h.db
        .delete('bank_folders', where: 'bank_name=?', whereArgs: ['b54']);
    await expectLater(
        read.listTargets(session: s.session, cursor: first.nextCursor),
        readFailure(ExternalReadFailure.stale));
    final beforeNarrow =
        await read.listTargets(session: s.session, pageSize: 1);
    await grant(s.policy(
        permissions: [CapabilityPermission.read], scopes: scopes.take(2)));
    await expectLater(
        read.listTargets(session: s.session, cursor: beforeNarrow.nextCursor),
        readFailure(ExternalReadFailure.stale));
  });

  test(
      'T7 response size and Handle/context/per-Profile capacity fail without leaking allocations',
      () async {
    read.close();
    read = ExternalReadContextService(
        admission: s.service.runtimeAdmission,
        targets: port,
        maxResponseBytes: 32);
    await expectLater(read.listTargets(session: s.session),
        readFailure(ExternalReadFailure.resourceLimit));
    expect(read.activeHandleCount, 0);
    read.close();
    read = ExternalReadContextService(
        admission: s.service.runtimeAdmission,
        targets: port,
        maxActiveHandles: 3,
        maxHandlesPerProfile: 3,
        maxContexts: 1,
        maxContextsPerProfile: 1);
    final ref =
        (await read.listTargets(session: s.session)).items.single.targetRef;
    await read.createContext(session: s.session, targetRef: ref);
    await expectLater(read.createContext(session: s.session, targetRef: ref),
        readFailure(ExternalReadFailure.resourceLimit));
    await read.listTargets(session: s.session);
    await expectLater(read.listTargets(session: s.session),
        readFailure(ExternalReadFailure.resourceLimit));
    expect(read.activeHandleCount, 3);
    s.clock.current = s.clock.current.add(const Duration(minutes: 15));
    read.sweep();
    expect(read.activeHandleCount, 0);
  });

  test(
      'T7 all 128 explicit scopes can be traversed within default reference capacity',
      () async {
    final scopes = <ExternalGrantScope>[];
    for (var i = 0; i < 128; i++) {
      final bank = 'bounded-${i.toString().padLeft(3, '0')}';
      await s.h.db
          .insert('bank_folders', {'bank_name': bank, 'folder_name': 'folder'});
      scopes.add(
          ExternalGrantScope(kind: ExternalTargetKind.bank, targetId: bank));
    }
    await grant(
        s.policy(permissions: [CapabilityPermission.read], scopes: scopes));
    final names = <String>[];
    String? cursor;
    do {
      final page = await read.listTargets(session: s.session, cursor: cursor);
      expect(page.items.length, lessThanOrEqualTo(20));
      names.addAll(page.items.map((i) => i.bankName));
      cursor = page.nextCursor;
    } while (cursor != null);
    expect(names, scopes.map((s) => s.targetId).toList());
    expect(read.activeHandleCount, 134);
  });

  for (final mode in [
    'revision',
    'narrow',
    'expand',
    'grant-revoke',
    'profile-revoke'
  ]) {
    test(
        'T8/T9/T12 $mode invalidates old snapshot; new Context uses only current policy',
        () async {
      final token = await context();
      final ref =
          (await read.listTargets(session: s.session)).items.single.targetRef;
      if (mode == 'grant-revoke') {
        await s.management.revokeGrant(s.profile, 2);
      } else if (mode == 'profile-revoke') {
        await s.management.revokeProfile(s.profile, 2);
      } else {
        final scopes = <ExternalGrantScope>[if (mode != 'narrow') s.bank];
        if (mode == 'expand') {
          await s.h.db.insert('bank_folders',
              {'bank_name': 'new-bank', 'folder_name': 'new-folder'});
          scopes.add(ExternalGrantScope(
              kind: ExternalTargetKind.bank, targetId: 'new-bank'));
        }
        await grant(
            s.policy(permissions: [CapabilityPermission.read], scopes: scopes));
      }
      expect(await read.contextStatus(session: s.session, context: token),
          ExternalReadValidity.invalid);
      await expectLater(read.createContext(session: s.session, targetRef: ref),
          throwsA(isA<ExternalReadException>()));
      if (mode == 'revision' || mode == 'expand') {
        final page = await read.listTargets(session: s.session);
        final fresh = await read.createContext(
            session: s.session, targetRef: page.items.first.targetRef);
        expect(await read.contextStatus(session: s.session, context: fresh),
            ExternalReadValidity.authorized);
      } else if (mode == 'narrow') {
        expect((await read.listTargets(session: s.session)).items, isEmpty);
      }
    });
  }

  for (final mode in ['folder', 'project', 'target-delete']) {
    test(
        'T9 current SQLite $mode drift invalidates target selection and Context',
        () async {
      if (mode == 'project') {
        await s.h.db.insert('projects',
            {'project_id': 'p', 'display_name': 'Synthetic', 'created_at': 1});
        await s.h.db
            .insert('project_banks', {'project_id': 'p', 'bank_name': 'bank'});
        await grant(s.policy(permissions: [
          CapabilityPermission.read
        ], scopes: [
          ExternalGrantScope(
              kind: ExternalTargetKind.bank, targetId: 'bank', projectId: 'p')
        ]));
      }
      final ref =
          (await read.listTargets(session: s.session)).items.single.targetRef;
      final token =
          await read.createContext(session: s.session, targetRef: ref);
      if (mode == 'folder') {
        await s.h.db.update('bank_folders', {'folder_name': 'changed'});
      } else if (mode == 'project') {
        await s.h.db
            .delete('project_banks', where: 'project_id=?', whereArgs: ['p']);
      } else {
        await s.h.db.delete('bank_folders');
      }
      expect(await read.contextStatus(session: s.session, context: token),
          ExternalReadValidity.invalid);
      await expectLater(read.createContext(session: s.session, targetRef: ref),
          readFailure(ExternalReadFailure.stale));
    });
  }

  for (final mode in ['expiry', 'disable', 'restart', 'restore', 'close']) {
    test('T10/T11 $mode invalidates handles without automatic renewal',
        () async {
      final token = await context();
      if (mode == 'expiry') {
        s.clock.current = s.clock.current.add(const Duration(minutes: 15));
      } else if (mode == 'disable') {
        s.trust.disable(s.principal);
      } else if (mode == 'restart') {
        s.trust.restart();
      } else if (mode == 'restore') {
        s.trust.restore();
      } else {
        s.service.close();
      }
      read.sweep();
      expect(read.activeHandleCount, 0);
      expect(await read.contextStatus(session: s.session, context: token),
          ExternalReadValidity.invalid);
      if (mode == 'expiry') {
        final fresh = await context();
        expect(fresh, isNot(token));
        expect(await read.contextStatus(session: s.session, context: fresh),
            ExternalReadValidity.authorized);
      }
    });
  }

  test(
      'T11 actual database close/reopen and new App registry reject original handles',
      () async {
    final token = await context();
    final oldSession = s.session;
    await s.reopen();
    read.close();
    read = ExternalReadContextService(
        admission: s.service.runtimeAdmission,
        targets:
            SqliteExternalTargetReadRepository(databaseHelper: s.h.helper));
    expect(await read.contextStatus(session: s.session, context: token),
        ExternalReadValidity.invalid);
    expect(await read.contextStatus(session: oldSession, context: token),
        ExternalReadValidity.invalid);
    expect(await context(), hasLength(43));
  });

  test(
      'T8 release recheck suppresses data after durable revoke between query and release',
      () async {
    port.after = (call) async {
      if (call == 1) await s.management.revokeGrant(s.profile, 2);
    };
    await expectLater(read.listTargets(session: s.session),
        readFailure(ExternalReadFailure.denied));
    expect(read.activeHandleCount, 0);
  });

  test(
      'T7 cancellation retains pending capacity until SQLite operation settles',
      () async {
    read.close();
    read = ExternalReadContextService(
        admission: s.service.runtimeAdmission, targets: port, maxInFlight: 1);
    port.pause = true;
    final control = s.control();
    final pending = read.listTargets(session: s.session, control: control);
    await port.entered.future;
    control.cancel();
    await expectLater(pending, readFailure(ExternalReadFailure.cancelled));
    expect(read.pendingCount, 1);
    await expectLater(read.listTargets(session: s.session),
        readFailure(ExternalReadFailure.resourceLimit));
    port.resume.complete();
    await read.whenIdle;
    expect(read.pendingCount, 0);
    expect(read.activeHandleCount, 0);
  });

  test(
      'T7 trusted query deadline bounds pending work and prevents late release',
      () async {
    port.pause = true;
    final control = s.control();
    final pending = read.listTargets(session: s.session, control: control);
    await port.entered.future;
    s.clock.current = s.clock.current.add(const Duration(seconds: 2));
    port.resume.complete();
    await expectLater(
        pending, readFailure(ExternalReadFailure.deadlineExceeded));
    await read.whenIdle;
    expect(read.activeHandleCount, 0);
  });

  test(
      'T7 wall timer returns deadline while blocked work still retains its slot',
      () async {
    read.close();
    read = ExternalReadContextService(
        admission: s.service.runtimeAdmission,
        targets: port,
        maxInFlightPerProfile: 1,
        maxQueryDuration: const Duration(milliseconds: 500));
    port.pause = true;
    final pending = read.listTargets(session: s.session);
    await port.entered.future;
    await expectLater(
        pending, readFailure(ExternalReadFailure.deadlineExceeded));
    expect(read.pendingCount, 1);
    await expectLater(read.listTargets(session: s.session),
        readFailure(ExternalReadFailure.resourceLimit));
    port.resume.complete();
    await read.whenIdle;
    expect(read.activeHandleCount, 0);
  });

  test(
      'T15 external READ stays inside Application/Data and never wires a Host or writer',
      () {
    for (final path in [
      'lib/application/external/external_runtime_admission.dart',
      'lib/application/external/external_read_context.dart',
    ]) {
      final source = File(path).readAsStringSync();
      final imports = RegExp(r'''(?:import|export)\s+['"]([^'"]+)['"]''')
          .allMatches(source)
          .map((m) => m[1]!)
          .toList();
      for (final forbidden in [
        'dart:io',
        'sqflite',
        'database_helper',
        '/data/',
        'flutter',
        'mcp_dart'
      ]) {
        expect(imports.any((i) => i.contains(forbidden)), isFalse,
            reason: path);
      }
      expect(source, isNot(contains('mcpStudyV0')));
    }
    final data =
        File('lib/data/repositories/external_target_read_repository.dart')
            .readAsStringSync();
    for (final write in ['.insert(', '.update(', '.delete(', '.execute(']) {
      expect(data, isNot(contains(write)));
    }
    final trust = File('lib/application/external/external_trust_core.dart')
        .readAsStringSync();
    expect(trust, isNot(contains('external_read_context')));
    for (final path in ['lib/main.dart', 'lib/mcp/study_mcp_server.dart']) {
      expect(File(path).readAsStringSync(),
          isNot(contains('ExternalReadContextService')));
    }
  });

  test(
      'T11/T13 a real isolated Dart process with same Profile/revision cannot reuse handle',
      () async {
    final token = await context();
    final parts = File(Platform.resolvedExecutable)
        .resolveSymbolicLinksSync()
        .split(Platform.pathSeparator);
    final cache = parts.lastIndexOf('cache');
    final dart = [
      ...parts.take(cache + 1),
      'dart-sdk',
      'bin',
      Platform.isWindows ? 'dart.exe' : 'dart'
    ].join(Platform.pathSeparator);
    expect(File(dart).existsSync(), isTrue);
    final child = await Process.start(
        dart,
        [
          '--packages=.dart_tool/package_config.json',
          'test/application/external/external_read_process_probe.dart'
        ],
        workingDirectory: Directory.current.path);
    final output = child.stdout.transform(utf8.decoder).join();
    final errors = child.stderr.transform(utf8.decoder).join();
    child.stdin.writeln(
        jsonEncode({'profileId': s.profile.profileId, 'context': token}));
    await child.stdin.close();
    try {
      expect(await child.exitCode.timeout(const Duration(seconds: 45)), 0);
      expect(await output, 'invalid\n');
      expect(await errors, isEmpty);
    } finally {
      child.kill();
    }
  });
}
