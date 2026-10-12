part of 'ipc_command_projection.dart';

enum _Command {
  listTargets('external_list_targets'),
  createReadContext('external_create_read_context'),
  searchQuestions('external_search_questions'),
  getQuestionDetail('external_get_question_detail'),
  listFileSelections('external_list_file_selections'),
  createFileContext('external_create_file_context'),
  retrieveFileContent('external_retrieve_file_content'),
  getFilePassage('external_get_file_passage'),
  stage('external_stage_generated_questions'),
  reconcile('external_reconcile_generated_stage');

  const _Command(this.wireName);
  final String wireName;
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
  const _CommandRequest(this.command, this.input);
  final _Command command;
  final Object input;
  static _CommandRequest decode(UntrustedIpcEnvelope envelope) {
    if (envelope.kind != IpcMessageKind.request) _bad();
    final root = _object(
        _decodeJson(envelope.payload, IpcEnvelopeLimits.requestBytes),
        ['schemaVersion', 'type', 'capability', 'input']);
    if (root['schemaVersion'] is! int || root['schemaVersion'] != 1) {
      _bad(IpcCommandFailure.unsupportedVersion);
    }
    if (root['type'] != 'command') _bad();
    final command = _Command.parse(root['capability']);
    Object input;
    switch (command) {
      case _Command.listTargets:
        final m = _object(root['input'], ['pageSize', 'cursor']);
        input = ExternalTargetQuery(
            pageSize: _integer(m['pageSize'], 1, 50),
            cursor: _cursor(m['cursor']));
      case _Command.createReadContext:
        final m = _object(root['input'], ['targetRef']);
        input = ExternalTargetSelection(_ref(m['targetRef']));
      case _Command.searchQuestions:
        final m = _object(root['input'], ['query', 'pageSize', 'cursor']);
        input = ExternalQuestionQuery(_text(m['query'], 200, nonblank: true),
            pageSize: _integer(m['pageSize'], 1, 50),
            cursor: _cursor(m['cursor']));
      case _Command.getQuestionDetail:
        final m = _object(root['input'], ['questionRef']);
        input = ExternalQuestionSelection(_ref(m['questionRef']));
      case _Command.listFileSelections || _Command.reconcile:
        _object(root['input'], []);
        input = const ExternalNoInput();
      case _Command.createFileContext:
        final m = _object(root['input'], ['fileRefs']);
        final refs = _list(m['fileRefs'], 64, min: 1).map(_ref).toList();
        if (refs.toSet().length != refs.length) _bad();
        input = ExternalFileSelections(refs);
      case _Command.retrieveFileContent:
        final m = _object(root['input'], ['query', 'limit']);
        final query = _text(m['query'], 400, nonblank: true);
        if (query.runes.length > 200) _bad();
        input = ExternalFileQuery(query, limit: _integer(m['limit'], 1, 20));
      case _Command.getFilePassage:
        final m = _object(root['input'], ['passageRef', 'cursor']);
        input = ExternalPassageSelection(_ref(m['passageRef']),
            cursor: _cursor(m['cursor']));
      case _Command.stage:
        final m =
            _object(root['input'], ['submissionJson', 'externalRequestId']);
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
    return _CommandRequest(command, input);
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
    if (root['schemaVersion'] is! int || root['schemaVersion'] != version) {
      _bad(IpcCommandFailure.unsupportedVersion);
    }
    if (root['type'] != 'result') _bad();
    final command =
        root['capability'] == null ? null : _Command.parse(root['capability']);
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
    case _Command.createReadContext || _Command.createFileContext:
      _ref(_object(value, ['contextRef'])['contextRef']);
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
      if (command != _Command.getFilePassage &&
          (page['nextCursor'] != null ||
              page['hasMore'] != false ||
              page['startsAtDocumentBeginning'] != false)) {
        _bad();
      }
      if (command == _Command.listFileSelections &&
          page['unsupportedExcluded'] != false) {
        _bad();
      }
      if (command == _Command.getFilePassage &&
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
