// Actual installed Windows Codex -> seven tools -> existing test mailbox -> P6.
// Synthetic F1 generation is seeded by FileReadHarness; reads use real F1/FTS5.
import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:shiroha_quiz/application/capabilities/capability.dart';
import 'package:shiroha_quiz/application/external/external_authorization.dart';
import 'package:shiroha_quiz/application/external/local_host_dispatch.dart';
import 'package:shiroha_quiz/mcp/vnext_mcp_composition_root.dart';
import '../application/external/external_file_read_test_support.dart';
import '../application/external/local_host_test_support.dart'
    show OfflineReadiness;
import '../application/study_query/study_query_test_support.dart'
    show insertLegacyQuestion;
import 'fixtures/codex_synthetic_app_support.dart';
import 'fixtures/vnext_mcp_test_support.dart' show AppAuthentication, batch;

final class _FileApp {
  final files = FileReadHarness();
  late VnextMcpAppComposition composition;

  Future<void> open() async {
    await files.open();
    await insertLegacyQuestion(files.s.h.db,
        id: 'synthetic-question',
        createdAt: 1,
        bankName: 'bank',
        content: 'Synthetic needle');
    await compose();
  }

  /// Warm the shared App read path before Codex assertions. File retrieval stays
  /// cold, keeping index-build and F1-read evidence attributable to each case.
  Future<void> warmRead() async {
    Future<Map<String, dynamic>> direct(String tool,
            [Map<String, dynamic> arguments = const {}]) async =>
        _data(await composition.call(tool, arguments,
            cancelled: const Stream<void>.empty(), available: () => true));
    final targets = await direct('open_generation_context');
    final target = (targets['items'] as List).single as Map;
    final opened = await direct(
        'open_generation_context', {'targetRef': target['targetRef']});
    final context = opened['contextRef'] as String;
    final search = await direct(
        'search_questions', {'contextRef': context, 'query': 'needle'});
    final hit = (search['items'] as List).single as Map;
    await direct('get_question_detail',
        {'contextRef': context, 'questionRef': hit['questionRef']});
    await direct('open_generation_context', {'contextRef': context});
  }

  Future<void> compose() async {
    final host = LocalHostDispatchCore(
        gateway: ExternalCapabilityGateway(
            stages: files.s.service, reads: files.read),
        readiness: OfflineReadiness(() async {
          expect(
              (await files.s.h.db.rawQuery('PRAGMA user_version'))
                  .single
                  .values
                  .single,
              34);
        }));
    await host.startOffline();
    composition = VnextMcpAppComposition(
        host: host,
        reads: files.read,
        stages: files.s.service,
        authentication: AppAuthentication(files.s.session),
        approvedTargets: []);
  }

  Future<void> restart() async {
    await composition.close();
    files.read.close();
    await files.read.whenIdle;
    await files.s.reopen();
    files.compose();
    await compose();
  }

  Future<void> close() async {
    try {
      await composition.close();
    } finally {
      await files.close();
    }
  }
}

Map<String, dynamic> _data(Map<String, dynamic> envelope) {
  expect(envelope['error'], isNull);
  return (envelope['data'] as Map).cast<String, dynamic>();
}

void _denied(Map<String, dynamic> envelope) {
  expect(envelope['data'], isNull);
  expect(
      envelope['error'],
      isIn({
        'capability.accessDenied',
        'capability.externalReadDenied',
        'capability.externalReadStale',
        'capability.externalReadDataCorrupt',
      }));
}

