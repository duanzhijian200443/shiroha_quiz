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
    var completed = false;

    try {
      await for (final line
          in source.transform(utf8.decoder).transform(const LineSplitter())) {
        if (line.isEmpty) {
          final events = decoder.decode(eventName, dataLines);
          eventName = null;
          dataLines.clear();
          for (final event in events) {
            if (event is AgentProviderCompleted) completed = true;
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
            eventName = value;
          case 'data':
            dataLines.add(value);
        }
      }

      if (eventName != null || dataLines.isNotEmpty) {
        for (final event in decoder.decode(eventName, dataLines)) {
          if (event is AgentProviderCompleted) completed = true;
          yield event;
        }
      }
      if (!completed) {
        throw const AgentProviderException(
          AgentProviderFailure.malformedResponse,
        );
      }
    } on AgentProviderException {
      rethrow;
    } catch (_) {
      throw const AgentProviderException(
        AgentProviderFailure.malformedResponse,
      );
    }
  }
}

final class _ResponsesEventDecoder {
  _ResponsesEventDecoder(this._onContinuationItem);

  final void Function(Map<String, Object?> item)? _onContinuationItem;
  final Map<String, _FunctionCallAccumulator> _functionCalls =
      <String, _FunctionCallAccumulator>{};
  final Set<String> _emittedCallIds = <String>{};
  final Set<AgentProviderWebSearchPhase> _emittedWebPhases =
      <AgentProviderWebSearchPhase>{};

  List<AgentProviderEvent> decode(String? eventName, List<String> dataLines) {
    if (dataLines.isEmpty) return const <AgentProviderEvent>[];
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
        'response.incomplete' => _incomplete(),
        'response.failed' || 'error' => _providerFailure(decoded),
        _ => const <AgentProviderEvent>[],
      };
    } on AgentProviderException {
      rethrow;
    } catch (_) {
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
    if (item is! Map<String, dynamic>) return _malformed();
    final itemType = item['type'];
    if (_isHiddenType(itemType)) return const <AgentProviderEvent>[];
    if (itemType == 'web_search_call') {
      return _webSearchPhase(AgentProviderWebSearchPhase.searching);
    }
    if (itemType != 'function_call') return const <AgentProviderEvent>[];

    final key = _eventKey(payload, item);
    if (key == null) return _malformed();
    final accumulator = _functionCalls.putIfAbsent(
      key,
      _FunctionCallAccumulator.new,
    );
    if (!_captureFunctionMetadata(accumulator, item)) return _malformed();
    return const <AgentProviderEvent>[];
  }

  List<AgentProviderEvent> _functionArgumentsDelta(
    Map<String, dynamic> payload,
  ) {
    final key = _eventKey(payload, null);
    final delta = payload['delta'];
    if (key == null || delta is! String) return _malformed();
    final accumulator = _functionCalls[key];
    if (accumulator == null) return _malformed();
    accumulator.arguments.write(delta);
    return const <AgentProviderEvent>[];
  }

  List<AgentProviderEvent> _functionArgumentsDone(
    Map<String, dynamic> payload,
  ) {
    final key = _eventKey(payload, null);
    if (key == null) return _malformed();
    final accumulator = _functionCalls[key];
    if (accumulator == null) return _malformed();
    final arguments = payload['arguments'];
    if (arguments is String) {
      accumulator.arguments
        ..clear()
        ..write(arguments);
    } else if (arguments != null) {
      return _malformed();
    }
    return _emitFunctionCall(accumulator);
  }

  List<AgentProviderEvent> _outputItemDone(Map<String, dynamic> payload) {
    final item = payload['item'];
    if (item is! Map<String, dynamic>) return _malformed();
    final itemType = item['type'];
    _captureContinuationItem(item);
    if (_isHiddenType(itemType)) return const <AgentProviderEvent>[];
    if (itemType == 'web_search_call') {
      return _webSearchPhase(AgentProviderWebSearchPhase.completed);
    }
    if (itemType != 'function_call') return const <AgentProviderEvent>[];

    final key = _eventKey(payload, item);
    if (key == null) return _malformed();
    final accumulator = _functionCalls.putIfAbsent(
      key,
      _FunctionCallAccumulator.new,
    );
    if (!_captureFunctionMetadata(accumulator, item)) return _malformed();
    final arguments = item['arguments'];
    if (arguments is String) {
      accumulator.arguments
        ..clear()
        ..write(arguments);
    } else if (arguments != null) {
      return _malformed();
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
      return _malformed();
    }
    final decodedArguments = jsonDecode(arguments);
    if (decodedArguments is! Map<String, dynamic>) return _malformed();
    if (!_emittedCallIds.add(callId)) return const <AgentProviderEvent>[];
    return <AgentProviderEvent>[
      AgentProviderFunctionCall(
        callId: callId,
        name: name,
        argumentsJson: arguments,
      ),
    ];
  }

  List<AgentProviderEvent> _completed(Map<String, dynamic> payload) {
    final response = payload['response'];
    final responseId = response is Map<String, dynamic>
        ? response['id']
        : payload['response_id'] ?? payload['id'];
    if (responseId is! String) return _malformed();
    return <AgentProviderEvent>[AgentProviderCompleted(responseId)];
  }

  Never _incomplete() {
    throw const AgentProviderException(
      AgentProviderFailure.incompleteResponse,
    );
  }

  void _captureContinuationItem(Map<String, dynamic> item) {
    final itemType = item['type'];
    if (itemType == 'reasoning' ||
        itemType == 'function_call' ||
        itemType == 'web_search_call' ||
        itemType == 'message') {
      _onContinuationItem?.call(Map<String, Object?>.from(item));
    }
  }

  List<AgentProviderEvent> _webSearchPhase(
    AgentProviderWebSearchPhase phase,
  ) {
    if (!_emittedWebPhases.add(phase)) return const <AgentProviderEvent>[];
    return <AgentProviderEvent>[AgentProviderWebSearchEvent(phase)];
  }

  Never _providerFailure(Map<String, dynamic> payload) {
    Object? error = payload['error'];
    final response = payload['response'];
    if (error == null && response is Map<String, dynamic>) {
      error = response['error'];
    }
    final code = error is Map<String, dynamic> ? error['code'] : null;
    final normalized = code is String ? code.toLowerCase() : '';
    final failure = normalized.contains('auth') ||
            normalized.contains('api_key') ||
            normalized.contains('unauthorized')
        ? AgentProviderFailure.authentication
        : normalized.contains('rate')
            ? AgentProviderFailure.rateLimited
            : normalized.contains('timeout')
                ? AgentProviderFailure.timeout
                : AgentProviderFailure.temporarilyUnavailable;
    throw AgentProviderException(failure);
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

  Never _malformed() {
    throw const AgentProviderException(AgentProviderFailure.malformedResponse);
  }
}

final class _FunctionCallAccumulator {
  String? callId;
  String? name;
  final StringBuffer arguments = StringBuffer();
}
