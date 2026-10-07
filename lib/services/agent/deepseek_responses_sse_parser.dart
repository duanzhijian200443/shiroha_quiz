import 'dart:async';
import 'dart:convert';

import '../../application/agent/agent_provider.dart';

final class DeepSeekResponsesSseParser {
  const DeepSeekResponsesSseParser();

  Stream<AgentProviderEvent> parse(
    Stream<List<int>> source, {
    void Function(Map<String, Object?> item)? onContinuationItem,
  }) async* {
    final decoder = _ResponsesEventDecoder(onContinuationItem);
    String? eventName;
    final dataLines = <String>[];

    try {
      await for (final line
          in source.transform(utf8.decoder).transform(const LineSplitter())) {
        if (line.isEmpty) {
          final events = decoder.decode(eventName, dataLines);
          eventName = null;
          dataLines.clear();
          for (final event in events) {
            yield event;
          }
          continue;
        }
        if (line.startsWith(':')) continue;

        final separator = line.indexOf(':');
        final field = separator < 0 ? line : line.substring(0, separator);
        var value = separator < 0 ? '' : line.substring(separator + 1);
        if (value.startsWith(' ')) value = value.substring(1);
        switch (field) {
          case 'event':
            // SSE permits repeated/empty event fields; the last value wins and
            // an empty value restores the default event type.
            eventName = value.isEmpty ? null : value;
          case 'data':
            dataLines.add(value);
          case 'id':
          case 'retry':
            break;
          default:
            // Unknown extension fields are ignored by SSE parsers. Payload
            // validation below remains strict once data is decoded.
            break;
        }
      }

      if (eventName != null || dataLines.isNotEmpty) {
        for (final event in decoder.decode(eventName, dataLines)) {
          yield event;
        }
      }
      if (decoder.pendingFailure case final failure?) throw failure;
      if (!decoder.terminalSeen) {
        throw const AgentProviderException.detailed(
          ProviderFailureCode.cleanEofWithoutTerminal,
        );
      }
    } on AgentProviderException {
      rethrow;
    } on FormatException {
      throw AgentProviderException.detailed(
        ProviderFailureCode.malformedEvent,
        terminalSeen: decoder.terminalSeen,
      );
    }
  }
}

final class _ResponsesEventDecoder {
  _ResponsesEventDecoder(this._onContinuationItem);

  final void Function(Map<String, Object?> item)? _onContinuationItem;
  final Map<String, _FunctionCallAccumulator> _functionCalls =
      <String, _FunctionCallAccumulator>{};
  bool terminalSeen = false;
  AgentProviderException? pendingFailure;
  final Set<String> _emittedCallIds = <String>{};
  final Map<String, AgentProviderFunctionCall> _emittedCalls = {};
  final Set<String> _continuationItemKeys = {};
  final Set<AgentProviderWebSearchPhase> _emittedWebPhases =
      <AgentProviderWebSearchPhase>{};