void main() {
  initializeGeneratedTests();
  final executable = Platform.environment['SHIROHA_CODEX_EXE'];
  final skip = Platform.isWindows && executable != null
      ? false
      : 'UNVERIFIED: Windows + explicit SHIROHA_CODEX_EXE required.';
  late _FileApp app;
  late Directory home;
  late CodexSyntheticAppLink link;
  late CodexSyntheticClient client;

  setUp(() async {
    final root = Directory(
        p.join(Directory.current.path, '.dart_tool', 'codex-client-tests'));
    await root.create(recursive: true);
    home = await root.createTemp('Codex File READ 合成 ');
    app = _FileApp();
    await app.open();
    await app.warmRead();
    final mailbox = await Directory(p.join(home.path, 'app-link')).create();
    link = CodexSyntheticAppLink(mailbox, () => app.composition)..start();
    client = CodexSyntheticClient(executable!, home, mailbox);
    await client.connect();
  });

  tearDown(() async {
    try {
      await client.disconnect();
    } finally {
      try {
        await link.close();
        await app.close();
      } finally {
        // Task-owned path only. A retained Windows handle fails cleanup.
        await home.delete(recursive: true);
        expect(home.existsSync(), isFalse);
      }
    }
  });

  Future<String> parent() async {
    final targets = _data(await client.call('open_generation_context'));
    final target = (targets['items'] as List).single as Map;
    expect(target['projectId'], app.files.project);
    return _data(await client.call('open_generation_context',
        {'targetRef': target['targetRef']}))['contextRef'] as String;
  }

  Future<List<dynamic>> choices(String context) async => _data(await client
          .call('open_generation_context', {'contextRef': context}))['items']
      as List;

  Future<String> select(String context, List<dynamic> refs) async =>
      _data(await client.call('open_generation_context',
          {'contextRef': context, 'fileRefs': refs}))['contextRef'] as String;

  Future<String> selected() async {
    final context = await parent();
    final items = await choices(context);
    return select(context, [(items.first as Map)['fileRef']]);
  }

  Future<Map<String, dynamic>> retrieve(String context,
          {String query = 'needle', int limit = 8}) =>
      client.call('retrieve_file_content',
          {'contextRef': context, 'query': query, 'limit': limit});

  Future<Map<String, dynamic>> passage(String context, String ref,
          {String? cursor}) =>
      client.call('get_file_passage', {
        'contextRef': context,
        'passageRef': ref,
        if (cursor != null) 'cursor': cursor
      });

  Future<String> anchor(String context) async =>
      (_data(await retrieve(context))['items'] as List).single['passageRef']
          as String;

  void safePage(Map<String, dynamic> page) {
    expect(page.keys.toSet(), {
      'items',
      'nextCursor',
      'hasMore',
      'unsupportedExcluded',
      'startsAtDocumentBeginning'
    });
    expect(utf8.encode(jsonEncode(page)).length, lessThanOrEqualTo(24000));
    for (final item in page['items'] as List) {
      expect(utf8.encode(item['content'] as String).length,
          lessThanOrEqualTo(6000));
    }
    final encoded = jsonEncode(page);
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
      app.files.managed.path
    ]) {
      expect(encoded, isNot(contains(forbidden)));
    }
  }

  test(
      'installed Codex: explicit File selection, verified F1/FTS5 and bounded passages',
      () async {
    final h = app.files;
    final original = await parent();
    final items = await choices(original);
    expect(items, hasLength(2));
    for (final item in items) {
      expect((item as Map).keys.toSet(), {'fileRef', 'selectionOrdinal'});
    }
    final context = await select(original, [items.first['fileRef']]);
    expect(context, isNot(original));
    _denied(await retrieve(original)); // Parent was never upgraded.
    expect(await h.s.h.count('retrieval_index_builds'), 0);
    final page = _data(await retrieve(context, limit: 1));
    safePage(page);
    expect(page['items'], hasLength(1));
    expect(page['items'].single['content'], 'needle file-a');
    expect(page['items'].single.keys.toSet(), {
      'passageRef',
      'content',
      'contentKind',
      'locator',
      'chunkOrdinal',
      'partOrdinal',
      'windowOrdinal',
      'pageNumber'
    });
    expect(page['nextCursor'], isNull);
    expect(page['hasMore'], isFalse);
    expect(page['startsAtDocumentBeginning'], isFalse);
    expect(page['unsupportedExcluded'], isTrue);
    final artifact = (await h.metadata.findCurrentByFileId('file-a'))!;
    final build = (await h.s.h.db.query('retrieval_index_builds')).single;
    expect(build['file_id'], 'file-a');
    expect(build['artifact_id'], artifact.artifactId);
    expect(build['revision'], artifact.revision);
    expect(build['payload_digest'], artifact.payloadSha256);
    expect(h.index.searched.toSet(), {'file-a'});
    expect(h.observed.reads, greaterThan(0));
    expect(
        _data(await retrieve(context, query: 'absenttoken'))['items'], isEmpty);
    final ref = page['items'].single['passageRef'] as String;
    var read = _data(await passage(context, ref));
    safePage(read);
    expect(read['items'], hasLength(8));
    expect(read['startsAtDocumentBeginning'], isTrue);
    expect(read['unsupportedExcluded'], isTrue);
    expect(read['hasMore'], isTrue);
    final chunks = [...read['items'] as List];
    read = _data(
        await passage(context, ref, cursor: read['nextCursor'] as String));
    safePage(read);
    chunks.addAll(read['items'] as List);
    expect(read['startsAtDocumentBeginning'], isFalse);
    expect(read['hasMore'], isFalse);
    expect(read['nextCursor'], isNull);
    expect(read['unsupportedExcluded'], isTrue);
    expect(chunks.map((i) => i['partOrdinal']), List.generate(14, (i) => i));
    expect(chunks[10]['content'], r'\[x^2\]');
    expect(chunks[12]['content'], 'r1c1: table value');
    expect(chunks[13]['content'], 'safe alt');
    final tail = _data(await retrieve(context, query: 'tail'));
    read = _data(
        await passage(context, tail['items'].single['passageRef'] as String));
    expect(read['items'].first['partOrdinal'], 11);
    expect(read['startsAtDocumentBeginning'], isFalse);
    expect(read['hasMore'], isFalse);
    expect(h.generation.calls, 2, reason: 'External reads must never parse.');
    expect(await h.s.h.count('generated_question_proposals'), 0);
    expect(await h.s.h.count('questions'), 1);
  }, skip: skip, timeout: const Timeout(Duration(minutes: 2)));

  test(
      'installed Codex: forged and cross-Context File/Passage/cursor refs deny bodies',
      () async {
    final a = await parent(), b = await parent();
    final selection = (await choices(a)).first['fileRef'];
    _denied(await client.call('open_generation_context', {
      'contextRef': b,
      'fileRefs': [selection]
    }));
    _denied(await client.call('open_generation_context', {
      'contextRef': a,
      'fileRefs': ['A' * 43]
    }));
    final context = await select(a, [selection]);
    final ref = await anchor(context);
    final cursor = _data(await passage(context, ref))['nextCursor'] as String;
    _denied(await passage(context, 'A' * 43));
    _denied(await passage(context, ref, cursor: 'A' * 43));
    _denied(await passage(b, ref, cursor: cursor));
    final other = await selected();
    _denied(await passage(other, ref, cursor: cursor));
    final freshAnchor = await anchor(context);
    _denied(await passage(context, freshAnchor, cursor: cursor));
    expect(_data(await passage(context, ref, cursor: cursor))['items'],
        isNotEmpty);
  }, skip: skip, timeout: const Timeout(Duration(minutes: 2)));

  test(
      'installed Codex: Question READ/STAGE need independent File scope and fileContent',
      () async {
    final h = app.files;
    await h.grant(scopes: [
      h.bank
    ], categories: [
      ExternalContentCategory.questionContent,
      ExternalContentCategory.proposalMetadata
    ]);
    var context = await parent();
    final questions = _data(await client.call('search_questions',
        {'contextRef': context, 'query': 'needle'}))['items'] as List;
    expect(questions, hasLength(1));
    _data(await client.call('get_question_detail', {
      'contextRef': context,
      'questionRef': questions.single['questionRef']
    }));
    _denied(
        await client.call('open_generation_context', {'contextRef': context}));
    await h
        .grant(scopes: [h.bank]); // Even fileContent needs an exact File scope.
    context = await parent();
    _denied(
        await client.call('open_generation_context', {'contextRef': context}));
    await h.grant(categories: [ExternalContentCategory.questionContent]);
    context = await parent();
    _denied(
        await client.call('open_generation_context', {'contextRef': context}));
    await h.s.management.replaceGrant(
        h.s.profile,
        h.revision,
        h.s.policy(permissions: [
          CapabilityPermission.read
        ], scopes: [
          h.bank,
          h.file('file-a')
        ], categories: [
          ExternalContentCategory.questionContent,
          ExternalContentCategory.fileContent
        ]));
    context = await selected();
    expect(_data(await retrieve(context))['items'], isNotEmpty);
    expect(
        _data(await client.call('search_questions',
            {'contextRef': context, 'query': 'needle'}))['items'],
        hasLength(1));
    // The composition supplies no App target approval, so the unchanged approval
    // gate denies staging before the separate STAGE-permission path.
    _denied(await client.call(
        'propose_generated_questions', batch(context, 'file-only')));
    // File READ never creates the independent parent Question READ authority.
    // P4 discovery remains denied when questionContent is removed, even though
    // exact File scope + fileContent are present. Do not change that contract.
    await h.s.management.replaceGrant(
        h.s.profile,
        h.revision + 1,
        h.s.policy(
            permissions: [CapabilityPermission.read],
            scopes: [h.bank, h.file('file-a')],
            categories: [ExternalContentCategory.fileContent]));
    _denied(await client.call('open_generation_context'));
    _denied(await retrieve(context));
    expect(await h.s.h.count('generated_question_proposals'), 0);
  }, skip: skip, timeout: const Timeout(Duration(minutes: 2)));

  test(
      'installed Codex: exact Project scope excludes even a related File in another Project',
      () async {
    final h = app.files;
    await h.s.h.db.insert('projects', {
      'project_id': 'other',
      'display_name': 'Other synthetic',
      'created_at': 1
    });
    await h.s.h.db
        .insert('project_files', {'project_id': 'other', 'file_id': 'file-b'});
    await h.grant(scopes: [h.bank, h.file('file-b', space: 'other')]);
    final context = await parent();
    _denied(
        await client.call('open_generation_context', {'contextRef': context}));
    _denied(await retrieve(context));
    expect(h.observed.reads, 0);
    expect(h.index.searched, isEmpty);
  }, skip: skip, timeout: const Timeout(Duration(minutes: 2)));

  for (final change in [
    'expiry',
    'revoke',
    'narrow',
    'detach',
    'reparse',
    'digest',
    'corrupt'
  ]) {
    test(
        'installed Codex: $change invalidates selected Context, Passage and cursor',
        () async {
      final h = app.files;
      final context = await selected();
      final ref = await anchor(context);
      final cursor = _data(await passage(context, ref))['nextCursor'] as String;
      switch (change) {
        case 'expiry':
          h.s.clock.current =
              h.s.clock.current.add(const Duration(minutes: 15));
        case 'revoke':
          await h.s.management.revokeGrant(h.s.profile, h.revision);
        case 'narrow':
          await h.grant(scopes: [h.bank, h.file('file-b')]);
        case 'detach':
          await h.s.h.db.delete('project_files',
              where: 'project_id=? AND file_id=?',
              whereArgs: [h.project, 'file-a']);
        case 'reparse':
          final before = (await h.metadata.findCurrentByFileId('file-a'))!;
          await h.lifecycle.reparseArtifact(
              fileId: 'file-a',
              options: FileReadHarness.options,
              expectedRevision: before.revision);
          final after = (await h.metadata.findCurrentByFileId('file-a'))!;
          expect(after.artifactId, isNot(before.artifactId));
          expect(after.revision, before.revision + 1);
        case 'digest':
          await h.s.h.db.update('library_files', {'sha256': 'b' * 64},
              where: 'file_id=?', whereArgs: ['file-a']);
        case 'corrupt':
          final artifact = (await h.metadata.findCurrentByFileId('file-a'))!;
          await File(p.join(h.managed.path, artifact.storageKey))
              .writeAsString('corrupt');
      }
      _denied(await retrieve(context));
      _denied(await passage(context, ref));
      _denied(await passage(context, ref, cursor: cursor));
      if (change == 'reparse') {
        final fresh = await selected();
        _denied(await passage(fresh, ref, cursor: cursor));
        expect(_data(await retrieve(fresh))['items'], isNotEmpty);
      }
    }, skip: skip, timeout: const Timeout(Duration(minutes: 2)));
  }

  test('installed Codex: revoke after actual FTS suppresses final release',
      () async {
    final h = app.files;
    final context = await selected();
    h.index.afterSearch =
        () => h.s.management.revokeGrant(h.s.profile, h.revision);
    _denied(await retrieve(context));
    expect(h.index.searched, ['file-a']);
    expect(await h.s.h.count('retrieval_index_builds'), 1);
  }, skip: skip, timeout: const Timeout(Duration(minutes: 2)));

  test(
      'installed Codex: EOF, database reopen and fresh Session never renew old refs',
      () async {
    final context = await selected();
    final ref = await anchor(context);
    final cursor = _data(await passage(context, ref))['nextCursor'] as String;
    await client.disconnect();
    await app.restart();
    await client.connect();
    _denied(await retrieve(context));
    _denied(await passage(context, ref, cursor: cursor));
    final fresh = await selected();
    _denied(await passage(fresh, ref, cursor: cursor));
    expect(_data(await retrieve(fresh))['items'], isNotEmpty);
  }, skip: skip, timeout: const Timeout(Duration(minutes: 2)));
}
