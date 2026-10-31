part of 'ipc_command_projection.dart';

enum _Command {
  openStudyContext('external_open_study_context'),
  listStudyBanks('external_list_study_banks'),
  studyOverview('external_study_overview'),
  dueReviewSummary('external_due_review_summary'),
  weakQuestions('external_weak_questions'),
  listTargets('external_list_targets'),
  createReadContext('external_create_read_context'),
  searchQuestions('external_search_questions'),
  getQuestionDetail('external_get_question_detail'),
  listFileSelections('external_list_file_selections'),
  createFileContext('external_create_file_context'),
  retrieveFileContent('external_retrieve_file_content'),
  getFilePassage('external_get_file_passage'),
  stage('external_stage_generated_questions'),
  reconcile('external_reconcile_generated_stage'),
  proposalLifecycle('external_get_proposal_lifecycle');

  const _Command(this.wireName);
  final String wireName;
  bool get study => index < 5;
  int get version => study
      ? 4
      : this == proposalLifecycle
          ? 2
          : 1;
  static _Command parse(Object? value) =>
      values.firstWhere((command) => command.wireName == value,
          orElse: () => _bad(IpcCommandFailure.unsupportedCapability));
}

Never _bad([IpcCommandFailure failure = IpcCommandFailure.invalidRequest]) =>
    throw IpcCommandSchemaException(failure);

Map<String, Object?> _object(Object? value, List<String> keys) {
  if (value is! Map ||
      value.length != keys.length ||
      keys.any((key) => !value.containsKey(key)) ||
      value.keys.any((key) => key is! String)) {
    _bad();
  }
  return Map<String, Object?>.from(value);
}

List<Object?> _list(Object? value, int max, {int min = 0}) {
  if (value is! List || value.length < min || value.length > max) _bad();
  return List<Object?>.from(value);
}

int _integer(Object? value, int min, int max) {
  if (value is! int || value < min || value > max) _bad();
  return value;
}

String _text(Object? value, int max, {bool nonblank = false}) {
  if (value is! String || value.length > max) _bad();
  // jsonDecode admits escaped unpaired surrogates; never replace them silently.
  for (var i = 0; i < value.length; i++) {
    final unit = value.codeUnitAt(i);
    if (unit >= 0xd800 && unit <= 0xdbff) {
      if (++i >= value.length ||
          value.codeUnitAt(i) < 0xdc00 ||
          value.codeUnitAt(i) > 0xdfff) {
        _bad();
      }
    } else if (unit >= 0xdc00 && unit <= 0xdfff) {
      _bad();
    }
  }
  if (nonblank && value.trim().isEmpty) _bad();
  return value;
}

String _ref(Object? value) {
  final text = _text(value, 43);
  if (!RegExp(r'^[A-Za-z0-9_-]{43}$').hasMatch(text)) _bad();
  return text;
}

String? _cursor(Object? value) => value == null ? null : _ref(value);

String _enum(Object? value, List<String> values) {
  if (value is! String || !values.contains(value)) _bad();
  return value;
}

void _boolean(Object? value) {
  if (value is! bool) _bad();
}

Object? _decodeJson(String text, int maxBytes) {
  try {
    return generatedDecode(text, maxBytes: maxBytes);
  } on GeneratedQuestionException {
    _bad();
  }
}

