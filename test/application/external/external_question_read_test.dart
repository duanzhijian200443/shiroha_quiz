import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:shiroha_quiz/application/capabilities/capability.dart';
import 'package:shiroha_quiz/application/external/external_authorization.dart';
import 'package:shiroha_quiz/application/external/external_question_read.dart';
import 'package:shiroha_quiz/application/external/external_read_context.dart';
import 'package:shiroha_quiz/application/external/external_trust_core.dart';
import 'package:shiroha_quiz/application/external/external_runtime_admission.dart';
import 'package:shiroha_quiz/data/repositories/external_target_read_repository.dart';
import 'package:shiroha_quiz/data/repositories/external_question_read_repository.dart';
import 'package:shiroha_quiz/domain/assets/asset_ref.dart';
import 'package:shiroha_quiz/domain/assets/sourced_asset_ref.dart';
import 'package:shiroha_quiz/domain/content/content_node.dart';
import 'package:shiroha_quiz/domain/content/rich_content.dart';
import 'package:shiroha_quiz/domain/question/question_draft_v2.dart';
import 'package:shiroha_quiz/domain/question/question_draft_v2_codec.dart';
import 'package:shiroha_quiz/domain/source/source_ref.dart';
import 'external_question_read_test_support.dart';

Matcher rejected(ExternalReadFailure code) =>
    throwsA(isA<ExternalReadException>()
        .having((error) => error.failure, 'fixed category', code));

final class _Credentials implements ExternalCredentialPort {
  final first = Object(), second = Object();
  String? identity(Object key) => identical(key, first)
      ? 'first'
      : identical(key, second)
          ? 'second'
          : null;
  @override
  AuthenticatedPeerEvidence? authenticate(Object key) {
    final id = identity(key);
    return id == null ? null : AuthenticatedPeerEvidence(id);
  }

  @override
  PairingProof? provePossession(Object key) {
    final id = identity(key);
    return id == null ? null : PairingProof(id, id);
  }
}