  List<AgentProviderEvent> decode(String? eventName, List<String> dataLines) {
    if (dataLines.isEmpty) {
      if (eventName != null) return _malformed();
      return const <AgentProviderEvent>[];
    }
    final data = dataLines.join('\n');
    if (data == '[DONE]') return const <AgentProviderEvent>[];
    if (_isHiddenType(eventName)) return const <AgentProviderEvent>[];

    try {
      final decoded = jsonDecode(data);
      if (decoded is! Map<String, dynamic>) return _malformed();
      final payloadType = decoded['type'];
      final type =
          eventName == null || eventName.isEmpty || eventName == 'message'
              ? payloadType
              : eventName;
      if (type is! String || type.isEmpty) return _malformed();
      if (payloadType != null && payloadType != type) return _malformed();
      final isTerminal = const {
        'response.completed',
        'response.incomplete',
        'response.failed',
        'error'
      }.contains(type);
      if (terminalSeen) {
        throw AgentProviderException.detailed(
          isTerminal
              ? ProviderFailureCode.duplicateTerminal
              : ProviderFailureCode.malformedEvent,
          terminalSeen: true,
        );
      }
      if (isTerminal) terminalSeen = true;
      if (_isHiddenType(type)) return const <AgentProviderEvent>[];

      return switch (type) {
        'response.output_text.delta' => _textDelta(decoded),
        'response.output_item.added' => _outputItemAdded(decoded),
        'response.function_call_arguments.delta' => _functionArgumentsDelta(
            decoded,
          ),
        'response.function_call_arguments.done' => _functionArgumentsDone(
            decoded,
          ),
        'response.output_item.done' => _outputItemDone(decoded),
        'response.web_search_call.in_progress' ||
        'response.web_search_call.searching' =>
          _webSearchPhase(AgentProviderWebSearchPhase.searching),
        'response.web_search_call.completed' =>
          _webSearchPhase(AgentProviderWebSearchPhase.completed),
        'response.completed' => _completed(decoded),
        'response.incomplete' => _incomplete(decoded),
        'response.failed' || 'error' => _providerFailure(decoded),
        _ => const <AgentProviderEvent>[],
      };
    } on AgentProviderException {
      rethrow;
    } on FormatException {
      return _malformed();
    }
  }

  List<AgentProviderEvent> _textDelta(Map<String, dynamic> payload) {
    final delta = payload['delta'];
    if (delta is! String || delta.isEmpty) return _malformed();
    return <AgentProviderEvent>[AgentProviderTextDelta(delta)];
  }

  List<AgentProviderEvent> _outputItemAdded(Map<String, dynamic> payload) {
    final item = payload['item'];
    if (item is! Map<String, dynamic>) return _invalidItem();
    final itemType = item['type'];
    if (_isHiddenType(itemType)) return const <AgentProviderEvent>[];
    if (itemType == 'web_search_call') {
      return _webSearchPhase(AgentProviderWebSearchPhase.searching);
    }
    if (itemType == 'message') return const <AgentProviderEvent>[];
    if (itemType != 'function_call') return _invalidItem();

    final key = _eventKey(payload, item);
    if (key == null) return _invalidItem();
    final accumulator = _functionCalls.putIfAbsent(
      key,
      _FunctionCallAccumulator.new,
    );
    if (!_captureFunctionMetadata(accumulator, item)) return _invalidItem();
    return const <AgentProviderEvent>[];
  }

  List<AgentProviderEvent> _functionArgumentsDelta(
    Map<String, dynamic> payload,
  ) {
    final key = _eventKey(payload, null);
    final delta = payload['delta'];
    if (key == null || delta is! String) return _invalidItem();
    final accumulator = _functionCalls[key];
    if (accumulator == null) return _invalidItem();
    accumulator.arguments.write(delta);
    return const <AgentProviderEvent>[];
  }

  List<AgentProviderEvent> _functionArgumentsDone(
    Map<String, dynamic> payload,
  ) {
    final key = _eventKey(payload, null);
    if (key == null) return _invalidItem();
    final accumulator = _functionCalls[key];
    if (accumulator == null) return _invalidItem();
    final arguments = payload['arguments'];
    if (arguments is String) {
      accumulator.arguments
        ..clear()
        ..write(arguments);
    } else if (arguments != null) {
      return _invalidItem();
    }
    return _emitFunctionCall(accumulator);
  }