final class _CommandRequest {
  const _CommandRequest(this.command, this.input, this.version, this.selection);
  final _Command command;
  final Object input;
  final int version;
  final IpcContextSelection? selection;
  static _CommandRequest decode(UntrustedIpcEnvelope envelope,
      {required bool selected, int selectedVersion = 3}) {
    if (envelope.kind != IpcMessageKind.request) _bad();
    final root = _object(
        _decodeJson(envelope.payload, IpcEnvelopeLimits.requestBytes),
        ['schemaVersion', 'type', 'capability', 'input']);
    if (root['schemaVersion'] is! int ||
        ![1, 2, 3, 4].contains(root['schemaVersion'])) {
      _bad(IpcCommandFailure.unsupportedVersion);
    }
    if (root['type'] != 'command') _bad();
    final command = _Command.parse(root['capability']);
    final version = root['schemaVersion']! as int;
    if ((version == 4 && !selected) ||
        (command.study && version != 4) ||
        (selected ? version != selectedVersion : version != command.version)) {
      _bad(IpcCommandFailure.unsupportedVersion);
    }
    var rawInput = root['input'];
    IpcContextSelection? selection;
    if (version == 3 || version == 4) {
      final kind = switch (command) {
        _Command.listTargets ||
        _Command.createReadContext =>
          IpcContextSelectionKind.rootRead,
        _Command.openStudyContext => IpcContextSelectionKind.rootStudy,
        _Command.listStudyBanks ||
        _Command.studyOverview ||
        _Command.dueReviewSummary ||
        _Command.weakQuestions =>
          IpcContextSelectionKind.study,
        _Command.getQuestionDetail when version == 4 =>
          IpcContextSelectionKind.questionRead,
        _Command.stage => IpcContextSelectionKind.stage,
        _Command.reconcile => IpcContextSelectionKind.reconciliation,
        _Command.proposalLifecycle => IpcContextSelectionKind.proposalLifecycle,
        _ => IpcContextSelectionKind.read,
      };
      if (kind == IpcContextSelectionKind.rootRead ||
          kind == IpcContextSelectionKind.rootStudy) {
        selection = IpcContextSelection._(kind);
      } else {
        if (rawInput is! Map) _bad();
        final values = Map<String, Object?>.from(rawInput);
        if (kind == IpcContextSelectionKind.read ||
            kind == IpcContextSelectionKind.stage ||
            kind == IpcContextSelectionKind.study ||
            kind == IpcContextSelectionKind.questionRead) {
          // Missing and explicit null both reject; never substitute a Context.
          selection = IpcContextSelection._(kind,
              contextRef: _ref(values.remove('contextRef')),
              questionRef: kind == IpcContextSelectionKind.questionRead
                  ? _ref(values['questionRef'])
                  : null);
        } else {
          final key = _text(values.remove('submissionKey'), 64, nonblank: true);
          if (!RegExp(r'^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$').hasMatch(key)) {
            _bad();
          }
          selection = IpcContextSelection._(kind, submissionKey: key);
        }
        rawInput = values;
      }
    }
    Object input;
    switch (command) {
      case _Command.openStudyContext:
        final m = _object(rawInput, ['targetRef']);
        input = ExternalStudySelection(
            m['targetRef'] == null ? null : _ref(m['targetRef']));
      case _Command.listStudyBanks || _Command.weakQuestions:
        final m = _object(rawInput, ['pageSize', 'cursor']);
        input = ExternalStudyQuery(
            pageSize: _integer(m['pageSize'], 1, 50),
            cursor: _cursor(m['cursor']));
      case _Command.studyOverview:
        final m = _object(rawInput, ['timezone']);
        input = ExternalStudyQuery(
            timezone: m['timezone'] == null
                ? null
                : _text(m['timezone'], 64, nonblank: true));
      case _Command.dueReviewSummary:
        final m = _object(rawInput, ['timezone', 'from', 'to']);
        DateTime date(Object? value) {
          final text = _text(value, 40, nonblank: true);
          final match = RegExp(
                  r'^(\d{4})-(\d{2})-(\d{2})T(\d{2}):(\d{2}):(\d{2})(?:\.\d{1,6})?(Z|[+-]\d{2}:\d{2})$')
              .firstMatch(text);
          if (match == null) _bad();
          int part(int index) => int.parse(match.group(index)!);
          final date = DateTime.utc(part(1), part(2), part(3));
          final offset = match.group(7)!;
          if (date.year != part(1) ||
              date.month != part(2) ||
              date.day != part(3) ||
              part(4) > 23 ||
              part(5) > 59 ||
              part(6) > 59 ||
              offset != 'Z' &&
                  (int.parse(offset.substring(1, 3)) > 23 ||
                      int.parse(offset.substring(4, 6)) > 59)) {
            _bad();
          }
          final result = DateTime.tryParse(text);
          if (result == null) _bad();
          return result.toUtc();
        }
        final from = date(m['from']), to = date(m['to']);
        if (!from.isBefore(to) ||
            to.difference(from) > const Duration(days: 90)) {
          _bad();
        }
        input = ExternalStudyQuery(
            timezone: m['timezone'] == null
                ? null
                : _text(m['timezone'], 64, nonblank: true),
            from: from,
            to: to);
      case _Command.listTargets:
        final m = _object(rawInput, ['pageSize', 'cursor']);
        input = ExternalTargetQuery(
            pageSize: _integer(m['pageSize'], 1, 50),
            cursor: _cursor(m['cursor']));
      case _Command.createReadContext:
        final m = _object(rawInput, ['targetRef']);
        input = ExternalTargetSelection(_ref(m['targetRef']));
      case _Command.searchQuestions:
        final m = _object(rawInput, ['query', 'pageSize', 'cursor']);
        input = ExternalQuestionQuery(_text(m['query'], 200, nonblank: true),
            pageSize: _integer(m['pageSize'], 1, 50),
            cursor: _cursor(m['cursor']));
      case _Command.getQuestionDetail:
        final m = _object(rawInput, ['questionRef']);
        input = ExternalQuestionSelection(_ref(m['questionRef']));
      case _Command.listFileSelections:
        final m = rawInput is Map && rawInput.isEmpty
            ? <String, Object?>{'pageSize': 20, 'cursor': null}
            : _object(rawInput, ['pageSize', 'cursor']);
        input = ExternalTargetQuery(
            pageSize: _integer(m['pageSize'], 1, 50),
            cursor: _cursor(m['cursor']));
      case _Command.reconcile || _Command.proposalLifecycle:
        _object(rawInput, []);
        input = const ExternalNoInput();
      case _Command.createFileContext:
        final m = _object(rawInput, ['fileRefs']);
        final refs = _list(m['fileRefs'], 64, min: 1).map(_ref).toList();
        if (refs.toSet().length != refs.length) _bad();
        input = ExternalFileSelections(refs);
      case _Command.retrieveFileContent:
        final m = _object(rawInput, ['query', 'limit']);
        final query = _text(m['query'], 400, nonblank: true);
        if (query.runes.length > 200) _bad();
        input = ExternalFileQuery(query, limit: _integer(m['limit'], 1, 20));
      case _Command.getFilePassage:
        final m = _object(rawInput, ['passageRef', 'cursor']);
        input = ExternalPassageSelection(_ref(m['passageRef']),
            cursor: _cursor(m['cursor']));
      case _Command.stage:
        final m = _object(rawInput, ['submissionJson', 'externalRequestId']);
        final submission =
            _text(m['submissionJson'], GeneratedLimits.submissionBytes);
        if (submission.isEmpty ||
            utf8.encode(submission).length > GeneratedLimits.submissionBytes) {
          _bad();
        }
        final correlation = m['externalRequestId'] == null
            ? null
            : _text(m['externalRequestId'], 128);
        if (correlation != null &&
            !RegExp(r'^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$')
                .hasMatch(correlation)) {
          _bad();
        }
        input =
            ExternalStageSubmission(submission, externalRequestId: correlation);
    }
    return _CommandRequest(command, input, version, selection);
  }
}

