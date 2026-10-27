import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:path/path.dart' as p;
import 'package:flutter_test/flutter_test.dart';
import 'package:shiroha_quiz/application/capabilities/capability.dart';
import 'package:shiroha_quiz/application/external/external_trust_core.dart';
import 'package:shiroha_quiz/application/external/external_authorization.dart';
import 'package:shiroha_quiz/application/external/external_file_read.dart';
import 'package:shiroha_quiz/application/external/external_read_context.dart';
import 'package:shiroha_quiz/application/external/external_runtime_admission.dart';
import 'external_file_read_test_support.dart';

Matcher fileFailure(ExternalReadFailure failure) =>
    throwsA(isA<ExternalFileReadException>()
        .having((e) => e.failure, 'safe failure', failure));

final class _TwoCredentials implements ExternalCredentialPort {
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

void main() {
  initializeGeneratedTests();
  late FileReadHarness h;
  setUp(() async {
    h = FileReadHarness();
    await h.open();
  });
  tearDown(() => h.close());

  test(
      'all-content file discovery pages beyond 64, skips unparsed pages, and binds cursors to their context',
      () async {
    await h.s.management.replaceGrant(
        h.s.profile,
        h.revision,
        ExternalGrantPolicy(
            permissions: [
              CapabilityPermission.read,
              CapabilityPermission.stage
            ],
            scopes: [],
            categories: ExternalContentCategory.values,
            allContent: true,
            generationMode: ExternalGenerationMode.review));
    h.revision++;
    for (var i = 0; i < 65; i++) {
      await h.seed('added-${i.toString().padLeft(3, '0')}');
    }
    for (var i = 0; i < 20; i++) {
      await h.seed('aaa-${i.toString().padLeft(3, '0')}', parsed: false);
    }
    final target = (await h.read.listTargets(session: h.s.session))
        .items
        .firstWhere((t) => t.projectId == h.project);
    final context = await h.read
        .createContext(session: h.s.session, targetRef: target.targetRef);
    final first =
        await h.read.listFileSelections(session: h.s.session, context: context);
    expect(first.items, isEmpty);
    expect(first.unsupportedExcluded, isTrue);
    expect(first.nextCursor, isNotNull);
    final other = await h.read
        .createContext(session: h.s.session, targetRef: target.targetRef);
    await expectLater(
        h.read.listFileSelections(
            session: h.s.session, context: other, cursor: first.nextCursor),
        throwsA(isA<ExternalReadException>()));
    var cursor = first.nextCursor;
    var total = 0;
    do {
      final page = await h.read.listFileSelections(
          session: h.s.session, context: context, cursor: cursor);
      expect(page.items.length, lessThanOrEqualTo(20));
      total += page.items.length;
      cursor = page.nextCursor;
      if (cursor == null) {
        final selected = await h.read.createFileContext(
            session: h.s.session,
            context: context,
            fileRefs: [page.items.last['fileRef'] as String]);
        expect((await h.search(selected)).items, isNotEmpty);
      }
    } while (cursor != null);
    expect(total, 67);
    expect(h.generation.calls, 67);
    await h.grant();
    await expectLater(
        h.read.listFileSelections(
            session: h.s.session, context: context, cursor: first.nextCursor),
        throwsA(isA<ExternalReadException>()));
  });

  test('T1 authenticated Principal and enabled Runtime are mandatory',
      () async {
    final context = await h.approved();
    h.s.trust.disable(h.s.principal);
    await expectLater(
        h.search(context), fileFailure(ExternalReadFailure.denied));
    expect(await h.s.h.count('retrieval_index_builds'), 0);
    expect(() => h.s.trust.authenticate(Object()), throwsA(anything));
  });

  test('T2 READ without fileContent denies selection before protected loading',
      () async {
    await h.grant(categories: [ExternalContentCategory.questionContent]);
    final context = await h.context();
    await expectLater(
        h.read.listFileSelections(session: h.s.session, context: context),
        throwsA(isA<ExternalReadException>()
            .having((e) => e.failure, 'failure', ExternalReadFailure.denied)));
    expect(h.generation.calls, 2);
    expect(h.observed.reads, 0);
    expect(await h.s.h.count('retrieval_index_builds'), 0);
  });

  test('T3 T4 real fileContent Grant with only Bank scope grants no files',
      () async {
    await h.grant(scopes: [h.bank]);
    final context = await h.context();
    await expectLater(
        h.read.listFileSelections(session: h.s.session, context: context),
        throwsA(isA<ExternalReadException>()));
    await expectLater(
        h.search(context), fileFailure(ExternalReadFailure.denied));
    expect(await h.s.h.count('retrieval_index_builds'), 0);
  });

  test(
      'T5 T6 T8 T9 explicit selection narrows exact Grant, F1 and real FTS scope',
      () async {
    final empty = await h.context();
    final approved = await h.approved(parent: empty);
    await expectLater(h.search(empty), fileFailure(ExternalReadFailure.denied));
    final page = await h.search(approved);
    expect(h.index.searched, ['file-a']);
    expect(page.items, hasLength(1));
    expect(page.items.single['content'], 'needle file-a');
    final artifact = (await h.metadata.findCurrentByFileId('file-a'))!;
    final build = (await h.s.h.db.query('retrieval_index_builds')).single;
    expect(build['file_id'], 'file-a');
    expect(build['artifact_id'], artifact.artifactId);
    expect(build['revision'], artifact.revision);
    expect(build['payload_digest'], artifact.payloadSha256);
    expect(page.executionEvidence!.effectKnown, isTrue);
    expect(page.executionEvidence!.derivedCacheWritten, isTrue);
    final repeat = await h.search(approved);
    expect(repeat.executionEvidence!.effectKnown, isTrue);
    expect(repeat.executionEvidence!.derivedCacheWritten, isFalse);
    await h.grant(scopes: [h.bank, h.file('file-a')]);
    final current = await h.context();
    expect(
        (await h.read
                .listFileSelections(session: h.s.session, context: current))
            .items,
        hasLength(1));
  });

  test(
      'T7 File selections, Passage and cursor bind exact Context and Principal',
      () async {
    final a = await h.context();
    final b = await h.context();
    final choices =
        await h.read.listFileSelections(session: h.s.session, context: a);
    await expectLater(
        h.read.createFileContext(
            session: h.s.session,
            context: b,
            fileRefs: [choices.items.first['fileRef'] as String]),
        throwsA(isA<ExternalReadException>()));
    await expectLater(
        h.read.createFileContext(
            session: h.s.session, context: a, fileRefs: ['file-a']),
        throwsA(isA<ExternalReadException>()));
    final approved = await h.approved(parent: a);
    final ref = (await h.search(approved)).items.single['passageRef'] as String;
    await expectLater(
        h.passage(b, ref), fileFailure(ExternalReadFailure.denied));
    final first = await h.passage(approved, ref);
    final otherRef =
        (await h.search(approved)).items.single['passageRef'] as String;
    await expectLater(h.passage(approved, otherRef, cursor: first.nextCursor),
        fileFailure(ExternalReadFailure.denied));
    // Another real authenticated Profile with equally explicit scopes still
    // cannot reuse the original Principal's references.
    h.s.profile = await h.s.management.createProfile(
        displayName: 'Other', adapter: 'bridge', protocol: 'tcp-v1');
    await h.s.management.replaceGrant(
        h.s.profile,
        0,
        h.s.policy(
            permissions: [CapabilityPermission.read],
            scopes: [h.bank, h.file('file-a')],
            categories: ExternalContentCategory.values));
    final foreignTrust = ExternalTrustCore(
        credentials: h.s.credentials,
        clock: h.s.clock,
        mintProfileId: () => h.s.profile.profileId);
    final foreign = foreignTrust.createProfile();
    foreignTrust.requestPairing(foreign,
        requestId: 'synthetic-pairing',
        credentialIdentity: 'synthetic-credential');
    foreignTrust.approvePairing(foreign);
    foreignTrust.completePairing(foreign, h.s.credentials.proof);
    foreignTrust.enable(foreign, const Duration(minutes: 30));
    final foreignSession = foreignTrust
        .openSession(foreignTrust.authenticate(h.s.credentials.authentication));
    await expectLater(
        h.read.retrieveFileContent(
            session: foreignSession, context: approved, query: 'needle'),
        fileFailure(ExternalReadFailure.denied));
  });

  test(
      'T10 T11 T12 whitelist, actual SourcePart order, continuation and exclusions',
      () async {
    final context = await h.approved();
    final hit = (await h.search(context)).items.single;
    expect(hit.keys.toSet(), {
      'passageRef',
      'content',
      'contentKind',
      'locator',
      'chunkOrdinal',
      'partOrdinal',
      'windowOrdinal',
      'pageNumber'
    });
    var page = await h.passage(context, hit['passageRef'] as String);
    expect(page.startsAtDocumentBeginning, isTrue);
    expect(page.items, hasLength(8));
    expect(page.hasMore, isTrue);
    expect(page.unsupportedExcluded, isTrue);
    final items = [...page.items];
    page = await h.passage(context, hit['passageRef'] as String,
        cursor: page.nextCursor);
    expect(page.startsAtDocumentBeginning, isFalse);
    expect(page.hasMore, isFalse);
    expect(page.nextCursor, isNull);
    items.addAll(page.items);
    expect(items.map((i) => i['chunkOrdinal']), List.generate(14, (i) => i));
    expect(items.map((i) => i['partOrdinal']), List.generate(14, (i) => i));
    expect(items[10]['content'], r'\[x^2\]');
    expect(items[12]['content'], 'r1c1: table value');
    expect(items[13]['content'], 'safe alt');
    final encoded = jsonEncode(items);
    for (final forbidden in [
      'artifactId',
      'fileId',
      'chunkId',
      'sourceRef',
      'storageKey',
      'never-release',
      'raw_fallback',
      'base64',
      'data:',
      h.managed.path
    ]) {
      expect(encoded, isNot(contains(forbidden)));
    }
    expect(utf8.encode(jsonEncode(page.toJson())).length,
        lessThanOrEqualTo(24000));
    expect(h.generation.calls, 2);
  });

  test(
      'T11 a mid-document search is never described as complete document reading',
      () async {
    final context = await h.approved();
    final ref = (await h.search(context, query: 'tail'))
        .items
        .single['passageRef'] as String;
    final page = await h.passage(context, ref);
    expect(page.startsAtDocumentBeginning, isFalse);
    expect(page.items.first['partOrdinal'], 11);
    expect(page.hasMore, isFalse);
  });

  test(
      'T13 missing Artifact returns sourceNotReady without parsing or index fallback',
      () async {
    await h.lifecycle
        .removeCurrentArtifact(fileId: 'file-a', expectedRevision: 1);
    final context = await h.context();
    await expectLater(
        h.read.listFileSelections(session: h.s.session, context: context),
        throwsA(isA<ExternalReadException>().having(
            (e) => e.failure, 'failure', ExternalReadFailure.sourceNotReady)));
    expect(h.generation.calls, 2);
    expect(await h.s.h.count('retrieval_index_builds'), 0);
  });

  test('T13 corrupt real F1 payload blocks even a warm old index', () async {
    final context = await h.approved();
    final ref = (await h.search(context)).items.single['passageRef'] as String;
    final artifact = (await h.metadata.findCurrentByFileId('file-a'))!;
    await File(p.join(h.managed.path, artifact.storageKey))
        .writeAsString('corrupt');
    await expectLater(
        h.search(context), fileFailure(ExternalReadFailure.dataCorrupt));
    await expectLater(
        h.passage(context, ref), fileFailure(ExternalReadFailure.dataCorrupt));
    expect(h.generation.calls, 2);
  });

  test(
      'T14 deterministic grant narrowing after real FTS generation suppresses release',
      () async {
    final context = await h.approved();
    h.index.afterSearch = () => h.grant(scopes: [h.bank, h.file('file-b')]);
    await expectLater(
        h.search(context), fileFailure(ExternalReadFailure.denied));
    expect(await h.s.h.count('retrieval_index_builds'), 1);
  });

  test('T14 revoke before query does not create cache or release body',
      () async {
    final context = await h.approved();
    final readsBeforeRevoke = h.observed.reads;
    await h.s.management.revokeGrant(h.s.profile, h.revision);
    await expectLater(
        h.search(context), fileFailure(ExternalReadFailure.denied));
    expect(await h.s.h.count('retrieval_index_builds'), 0);
    expect(h.index.searched, isEmpty);
    expect(h.observed.reads, readsBeforeRevoke);
  });

  test('T14 Project relation drift after actual search prevents release',
      () async {
    final context = await h.approved();
    h.index.afterSearch = () async {
      await h.s.h.db.delete('project_files',
          where: 'project_id=? AND file_id=?',
          whereArgs: [h.project, 'file-a']);
    };
    await expectLater(
        h.search(context), fileFailure(ExternalReadFailure.denied));
  });

  test('T15 reparse changes real generation, invalidating snapshot and Passage',
      () async {
    final context = await h.approved();
    final ref = (await h.search(context)).items.single['passageRef'] as String;
    await h.lifecycle.reparseArtifact(
        fileId: 'file-a',
        options: FileReadHarness.options,
        expectedRevision: 1);
    await expectLater(
        h.search(context), fileFailure(ExternalReadFailure.stale));
    await expectLater(
        h.passage(context, ref), fileFailure(ExternalReadFailure.stale));
  });

  test('T15 delete and same-name replacement never rebind old Passage',
      () async {
    final context = await h.approved();
    final ref = (await h.search(context)).items.single['passageRef'] as String;
    await h.s.h.db
        .delete('library_files', where: 'file_id=?', whereArgs: ['file-a']);
    await h.seed('replacement');
    await expectLater(
        h.passage(context, ref), fileFailure(ExternalReadFailure.denied));
    expect(await h.s.h.count('retrieval_index_builds'), 0);
  });

  test('T16 Context expiry and cursor cannot renew original deadline',
      () async {
    final context = await h.approved();
    final ref = (await h.search(context)).items.single['passageRef'] as String;
    final cursor = (await h.passage(context, ref)).nextCursor;
    h.s.clock.current = h.s.clock.current.add(const Duration(minutes: 15));
    await expectLater(h.passage(context, ref, cursor: cursor),
        fileFailure(ExternalReadFailure.denied));
    expect(h.read.activeHandleCount, 0);
  });

  test('T16 capacity rejection rolls back unreturned File selections',
      () async {
    h.read.close();
    h.compose(maxHandles: 3);
    final context = await h.context();
    expect(h.read.activeHandleCount, 2);
    await expectLater(
        h.read.listFileSelections(session: h.s.session, context: context),
        throwsA(isA<ExternalReadException>()));
    expect(h.read.activeHandleCount, 2);
  });

  test(
      'T16 size reduces complete passage chunks or safely rejects, no partial formula',
      () async {
    final context = await h.approved();
    final ref = (await h.search(context)).items.single['passageRef'] as String;
    // Size bound is fixed at composition: use a new registry and fresh handles.
    h.read.close();
    h.compose(maxBytes: 600);
    final smallContext = await h.approved();
    final smallRef =
        (await h.search(smallContext)).items.single['passageRef'] as String;
    final page = await h.passage(smallContext, smallRef);
    expect(page.items.length, lessThan(8));
    expect(page.hasMore, isTrue);
    expect(externalFileEncodedBytes(page.toJson()), lessThanOrEqualTo(600));
    await expectLater(
        h.passage(smallContext, ref), fileFailure(ExternalReadFailure.denied));
    h.generation.longFormula = true;
    await h.lifecycle.reparseArtifact(
        fileId: 'file-a',
        options: FileReadHarness.options,
        expectedRevision: 1);
    await expectLater(h.approved(), throwsA(isA<ExternalReadException>()));
  });

  for (final timeout in [false, true]) {
    test(
        'T16 T17 ${timeout ? "timeout" : "cancel"} retains slot and unknown effect until real build settlement',
        () async {
      final context = await h.approved();
      final entered = Completer<void>(), unblock = Completer<void>();
      h.index.beforeBuild = () async {
        entered.complete();
        await unblock.future;
      };
      final control = h.s.control();
      final pending = h.read.retrieveFileContent(
          session: h.s.session,
          context: context,
          query: 'needle',
          control: control);
      await entered.future;
      if (!timeout) control.cancel();
      ExternalFileReadException? failure;
      try {
        await pending;
      } on ExternalFileReadException catch (error) {
        failure = error;
      }
      expect(
          failure!.failure,
          timeout
              ? ExternalReadFailure.deadlineExceeded
              : ExternalReadFailure.cancelled);
      expect(failure.evidence.effectKnown, isFalse);
      expect(h.read.pendingCount, 1);
      unblock.complete();
      await h.read.whenIdle;
      expect(h.read.pendingCount, 0);
      expect(failure.evidence.effectKnown, isTrue);
      expect(failure.evidence.derivedCacheWritten, isTrue);
      expect(await h.s.h.count('retrieval_index_builds'), 1);
    });
  }

  test('T17 cache response loss stays unknown despite actual committed cache',
      () async {
    final context = await h.approved();
    h.index.loseBuildResponse = true;
    ExternalFileReadException? failure;
    try {
      await h.search(context);
    } on ExternalFileReadException catch (error) {
      failure = error;
    }
    expect(failure, isNotNull);
    expect(failure!.evidence.effectKnown, isFalse);
    expect(failure.evidence.derivedCacheWritten, isFalse);
    expect(await h.s.h.count('retrieval_index_builds'), 1);
    expect(await h.s.h.count('generated_question_proposals'), 0);
    expect(await h.s.h.count('questions'), 0);
    expect(await h.s.h.count('review_states'), 0);
  });

  test(
      'T7 two currently bound Profiles in one runtime cannot share File/Passage/Cursor',
      () async {
    final other = await h.s.management.createProfile(
        displayName: 'Other', adapter: 'bridge', protocol: 'tcp-v1');
    await h.s.management.replaceGrant(
        other,
        0,
        h.s.policy(
            permissions: [CapabilityPermission.read],
            scopes: [h.bank, h.file('file-a')],
            categories: ExternalContentCategory.values));
    final credentials = _TwoCredentials();
    var next = h.s.profile.profileId;
    final trust = ExternalTrustCore(
        credentials: credentials, clock: h.s.clock, mintProfileId: () => next);
    final admission = ExternalRuntimeAdmission(
        trust: trust,
        management: h.s.management,
        compositionIsCurrent: () => h.s.localSession.isCurrent);
    h.read.close();
    h.compose(admission: admission);
    Future<ExternalSession> authenticate(
        ExternalProfileReference profile, Object key) async {
      next = profile.profileId;
      final principal = trust.createProfile();
      await admission.bindIdentity(profile, principal);
      final id = credentials.identity(key)!;
      trust.requestPairing(principal, requestId: id, credentialIdentity: id);
      trust.approvePairing(principal);
      trust.completePairing(principal, key);
      trust.enable(principal, const Duration(minutes: 30));
      return trust.openSession(trust.authenticate(key));
    }

    try {
      final first = await authenticate(h.s.profile, credentials.first);
      final second = await authenticate(other, credentials.second);
      h.s.session = first;
      final firstParent = await h.context();
      final selection = (await h.read
              .listFileSelections(session: first, context: firstParent))
          .items
          .first['fileRef'] as String;
      final a = await h.approved(parent: firstParent);
      final ref = (await h.search(a)).items.single['passageRef'] as String;
      final cursor = (await h.passage(a, ref)).nextCursor;
      h.s.session = second;
      final secondParent = await h.context();
      final b = await h.approved(parent: secondParent);
      expect((await h.search(b)).items, isNotEmpty);
      await expectLater(
          h.read.createFileContext(
              session: second, context: secondParent, fileRefs: [selection]),
          throwsA(isA<ExternalReadException>()));
      await expectLater(h.passage(b, ref, cursor: cursor),
          fileFailure(ExternalReadFailure.denied));
      await expectLater(h.search(a), fileFailure(ExternalReadFailure.denied));
    } finally {
      admission.close();
    }
  });

  test('T14 T15 source reparse after FTS prevents stale content release',
      () async {
    final context = await h.approved();
    h.index.afterSearch = () async {
      await h.lifecycle.reparseArtifact(
          fileId: 'file-a',
          options: FileReadHarness.options,
          expectedRevision: 1);
    };
    await expectLater(
        h.search(context), fileFailure(ExternalReadFailure.stale));
  });

  test('T13 final release verifies payload rather than trusting warm index',
      () async {
    final context = await h.approved();
    h.index.afterSearch = () async {
      final artifact = (await h.metadata.findCurrentByFileId('file-a'))!;
      await File(p.join(h.managed.path, artifact.storageKey))
          .writeAsString('corrupt');
    };
    await expectLater(
        h.search(context), fileFailure(ExternalReadFailure.dataCorrupt));
  });

  test('T8 original File digest drift invalidates old verified generation',
      () async {
    final context = await h.approved();
    await h.s.h.db.update('library_files', {'sha256': 'b' * 64},
        where: 'file_id=?', whereArgs: ['file-a']);
    await expectLater(
        h.search(context), fileFailure(ExternalReadFailure.stale));
    expect(await h.s.h.count('retrieval_index_builds'), 0);
  });

  test('T16 T17 input budgets reject with known zero cache effect', () async {
    final context = await h.approved();
    for (final query in ['', 'x' * 201, List.filled(33, 'word').join(' ')]) {
      ExternalFileReadException? failure;
      try {
        await h.search(context, query: query);
      } on ExternalFileReadException catch (error) {
        failure = error;
      }
      expect(failure!.failure, ExternalReadFailure.invalidRequest);
      expect(failure.evidence.effectKnown, isTrue);
      expect(failure.evidence.derivedCacheWritten, isFalse);
    }
    expect(await h.s.h.count('retrieval_index_builds'), 0);
  });

  test(
      'T16 fifth same-Profile File READ stays rejected after cancellation until settlement',
      () async {
    final context = await h.approved();
    final ready = Completer<void>(), resume = Completer<void>();
    var entered = 0;
    h.index.beforeBuild = () async {
      entered++;
      if (entered == 4) ready.complete();
      await resume.future;
    };
    final controls = List.generate(4, (_) => h.s.control());
    final pending = [
      for (final control in controls)
        h.read
            .retrieveFileContent(
                session: h.s.session,
                context: context,
                query: 'needle',
                control: control)
            .then<Object>((v) => v, onError: (Object e) => e)
    ];
    await ready.future;
    for (final control in controls) {
      control.cancel();
    }
    await Future.wait(pending);
    expect(h.read.pendingCount, 4);
    await expectLater(
        h.search(context), fileFailure(ExternalReadFailure.resourceLimit));
    resume.complete();
    await h.read.whenIdle;
    expect(h.read.pendingCount, 0);
  });

  test('T14 Passage revoke after verified load suppresses final release',
      () async {
    final context = await h.approved();
    final ref = (await h.search(context)).items.single['passageRef'] as String;
    h.observed.afterRead = () async {
      await h.s.management.revokeGrant(h.s.profile, h.revision);
    };
    await expectLater(
        h.passage(context, ref), fileFailure(ExternalReadFailure.denied));
  });

  test('T5 File scopes in another Project never enter this Context', () async {
    await h.s.h.db.insert('projects',
        {'project_id': 'other', 'display_name': 'Other', 'created_at': 1});
    await h.s.h.db
        .insert('project_files', {'project_id': 'other', 'file_id': 'file-b'});
    await h.grant(scopes: [h.bank, h.file('file-b', space: 'other')]);
    final context = await h.context();
    await expectLater(
        h.read.listFileSelections(session: h.s.session, context: context),
        throwsA(isA<ExternalReadException>()));
    expect(h.observed.reads, 0);
  });

  test('T15 same File ID recreation binds a different real Artifact generation',
      () async {
    final context = await h.approved();
    final ref = (await h.search(context)).items.single['passageRef'] as String;
    final before = (await h.metadata.findCurrentByFileId('file-a'))!;
    await h.s.h.db
        .delete('library_files', where: 'file_id=?', whereArgs: ['file-a']);
    await h.seed('file-a');
    final after = (await h.metadata.findCurrentByFileId('file-a'))!;
    expect(after.artifactId, isNot(before.artifactId));
    await expectLater(
        h.passage(context, ref), fileFailure(ExternalReadFailure.stale));
  });

  test('T18 actual database restart drops File/Passage Context and cursors',
      () async {
    final context = await h.approved();
    final ref = (await h.search(context)).items.single['passageRef'] as String;
    final cursor = (await h.passage(context, ref)).nextCursor;
    await h.s.reopen();
    expect(h.read.activeHandleCount, 0);
    h.compose();
    await expectLater(h.passage(context, ref, cursor: cursor),
        fileFailure(ExternalReadFailure.denied));
    final fresh = await h.approved();
    await expectLater(h.passage(fresh, ref, cursor: cursor),
        fileFailure(ExternalReadFailure.denied));
    expect((await h.search(fresh)).items, isNotEmpty);
  });
}