  List<AgentProviderEvent> _outputItemDone(Map<String, dynamic> payload) {
    final item = payload['item'];
    if (item is! Map<String, dynamic>) return _invalidItem();
    final itemType = item['type'];
    _captureContinuationItem(item);
    if (_isHiddenType(itemType)) return const <AgentProviderEvent>[];
    if (itemType == 'web_search_call') {
      return _webSearchPhase(AgentProviderWebSearchPhase.completed);
    }
    if (itemType == 'message') return const <AgentProviderEvent>[];
    if (itemType != 'function_call') return _invalidItem();

    final key = _eventKey(payload, item);
    if (key == null) return _invalidItem();
    final accumulator = _functionCalls.putIfAbsent(
      key,
      _FunctionCallAccumulator.new,
    );
    if (!_captureFunctionMetadata(accumulator, item)) return _invalidItem();
    final arguments = item['arguments'];
    if (arguments is String) {
      accumulator.arguments
        ..clear()
        ..write(arguments);
    } else if (arguments != null) {
      return _invalidItem();
    }
    return _emitFunctionCall(accumulator);
  }

  bool _captureFunctionMetadata(
    _FunctionCallAccumulator accumulator,
    Map<String, dynamic> item,
  ) {
    final callId = item['call_id'];
    final name = item['name'];
    if (callId is! String || name is! String) return false;
    if ((accumulator.callId != null && accumulator.callId != callId) ||
        (accumulator.name != null && accumulator.name != name)) {
      return false;
    }
    accumulator
      ..callId = callId
      ..name = name;
    final arguments = item['arguments'];
    if (arguments is String && arguments.isNotEmpty) {
      accumulator.arguments
        ..clear()
        ..write(arguments);
    }
    return true;
  }

  List<AgentProviderEvent> _emitFunctionCall(
    _FunctionCallAccumulator accumulator,
  ) {
    final callId = accumulator.callId;
    final name = accumulator.name;
    final arguments = accumulator.arguments.toString();
    if (callId == null || name == null || arguments.isEmpty) {
      return _invalidItem();
    }
    final Object? decodedArguments;
    try {
      decodedArguments = jsonDecode(arguments);
    } on FormatException {
      return _invalidItem();
    }
    if (decodedArguments is! Map<String, dynamic>) return _invalidItem();
    final existing = _emittedCalls[callId];
    if (existing != null) {
      if (existing.name != name || existing.argumentsJson != arguments) {
        return _invalidItem();
      }
      return const [];
    }
    final AgentProviderFunctionCall call;
    try {
      call = AgentProviderFunctionCall(
        callId: callId,
        name: name,
        argumentsJson: arguments,
      );
    } on AgentProviderException {
      return _invalidItem();
    }
    _emittedCallIds.add(callId);
    _emittedCalls[callId] = call;
    return [call];
  }

  List<AgentProviderEvent> _completed(Map<String, dynamic> payload) {
    final response = payload['response'];
    final responseId = response is Map<String, dynamic>
        ? response['id']
        : payload['response_id'] ?? payload['id'];
    if (responseId is! String) return _malformed();
    final events = <AgentProviderEvent>[];
    if (response is Map<String, dynamic> && response.containsKey('output')) {
      final output = response['output'];
      if (output is! List) return _invalidItem();
      for (var index = 0; index < output.length; index++) {
        events.addAll(
            _outputItemDone({'item': output[index], 'output_index': index}));
      }
    }
    if (_functionCalls.values
        .any((call) => !_emittedCallIds.contains(call.callId))) {
      return _invalidItem();
    }
    try {
      events.add(AgentProviderCompleted(responseId));
    } on AgentProviderException {
      return _malformed();
    }
    return events;
  }

  List<AgentProviderEvent> _incomplete(Map<String, dynamic> payload) {
    final response = payload['response'];
    final details = response is Map<String, dynamic>
        ? response['incomplete_details']
        : null;
    final reason = details is Map<String, dynamic> ? details['reason'] : null;
    pendingFailure = AgentProviderException.detailed(
      reason == 'max_output_tokens'
          ? ProviderFailureCode.maxOutputTokens
          : ProviderFailureCode.incompleteUnknown,
      terminalSeen: true,
    );
    return [AgentProviderFailureTerminal(pendingFailure!)];
  }