/// Client-side offline response validation; it never admits a business call.
abstract final class IpcCommandResponseCodec {
  static const version = 1;
  static Map<String, Object?> decode(UntrustedIpcEnvelope envelope) {
    if (envelope.kind != IpcMessageKind.response) _bad();
    final root = _object(
        _decodeJson(envelope.payload, IpcEnvelopeLimits.responseBytes),
        ['schemaVersion', 'type', 'capability', 'data', 'error']);
    if (root['schemaVersion'] is! int ||
        ![1, 2, 3, 4].contains(root['schemaVersion'])) {
      _bad(IpcCommandFailure.unsupportedVersion);
    }
    if (root['type'] != 'result') _bad();
    final command =
        root['capability'] == null ? null : _Command.parse(root['capability']);
    if (command == null
        ? root['schemaVersion'] != version
        : (command.study && root['schemaVersion'] != 4) ||
            root['schemaVersion'] != 4 &&
                root['schemaVersion'] != 3 &&
                root['schemaVersion'] != command.version) {
      _bad(IpcCommandFailure.unsupportedVersion);
    }
    if (root['error'] == null) {
      if (command == null || root['data'] == null) _bad();
      _validateData(command, root['data']);
    } else {
      if (root['data'] != null || !_safeError(root['error'])) _bad();
    }
    return root;
  }
}

bool _safeError(Object? value) =>
    IpcCommandFailure.values.any((failure) => failure.name == value) ||
    CapabilityFailure.values
        .any((failure) => 'capability.${failure.name}' == value);

const _questionKinds = [
  'single_choice',
  'fill_blank',
  'short_answer',
  'unknown'
];
const _sourceKinds = ['typed', 'legacy'];