void main() {
  initializeGeneratedTests();
  late QuestionReadHarness h;
  setUp(() async {
    h = QuestionReadHarness();
    await h.open();
  });
  tearDown(() async => h.close());
  Future<ExternalQuestionSearchPage> search(String context,
          {String query = 'needle', int size = 20, String? cursor}) =>
      h.read.searchQuestions(
          session: h.s.session,
          context: context,
          query: query,
          pageSize: size,
          cursor: cursor);
  Future<ExternalQuestionDetail> detail(String context, String ref) =>
      h.read.getQuestionDetail(
          session: h.s.session, context: context, questionRef: ref);
  Future<void> policy(ExternalGrantPolicy value) async {
    final revision =
        (await h.s.management.read(h.s.profile)).profile.grantRevision;
    await h.s.management.replaceGrant(h.s.profile, revision, value);
  }

  test(
      'T1/T2 authentic Session/Enablement and exact process Context precede content reads',
      () async {
    final context = await h.context();
    expect(() => h.s.trust.authenticate({'trusted': true}),
        throwsA(isA<ExternalCoreException>()));
    h.s.trust.disable(h.s.principal);
    await expectLater(search(context), rejected(ExternalReadFailure.denied));
    expect(h.contentReads, 0);
    h.s.trust.enable(h.s.principal, const Duration(minutes: 30));
    h.s.session = h.s.trust
        .openSession(h.s.trust.authenticate(h.s.credentials.authentication));
    await expectLater(search(context), rejected(ExternalReadFailure.denied));
    expect(h.contentReads, 0);
  });

  for (final mode in ['permission', 'egress', 'empty-scope']) {
    test(
        'T3 $mode denies content without inferring STAGE/proposalMetadata rights',
        () async {
      final context = await h.context();
      await policy(h.s.policy(
          permissions: mode == 'permission'
              ? [CapabilityPermission.stage]
              : [CapabilityPermission.read],
          categories: mode == 'egress'
              ? [ExternalContentCategory.proposalMetadata]
              : [ExternalContentCategory.questionContent],
          scopes: mode == 'empty-scope' ? [] : null));
      await expectLater(search(context), rejected(ExternalReadFailure.denied));
      expect(h.contentReads, 0);
    });
  }

  test(
      'T4/T5 exact Bank/Project SQL never reads another granted bank or corrupt private bank',
      () async {
    await h.s.h.db.insert('bank_folders',
        {'bank_name': 'private', 'folder_name': 'private-folder'});
    await h.typed(bank: 'private');
    await h.s.h.db.update('question_v2_payloads', {'payload_json': '{broken'});
    await h.typed();
    await h.s.h.db.insert('projects',
        {'project_id': 'p', 'display_name': 'Synthetic', 'created_at': 1});
    await h.s.h.db
        .insert('project_banks', {'project_id': 'p', 'bank_name': 'bank'});
    await h.s.h.db
        .insert('project_banks', {'project_id': 'p', 'bank_name': 'private'});
    await policy(h.s.policy(permissions: [
      CapabilityPermission.read
    ], scopes: [
      ExternalGrantScope(
          kind: ExternalTargetKind.bank, targetId: 'bank', projectId: 'p'),
      ExternalGrantScope(
          kind: ExternalTargetKind.bank, targetId: 'private', projectId: 'p'),
    ]));
    final context = await h.context();
    final page = await search(context);
    expect(page.items, hasLength(1));
    expect(jsonEncode(page.toJson()), isNot(contains('private')));
    final otherContext = await h.context(bank: 'private');
    await expectLater(detail(otherContext, page.items.single.questionRef),
        rejected(ExternalReadFailure.denied));
    for (final token in ['private', 'missing', 'A' * 43]) {
      await expectLater(
          detail(context, token), rejected(ExternalReadFailure.denied));
    }
    expect(page.items.single.toJson().keys.toSet(), {
      'questionRef',
      'kind',
      'stemPreview',
      'hasAnswer',
      'hasExplanation',
      'sourceKind'
    });
    expect(page.toJson().keys.toSet(), {'items', 'nextCursor'});
  });

  test('T6 stable keyset pages, query binding and literal wildcard/SQL input',
      () async {
    for (final id in ['a', 'b', 'c']) {
      await h.legacy(id, stem: 'needle $id 100%_done');
    }
    final context = await h.context();
    final first = await search(context, size: 1);
    final second = await search(context, size: 1, cursor: first.nextCursor);
    final third = await search(context, size: 1, cursor: second.nextCursor);
    expect(
        [first, second, third].map((p) => p.items.single.stemPreview).toList(),
        ['needle c 100%_done', 'needle b 100%_done', 'needle a 100%_done']);
    expect(third.nextCursor, isNull);
    await expectLater(
        search(context, query: 'different', cursor: first.nextCursor),
        rejected(ExternalReadFailure.denied));
    expect((await search(context, query: "' OR 1=1 --")).items, isEmpty);
    expect((await search(context, query: '%_')).items, hasLength(3));
    for (final query in ['', ' ' * 200, 'a' * 201]) {
      await expectLater(search(context, query: query),
          rejected(ExternalReadFailure.invalidRequest));
    }
    for (final size in [0, 51]) {
      await expectLater(search(context, size: size),
          rejected(ExternalReadFailure.invalidRequest));
    }
  });

  test(
      'T6 bounded scan can return an empty continuation page without dropping later hits',
      () async {
    for (var i = 0; i < 129; i++) {
      await h.legacy('q$i',
          createdAt: 129 - i, stem: i == 128 ? 'needle' : 'other');
    }
    final context = await h.context();
    final first = await search(context);
    expect(first.items, isEmpty);
    expect(first.nextCursor, isNotNull);
    final last = await search(context, cursor: first.nextCursor);
    expect(last.items, hasLength(1));
    expect(last.nextCursor, isNull);
  });

  test(
      'T7 Context-specific opaque references cannot be raw identities or another Context cursor',
      () async {
    final id = await h.typed();
    await h.legacy('extra');
    final context = await h.context();
    final other = await h.context();
    final page = await search(context, size: 1);
    expect(page.items.single.questionRef, hasLength(43));
    expect(page.items.single.questionRef, isNot(id));
    await expectLater(detail(other, page.items.single.questionRef),
        rejected(ExternalReadFailure.denied));
    await expectLater(search(other, cursor: page.nextCursor),
        rejected(ExternalReadFailure.denied));
    await expectLater(
        detail(context, id), rejected(ExternalReadFailure.denied));
    await expectLater(detail(context, page.nextCursor!),
        rejected(ExternalReadFailure.denied));
    final foreign = ExternalTrustCore(
        credentials: h.s.credentials,
        clock: h.s.clock,
        mintProfileId: () => h.s.profile.profileId);
    final principal = foreign.createProfile();
    foreign.requestPairing(principal,
        requestId: 'synthetic-pairing',
        credentialIdentity: 'synthetic-credential');
    foreign.approvePairing(principal);
    foreign.completePairing(principal, h.s.credentials.proof);
    foreign.enable(principal, const Duration(minutes: 30));
    final session = foreign
        .openSession(foreign.authenticate(h.s.credentials.authentication));
    await expectLater(
        h.read.getQuestionDetail(
            session: session,
            context: context,
            questionRef: page.items.single.questionRef),
        rejected(ExternalReadFailure.denied));
  });

  test(
      'T2/T7 two independently bound Profiles in one runtime cannot share question references',
      () async {
    await h.typed();
    await h.legacy('extra');
    final other = await h.s.management.createProfile(
        displayName: 'Other', adapter: 'bridge', protocol: 'tcp-v1');
    await h.s.management.replaceGrant(
        other, 0, h.s.policy(permissions: [CapabilityPermission.read]));
    final credentials = _Credentials();
    var nextId = h.s.profile.profileId;
    final trust = ExternalTrustCore(
        credentials: credentials,
        clock: h.s.clock,
        mintProfileId: () => nextId);
    final admission = ExternalRuntimeAdmission(
        trust: trust,
        management: h.s.management,
        compositionIsCurrent: () => h.s.localSession.isCurrent);
    h.read.close();
    h.read = ExternalReadContextService(
        admission: admission,
        targets:
            SqliteExternalTargetReadRepository(databaseHelper: h.s.h.helper),
        questions:
            SqliteExternalQuestionReadRepository(databaseHelper: h.s.h.helper));
    Future<ExternalSession> session(
        ExternalProfileReference profile, Object key) async {
      nextId = profile.profileId;
      final principal = trust.createProfile();
      await admission.bindIdentity(profile, principal);
      final id = credentials.identity(key)!;
      trust.requestPairing(principal, requestId: id, credentialIdentity: id);
      trust.approvePairing(principal);
      trust.completePairing(principal, key);
      trust.enable(principal, const Duration(minutes: 30));
      return trust.openSession(trust.authenticate(key));
    }

    Future<String> contextFor(ExternalSession authenticated) async {
      final target = (await h.read.listTargets(session: authenticated))
          .items
          .single
          .targetRef;
      return h.read.createContext(session: authenticated, targetRef: target);
    }

    try {
      final first = await session(h.s.profile, credentials.first);
      final second = await session(other, credentials.second);
      final a = await contextFor(first), b = await contextFor(second);
      final page = await h.read.searchQuestions(
          session: first, context: a, query: 'needle', pageSize: 1);
      expect(
          (await h.read.searchQuestions(
                  session: second, context: b, query: 'needle'))
              .items,
          hasLength(2));
      await expectLater(
          h.read.getQuestionDetail(
              session: second,
              context: b,
              questionRef: page.items.single.questionRef),
          rejected(ExternalReadFailure.denied));
      await expectLater(
          h.read.searchQuestions(
              session: second,
              context: b,
              query: 'needle',
              cursor: page.nextCursor),
          rejected(ExternalReadFailure.denied));
      await expectLater(
          h.read.searchQuestions(session: second, context: a, query: 'needle'),
          rejected(ExternalReadFailure.denied));
    } finally {
      admission.close();
    }
  });

  test(
      'T8 typed authority projects exact text/math/options/answer labels and ignores V1 decoy',
      () async {
    final id = await h.typed(
        draft: makeDraft('typed',
            stem: richContent([
              const TextNode('needle '),
              const InlineMathNode('x'),
              const BlockMathNode('y')
            ]),
            options: [
              QuestionOption(
                  optionId: 'option-a',
                  label: 'A',
                  content: textContent('One')),
              QuestionOption(
                  optionId: 'option-b', label: 'B', content: textContent('Two'))
            ],
            answer: ChoiceAnswer(optionIds: ['option-b']),
            explanation: RichContent(nodes: [])));
    await h.s.h.db.update(
        'questions',
        {
          'content': 'V1-decoy',
          'standard_answer': 'V1-answer',
          'explanation': 'V1-explanation'
        },
        where: 'id=?',
        whereArgs: [id]);
    final context = await h.context();
    expect((await search(context, query: 'V1-decoy')).items, isEmpty);
    final page = await search(context);
    expect(page.items.single.sourceKind.name, 'typed');
    final output =
        (await detail(context, page.items.single.questionRef)).toJson();
    expect(output.keys.toSet(),
        {'kind', 'stem', 'options', 'answer', 'explanation', 'sourceKind'});
    expect(output['stem'], [
      {'type': 'text', 'text': 'needle '},
      {'type': 'inline_math', 'latex': 'x'},
      {'type': 'block_math', 'latex': 'y'}
    ]);
    expect(output['answer'], [
      {'type': 'text', 'text': 'B'}
    ]);
    expect(output['explanation'], []);
    expect((output['options'] as List).map((o) => (o as Map)['label']).toList(),
        ['A', 'B']);
    for (final forbidden in [
      'V1-',
      id,
      'option-a',
      'questionId',
      'bankName',
      'due',
      'review'
    ]) {
      expect(jsonEncode(output), isNot(contains(forbidden)));
    }
  });

  test('T8 null and explicit empty typed answer/explanation remain distinct',
      () async {
    await h.typed(
        draft: makeDraft('null',
            kind: QuestionKind.shortAnswer, stem: textContent('needle null')));
    await h.typed(
        draft: makeDraft('empty',
            kind: QuestionKind.shortAnswer,
            stem: textContent('needle empty'),
            answer: ContentAnswer(content: RichContent(nodes: [])),
            explanation: RichContent(nodes: [])));
    final context = await h.context();
    final page = await search(context);
    for (final item in page.items) {
      final output = (await detail(context, item.questionRef)).toJson();
      final empty = item.stemPreview.endsWith('empty');
      expect(output['answer'], empty ? [] : null);
      expect(output['explanation'], empty ? [] : null);
      expect(item.hasAnswer, empty);
      expect(item.hasExplanation, empty);
    }
  });

  test(
      'T9 genuinely absent sidecar uses existing strict legacy-safe projection',
      () async {
    await h.legacy('old-id');
    final context = await h.context();
    final item = (await search(context)).items.single;
    final output = (await detail(context, item.questionRef)).toJson();
    expect(output['sourceKind'], 'legacy');
    expect(output['stem'], [
      {'type': 'text', 'text': 'Legacy needle'}
    ]);
    expect(output['answer'], [
      {'type': 'text', 'text': 'Legacy answer'}
    ]);
    expect(output['options'], [
      {
        'label': 'A',
        'content': [
          {'type': 'text', 'text': 'one'}
        ]
      },
      {
        'label': 'B',
        'content': [
          {'type': 'text', 'text': 'two'}
        ]
      }
    ]);
  });

  test(
      'T8/T18 emitted DTOs are immutable and READ leaves durable business/policy rows unchanged',
      () async {
    await h.typed();
    final context = await h.context();
    const tables = [
      'questions',
      'question_v2_payloads',
      'review_states',
      'generated_question_proposals',
      'external_client_profiles',
      'external_grants',
      'external_grant_scopes',
      'external_grant_egress'
    ];
    final before = {
      for (final table in tables) table: await h.s.h.db.query(table)
    };
    final item = (await search(context)).items.single;
    final result = await detail(context, item.questionRef);
    expect(() => result.stem.clear(), throwsUnsupportedError);
    for (final table in tables) {
      expect(await h.s.h.db.query(table), before[table]);
    }
  });

  for (final mode in ['malformed', 'partial', 'unsafe', 'unsupported']) {
    test(
        'T10 real $mode sidecar fails complete search/detail without V1 fallback',
        () async {
      final id = await h.typed();
      final context = await h.context();
      final ref = (await search(context)).items.single.questionRef;
      final row = (await h.s.h.db.query('question_v2_payloads')).single;
      final body =
          jsonDecode(row['payload_json'] as String) as Map<String, dynamic>;
      if (mode == 'partial') {
        body.remove('stem');
      }
      if (mode == 'unsafe') {
        body['stem'] = [
          {
            'type': 'raw_fallback',
            'payload': {'path': 'C:/synthetic-private'}
          }
        ];
      }
      if (mode == 'unsupported') {
        body['schemaVersion'] = 99;
      }
      await h.s.h.db.update('question_v2_payloads',
          {'payload_json': mode == 'malformed' ? '{bad' : jsonEncode(body)},
          where: 'question_id=?', whereArgs: [id]);
      await expectLater(
          search(context), rejected(ExternalReadFailure.dataCorrupt));
      await expectLater(
          detail(context, ref), rejected(ExternalReadFailure.dataCorrupt));
    });
  }

  test(
      'T11 legal RawFallback and Image become unsupported without source/path/payload release',
      () async {
    final id = await h.typed();
    final draft = QuestionDraftV2(
        questionId: 'safe-image',
        kind: QuestionKind.shortAnswer,
        stem: richContent([
          const TextNode('needle'),
          RawFallbackNode(rawFallbackPayload('hidden-marker')),
          ImageNode(sourceId: 'source-private', localAssetId: 'asset-private')
        ]),
        sourceRefs: [
          SourceRef.document(sourceId: 'source-private')
        ],
        assetRefs: [
          SourcedAssetRef(
              sourceId: 'source-private',
              asset: AssetRef(assetId: 'asset-private', kind: AssetKind.image))
        ]);
    // Fully legal read payload with strict codec/inventory. No file/byte loading.
    await h.s.h.db.update(
        'question_v2_payloads',
        {
          'payload_json': jsonEncode(const QuestionDraftV2Codec().encode(draft))
        },
        where: 'question_id=?',
        whereArgs: [id]);
    final context = await h.context();
    expect((await search(context, query: 'hidden-marker')).items, isEmpty);
    final item = (await search(context)).items.single;
    final output = (await detail(context, item.questionRef)).toJson();
    expect(output['stem'], [
      {'type': 'text', 'text': 'needle'},
      {'type': 'unsupported'},
      {'type': 'unsupported'}
    ]);
    for (final marker in [
      'hidden-marker',
      'source-private',
      'asset-private',
      'payload',
      'path',
      'rawJson'
    ]) {
      expect(jsonEncode(output), isNot(contains(marker)));
      expect(jsonEncode(item.toJson()), isNot(contains(marker)));
    }
  });

  for (final mode in ['one-null', 'both-null']) {
    test('T10 real present $mode sidecar is never misread as absent legacy',
        () async {
      final id = await h.typed();
      final context = await h.context();
      final ref = (await search(context)).items.single.questionRef;
      // Corruption-only synthetic table shape; production schema is unchanged.
      await h.s.h.db.execute('DROP TABLE question_v2_payloads');
      await h.s.h.db.execute(
          'CREATE TABLE question_v2_payloads(question_id TEXT PRIMARY KEY, payload_schema_version INTEGER, payload_json TEXT)');
      await h.s.h.db.insert('question_v2_payloads', {
        'question_id': id,
        'payload_schema_version': mode == 'both-null' ? null : 2,
        'payload_json': null
      });
      await expectLater(
          search(context), rejected(ExternalReadFailure.dataCorrupt));
      await expectLater(
          detail(context, ref), rejected(ExternalReadFailure.dataCorrupt));
    });
  }

  test('T12 revoke before scoped Data admission reads no question body',
      () async {
    await h.typed();
    final context = await h.context();
    h.barrier.beforeSearch = () => h.s.management.revokeGrant(h.s.profile, 2);
    await expectLater(search(context), rejected(ExternalReadFailure.denied));
    expect(h.contentReads, 0);
    expect(h.barrier.releases, 0);
  });

  for (final mode in ['grant-revoke', 'profile-revoke', 'revision', 'scope']) {
    test(
        'T12 $mode after Data return suppresses previews and details at final Release',
        () async {
      await h.typed();
      final context = await h.context();
      final item = (await search(context)).items.single;
      Future<void> mutate() async {
        if (mode == 'grant-revoke') {
          await h.s.management.revokeGrant(h.s.profile, 2);
        } else if (mode == 'profile-revoke') {
          await h.s.management.revokeProfile(h.s.profile, 2);
        } else {
          await policy(h.s.policy(
              permissions: [CapabilityPermission.read],
              scopes: mode == 'scope' ? [] : null));
        }
      }

      h.barrier.afterDetail = mutate;
      await expectLater(detail(context, item.questionRef),
          rejected(ExternalReadFailure.denied));
      expect(h.barrier.releases, 2);
    });
  }

  test(
      'T12 queued durable revoke during real read transaction suppresses final search release',
      () async {
    await h.typed();
    final context = await h.context();
    final entered = Completer<void>(), resume = Completer<void>();
    h.checkpoint = (point) async {
      if (point == ExternalQuestionReadCheckpoint.afterContentRead &&
          !entered.isCompleted) {
        entered.complete();
        await resume.future;
      }
    };
    final pending = search(context);
    await entered.future;
    final revoked = h.s.management.revokeGrant(h.s.profile, 2);
    h.barrier.afterSearch = () async {
      await revoked;
    };
    resume.complete();
    await expectLater(pending, rejected(ExternalReadFailure.denied));
  });

  for (final mode in [
    'delete',
    'move',
    'replace',
    'edit',
    'project',
    'folder'
  ]) {
    test('T13 $mode after Data detail cannot release selected/other content',
        () async {
      final id = await h.typed();
      if (mode == 'project') {
        await h.s.h.db.insert('projects',
            {'project_id': 'p', 'display_name': 'Synthetic', 'created_at': 1});
        await h.s.h.db
            .insert('project_banks', {'project_id': 'p', 'bank_name': 'bank'});
        await policy(h.s.policy(permissions: [
          CapabilityPermission.read
        ], scopes: [
          ExternalGrantScope(
              kind: ExternalTargetKind.bank, targetId: 'bank', projectId: 'p')
        ]));
      }
      final context = await h.context();
      final ref = (await search(context)).items.single.questionRef;
      h.barrier.afterDetail = () async {
        if (mode == 'delete' || mode == 'replace') {
          await h.s.h.db.delete('questions', where: 'id=?', whereArgs: [id]);
          if (mode == 'replace') {
            await h.typed(
                id: id,
                draft: makeDraft('replacement',
                    kind: QuestionKind.shortAnswer,
                    stem: textContent('Different content')));
          }
        } else if (mode == 'move') {
          await h.s.h.db.update('questions', {'bank_name': 'ungranted'},
              where: 'id=?', whereArgs: [id]);
        } else if (mode == 'project') {
          await h.s.h.db
              .delete('project_banks', where: 'project_id=?', whereArgs: ['p']);
        } else if (mode == 'folder') {
          await h.s.h.db.update('bank_folders', {'folder_name': 'changed'});
        } else {
          final value = makeDraft('edited',
              kind: QuestionKind.shortAnswer,
              stem: textContent('Changed content'));
          await h.s.h.db.update(
              'question_v2_payloads',
              {
                'payload_json':
                    jsonEncode(const QuestionDraftV2Codec().encode(value))
              },
              where: 'question_id=?',
              whereArgs: [id]);
        }
      };
      await expectLater(
          detail(context, ref),
          rejected(mode == 'project'
              ? ExternalReadFailure.denied
              : ExternalReadFailure.stale));
    });
  }

  test(
      'T14 search/reference capacity is shared and failed allocations are removed',
      () async {
    for (var i = 0; i < 5; i++) {
      await h.legacy('q$i');
    }
    h.read.close();
    h.compose(maxHandles: 4);
    final context = await h.context();
    final before = h.read.activeHandleCount;
    await expectLater(
        search(context), rejected(ExternalReadFailure.resourceLimit));
    expect(h.read.activeHandleCount, before);
    final page = await search(context, size: 1);
    expect(page.items, hasLength(1));
    expect(h.read.activeHandleCount, 4);
  });

  test(
      'T14 complete detail exceeds response budget without partial math/answer output',
      () async {
    await h.typed(
        draft: makeDraft('large',
            kind: QuestionKind.shortAnswer,
            stem: textContent('needle'),
            explanation:
                richContent(List.generate(8, (_) => BlockMathNode('中' * 900))),
            answer: ContentAnswer(
                content: richContent(
                    List.generate(8, (_) => TextNode('中' * 900))))));
    final context = await h.context();
    final ref = (await search(context)).items.single.questionRef;
    await expectLater(
        detail(context, ref), rejected(ExternalReadFailure.resourceLimit));
  });

  test('T14 Question READ composition cannot enlarge accepted P4 maximums', () {
    expect(
        () => ExternalReadContextService(
            admission: h.s.service.runtimeAdmission,
            targets: SqliteExternalTargetReadRepository(
                databaseHelper: h.s.h.helper),
            questions: h.barrier,
            maxResponseBytes: 32769),
        throwsArgumentError);
    expect(
        () => ExternalReadContextService(
            admission: h.s.service.runtimeAdmission,
            targets: SqliteExternalTargetReadRepository(
                databaseHelper: h.s.h.helper),
            questions: h.barrier,
            maxActiveHandles: 257),
        throwsArgumentError);
  });

  test(
      'T14 oversized stored candidate is rejected before payload materialization',
      () async {
    await h.legacy('oversized', stem: '中' * 90000);
    final context = await h.context();
    await expectLater(
        search(context), rejected(ExternalReadFailure.resourceLimit));
    expect(h.contentReads, 0);
  });

  test(
      'T14 oversized legacy storage identity is rejected before body materialization',
      () async {
    await h.legacy('x' * 257);
    final context = await h.context();
    await expectLater(
        search(context), rejected(ExternalReadFailure.resourceLimit));
    expect(h.contentReads, 0);
  });

  for (final mode in ['expiry', 'restart', 'restore']) {
    test(
        'T15 $mode invalidates Context, QuestionRef and search cursor together',
        () async {
      await h.typed();
      await h.legacy('extra');
      final context = await h.context();
      final page = await search(context, size: 1);
      if (mode == 'expiry') {
        h.s.clock.current = h.s.clock.current.add(const Duration(minutes: 15));
      } else if (mode == 'restart') {
        h.s.trust.restart();
      } else {
        h.s.trust.restore();
      }
      await expectLater(search(context, cursor: page.nextCursor),
          rejected(ExternalReadFailure.denied));
      await expectLater(detail(context, page.items.single.questionRef),
          rejected(ExternalReadFailure.denied));
      h.read.sweep();
      expect(h.read.activeHandleCount, 0);
    });
  }

  for (final mode in ['cancel', 'deadline', 'close']) {
    test(
        'T14 $mode prevents late output and holds pending capacity until settlement',
        () async {
      await h.typed();
      h.read.close();
      h.compose(maxPending: 1);
      final context = await h.context();
      final entered = Completer<void>(), resume = Completer<void>();
      h.barrier.afterSearch = () async {
        entered.complete();
        await resume.future;
      };
      final control = h.s.control();
      final pending = h.read.searchQuestions(
          session: h.s.session,
          context: context,
          query: 'needle',
          control: control);
      await entered.future;
      if (mode == 'cancel') {
        control.cancel();
      } else if (mode == 'deadline') {
        h.s.clock.current = h.s.clock.current.add(const Duration(seconds: 2));
      } else {
        h.read.close();
      }
      if (mode == 'cancel') {
        await expectLater(pending, rejected(ExternalReadFailure.cancelled));
        expect(h.read.pendingCount, 1);
        await expectLater(
            search(context), rejected(ExternalReadFailure.resourceLimit));
      }
      resume.complete();
      if (mode != 'cancel') {
        await expectLater(
            pending,
            rejected(mode == 'close'
                ? ExternalReadFailure.denied
                : ExternalReadFailure.deadlineExceeded));
      }
      await h.read.whenIdle;
      expect(h.read.pendingCount, 0);
      expect(h.read.activeHandleCount, mode == 'close' ? 0 : 2);
    });
  }

  test(
      'T15 actual file reopen with rebuilt Trust/Admission/Registry rejects old Context/QuestionRef',
      () async {
    await h.typed();
    final context = await h.context();
    final ref = (await search(context)).items.single.questionRef;
    await h.s.reopen();
    h.compose();
    final fresh = await h.context();
    await expectLater(detail(fresh, ref), rejected(ExternalReadFailure.denied));
    await expectLater(search(context), rejected(ExternalReadFailure.denied));
    expect((await search(fresh)).items, hasLength(1));
  });

  test(
      'T15 real isolated process cannot recover Context, QuestionRef or search cursor',
      () async {
    await h.typed();
    await h.legacy('another');
    final context = await h.context();
    final page = await search(context, size: 1);
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
    final child = await Process.start(
        dart,
        [
          '--packages=.dart_tool/package_config.json',
          'test/application/external/external_read_process_probe.dart'
        ],
        workingDirectory: Directory.current.path);
    final output = child.stdout.transform(utf8.decoder).join();
    final errors = child.stderr.transform(utf8.decoder).join();
    child.stdin.writeln(jsonEncode({
      'profileId': h.s.profile.profileId,
      'context': context,
      'questionRef': page.items.single.questionRef,
      'cursor': page.nextCursor
    }));
    await child.stdin.close();
    try {
      expect(await child.exitCode.timeout(const Duration(seconds: 45)), 0);
      expect(await output, 'invalid\n');
      expect(await errors, isEmpty);
    } finally {
      child.kill();
    }
  });

  test(
      'T18 Application read proof/DTOs never wire transport, writer or general Principal',
      () {
    for (final path in [
      'lib/application/external/external_question_read.dart',
      'lib/application/external/external_read_context.dart',
      'lib/application/study_query/study_question_projection.dart'
    ]) {
      final source = File(path).readAsStringSync();
      final imports = RegExp(r'''(?:import|export)\s+['"]([^'"]+)['"]''')
          .allMatches(source)
          .map((m) => m[1]!);
      for (final forbidden in [
        'dart:io',
        'sqflite',
        '/data/',
        'database_helper',
        'flutter',
        'mcp_dart'
      ]) {
        expect(imports.any((i) => i.contains(forbidden)), isFalse);
      }
    }
    final reader =
        File('lib/data/repositories/external_question_read_repository.dart')
            .readAsStringSync();
    for (final forbidden in [
      '.insert(',
      '.update(',
      '.delete(',
      '.execute(',
      'review_states',
      'review_logs',
      'library_files'
    ]) {
      expect(reader, isNot(contains(forbidden)));
    }
    expect(reader, contains('materializeExactQuestions'));
    for (final path in ['lib/main.dart', 'lib/mcp/study_mcp_server.dart']) {
      expect(File(path).readAsStringSync(),
          isNot(contains('ExternalQuestionReadPort')));
    }
  });
}