  void _captureContinuationItem(Map<String, dynamic> item) {
    final itemType = item['type'];
    final identity =
        item['id'] ?? (itemType == 'function_call' ? item['call_id'] : null);
    final key = identity is String && identity.isNotEmpty
        ? 'id:$identity'
        : 'value:${_stableJson(item)}';
    if (!_continuationItemKeys.add(key)) return;
    if (itemType == 'reasoning' ||
        itemType == 'function_call' ||
        itemType == 'web_search_call' ||
        itemType == 'message') {
      _onContinuationItem?.call(Map<String, Object?>.from(item));
    }
  }

  String _stableJson(Object? value) {
    if (value is Map) {
      final keys = value.keys.whereType<String>().toList()..sort();
      return '{${keys.map((key) => '${jsonEncode(key)}:${_stableJson(value[key])}').join(',')}}';
    }
    if (value is List) {
      return '[${value.map(_stableJson).join(',')}]';
    }
    return jsonEncode(value);
  }

  List<AgentProviderEvent> _webSearchPhase(
    AgentProviderWebSearchPhase phase,
  ) {
    if (!_emittedWebPhases.add(phase)) return const <AgentProviderEvent>[];
    return <AgentProviderEvent>[AgentProviderWebSearchEvent(phase)];
  }

  List<AgentProviderEvent> _providerFailure(Map<String, dynamic> payload) {
    Object? error = payload['error'];
    final response = payload['response'];
    if (error == null && response is Map<String, dynamic>) {
      error = response['error'];
    }
    final code = error is Map<String, dynamic> ? error['code'] : null;
    final normalized = code is String ? code.toLowerCase() : '';
    final ProviderFailureCode detail;
    if (normalized.contains('content_filter')) {
      detail = ProviderFailureCode.contentFiltered;
    } else if (normalized.contains('auth') ||
        normalized.contains('api_key') ||
        normalized.contains('unauthorized')) {
      detail = ProviderFailureCode.authentication;
    } else if (normalized.contains('rate')) {
      detail = ProviderFailureCode.rateLimited;
    } else if (normalized.contains('timeout')) {
      detail = ProviderFailureCode.streamTimeout;
    } else {
      detail = ProviderFailureCode.temporarilyUnavailable;
    }
    final failure = switch (detail) {
      ProviderFailureCode.authentication => AgentProviderFailure.authentication,
      ProviderFailureCode.rateLimited => AgentProviderFailure.rateLimited,
      ProviderFailureCode.streamTimeout => AgentProviderFailure.timeout,
      ProviderFailureCode.contentFiltered ||
      ProviderFailureCode.temporarilyUnavailable =>
        AgentProviderFailure.temporarilyUnavailable,
      _ => AgentProviderFailure.temporarilyUnavailable,
    };
    pendingFailure = AgentProviderException.detailed(detail,
        legacyFailure: failure, terminalSeen: true);
    return [AgentProviderFailureTerminal(pendingFailure!)];
  }

  String? _eventKey(Map<String, dynamic> payload, Map<String, dynamic>? item) {
    final itemId = payload['item_id'] ?? item?['id'];
    if (itemId is String && itemId.isNotEmpty) return 'item:$itemId';
    final outputIndex = payload['output_index'];
    if (outputIndex is int && outputIndex >= 0) return 'index:$outputIndex';
    return null;
  }

  bool _isHiddenType(Object? type) {
    if (type is! String) return false;
    final normalized = type.toLowerCase();
    return normalized.contains('reasoning') || normalized.contains('thinking');
  }

  Never _invalidItem() {
    throw AgentProviderException.detailed(ProviderFailureCode.invalidOutputItem,
        terminalSeen: terminalSeen);
  }

  Never _malformed() {
    throw AgentProviderException.detailed(ProviderFailureCode.malformedEvent,
        terminalSeen: terminalSeen);
  }
}

final class _FunctionCallAccumulator {
  String? callId;
  String? name;
  final StringBuffer arguments = StringBuffer();
}