int _nodes(Object? value, {bool nullable = false}) {
  if (nullable && value == null) return 0;
  final nodes = _list(value, 512);
  for (final node in nodes) {
    if (node is! Map) _bad();
    switch (node['type']) {
      case 'text':
        _text(_object(node, ['type', 'text'])['text'], 32768);
      case 'inline_math' || 'block_math':
        _text(_object(node, ['type', 'latex'])['latex'], 32768);
      case 'unsupported':
        _object(node, ['type']);
      default:
        _bad();
    }
  }
  return nodes.length;
}

void _validateData(_Command command, Object? value) {
  switch (command) {
    case _Command.proposalLifecycle:
      final m = _object(value, [
        'submissionKey',
        'lifecycleStatus',
        'requestedCount',
        'actualCount',
        'committedCount',
        'rejectedCount'
      ]);
      generatedToken(m['submissionKey']);
      final status = _enum(
          m['lifecycleStatus'], ['pending_review', 'committed', 'rejected']);
      _integer(m['requestedCount'], 1, 50);
      final actual = _integer(m['actualCount'], 1, 50);
      final committed = _integer(m['committedCount'], 0, actual);
      final rejected = _integer(m['rejectedCount'], 0, actual);
      if (status == 'pending_review'
          ? committed != 0 || rejected != 0
          : status == 'rejected'
              ? committed != 0 || rejected != actual
              : committed == 0 || committed + rejected != actual) {
        _bad();
      }
    case _Command.listTargets:
      final page = _object(value, ['items', 'nextCursor']);
      _cursor(page['nextCursor']);
      for (final item in _list(page['items'], 50)) {
        final m =
            _object(item, ['targetRef', 'bankName', 'projectId', 'folderName']);
        _ref(m['targetRef']);
        _text(m['bankName'], 512, nonblank: true);
        if (m['projectId'] != null) _text(m['projectId'], 256, nonblank: true);
        if (m['folderName'] != null) {
          _text(m['folderName'], 512, nonblank: true);
        }
      }
    case _Command.createReadContext ||
          _Command.createFileContext ||
          _Command.openStudyContext:
      _ref(_object(value, ['contextRef'])['contextRef']);
    case _Command.listStudyBanks:
      final page =
          _object(value, ['items', 'nextCursor', 'statisticsAuthorized']);
      _cursor(page['nextCursor']);
      _boolean(page['statisticsAuthorized']);
      for (final raw in _list(page['items'], 50)) {
        final item = _object(raw, [
          'targetRef',
          'bankName',
          'folderName',
          if (page['statisticsAuthorized'] == true) ...[
            'questionCount',
            'dueCount',
            'masteredCount'
          ]
        ]);
        _ref(item['targetRef']);
        _text(item['bankName'], 256, nonblank: true);
        if (item['folderName'] != null) {
          _text(item['folderName'], 256, nonblank: true);
        }
        if (page['statisticsAuthorized'] == true) {
          for (final field in ['questionCount', 'dueCount', 'masteredCount']) {
            _integer(item[field], 0, 9007199254740991);
          }
        }
      }
    case _Command.studyOverview:
      final fields = [
        'questionCount',
        'masteredCount',
        'dueCount',
        'todayPracticeCount',
        'wrongQuestionCount'
      ];
      final result = _object(value, fields);
      for (final field in fields) {
        _integer(result[field], 0, 9007199254740991);
      }
    case _Command.dueReviewSummary:
      final result = _object(value, ['dueNow', 'scheduledCount', 'buckets']);
      _integer(result['dueNow'], 0, 9007199254740991);
      _integer(result['scheduledCount'], 0, 9007199254740991);
      for (final raw in _list(result['buckets'], 92)) {
        final bucket = _object(raw, ['date', 'count']);
        if (!RegExp(r'^\d{4}-\d{2}-\d{2}$')
            .hasMatch(_text(bucket['date'], 10))) {
          _bad();
        }
        _integer(bucket['count'], 0, 9007199254740991);
      }
    case _Command.weakQuestions:
      final result = _object(value, ['items', 'nextCursor']);
      _cursor(result['nextCursor']);
      for (final raw in _list(result['items'], 50)) {
        final item = _object(raw, [
          'questionRef',
          'bankName',
          'stemPreview',
          'lapseCount',
          'difficulty',
          'lastLapseAt'
        ]);
        _ref(item['questionRef']);
        _text(item['bankName'], 256, nonblank: true);
        _text(item['stemPreview'], 32768);
        _integer(item['lapseCount'], 1, 9007199254740991);
        if (item['difficulty'] is! num ||
            !(item['difficulty'] as num).isFinite) {
          _bad();
        }
        if (item['lastLapseAt'] != null &&
            DateTime.tryParse(_text(item['lastLapseAt'], 40)) == null) {
          _bad();
        }
      }
    case _Command.searchQuestions:
      final page = _object(value, ['items', 'nextCursor']);
      _cursor(page['nextCursor']);
      for (final item in _list(page['items'], 50)) {
        final m = _object(item, [
          'questionRef',
          'kind',
          'stemPreview',
          'hasAnswer',
          'hasExplanation',
          'sourceKind'
        ]);
        _ref(m['questionRef']);
        _enum(m['kind'], _questionKinds);
        _text(m['stemPreview'], 32768);
        _boolean(m['hasAnswer']);
        _boolean(m['hasExplanation']);
        _enum(m['sourceKind'], _sourceKinds);
      }
    case _Command.getQuestionDetail:
      final m = _object(value,
          ['kind', 'stem', 'options', 'answer', 'explanation', 'sourceKind']);
      _enum(m['kind'], _questionKinds);
      _enum(m['sourceKind'], _sourceKinds);
      var count = _nodes(m['stem']) +
          _nodes(m['answer'], nullable: true) +
          _nodes(m['explanation'], nullable: true);
      for (final option in _list(m['options'], 26)) {
        final o = _object(option, ['label', 'content']);
        _text(o['label'], 32768);
        count += _nodes(o['content']);
      }
      if (count > 512) _bad();
    case _Command.listFileSelections ||
          _Command.retrieveFileContent ||
          _Command.getFilePassage:
      final page = _object(value, [
        'items',
        'nextCursor',
        'hasMore',
        'unsupportedExcluded',
        'startsAtDocumentBeginning'
      ]);
      _cursor(page['nextCursor']);
      _boolean(page['hasMore']);
      _boolean(page['unsupportedExcluded']);
      _boolean(page['startsAtDocumentBeginning']);
      if (command == _Command.retrieveFileContent &&
          (page['nextCursor'] != null ||
              page['hasMore'] != false ||
              page['startsAtDocumentBeginning'] != false)) {
        _bad();
      }
      if (command == _Command.listFileSelections &&
          page['startsAtDocumentBeginning'] != false) {
        _bad();
      }
      if ((command == _Command.getFilePassage ||
              command == _Command.listFileSelections) &&
          (page['hasMore'] == true) != (page['nextCursor'] != null)) {
        _bad();
      }
      final max = command == _Command.listFileSelections
          ? 64
          : command == _Command.getFilePassage
              ? 8
              : 20;
      for (final item in _list(page['items'], max)) {
        if (command == _Command.listFileSelections) {
          final m = _object(item, ['fileRef', 'selectionOrdinal']);
          _ref(m['fileRef']);
          _integer(m['selectionOrdinal'], 0, 63);
        } else {
          final m = _object(item, [
            if (command == _Command.retrieveFileContent) 'passageRef',
            'content',
            'contentKind',
            'locator',
            'chunkOrdinal',
            'partOrdinal',
            'windowOrdinal',
            'pageNumber'
          ]);
          if (command == _Command.retrieveFileContent) _ref(m['passageRef']);
          _text(m['content'], 6000);
          if (utf8.encode(m['content']! as String).length > 6000) _bad();
          _enum(m['contentKind'], [
            'paragraph',
            'heading',
            'formula',
            'answerLike',
            'table',
            'imageAlt'
          ]);
          _text(m['locator'], 256);
          for (final key in ['chunkOrdinal', 'partOrdinal', 'windowOrdinal']) {
            _integer(m[key], 0, 0x7fffffff);
          }
          if (m['pageNumber'] != null) _integer(m['pageNumber'], 1, 0x7fffffff);
        }
      }
    case _Command.stage || _Command.reconcile:
      final m = _object(value,
          ['proposalId', 'submissionKey', 'publication', 'formalCommit']);
      generatedToken(m['proposalId'], uuid: true);
      generatedToken(m['submissionKey']);
      if (m['publication'] != 'STAGED' || m['formalCommit'] != 'NOT_REPORTED') {
        _bad();
      }
  }
  final file = command == _Command.listFileSelections ||
      command == _Command.retrieveFileContent ||
      command == _Command.getFilePassage;
  if (utf8.encode(jsonEncode(value)).length > (file ? 24000 : 32768)) _bad();
}
