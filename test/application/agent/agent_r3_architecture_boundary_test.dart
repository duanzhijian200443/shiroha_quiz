import 'dart:io';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test(
      'R3 owners retain facade and separate execution, finalization and authority',
      () {
    String read(String name) =>
        File('lib/application/agent/$name.dart').readAsStringSync();
    final facade = read('agent_runtime');
    final engine = read('agent_round_engine');
    final transcript = read('agent_turn_transcript');
    final tools = read('agent_tool_executor');
    final gateway = read('provider_round_gateway');
    expect(facade, contains('final class ShirohaAgentRuntime'));
    expect(facade, contains('_coordinator.startTurn'));
    expect(facade, isNot(contains('_executeTurn(')));
    expect(engine, contains('_tools._execute(turn, call, trusted)'));
    expect(engine, isNot(contains('call.name ==')));
    expect(engine, isNot(contains('appendAssistant')));
    expect(tools, contains('_bindings = Map.unmodifiable'));
    expect(tools, contains('.dispatchWithReceipt('));
    for (final dispatcher in [
      '_toolDispatcher',
      '_proposalDispatcher',
      '_studyPlanDispatcher',
      'retrievalDispatcher'
    ]) {
      expect(
          RegExp('\\b$dispatcher[!?]?\\s*\\.dispatch\\s*\\(').hasMatch(tools),
          isFalse);
    }
    expect(gateway, contains('normalizeProviderRound('));
    for (final source in [facade, engine, gateway]) {
      expect(source, isNot(contains('services/agent/deepseek')));
    }
    for (final forbidden in [
      'sqlite',
      'database_helper',
      'mcp',
      'LogWriter',
      'ContinuationState'
    ]) {
      expect(
          transcript.toLowerCase(), isNot(contains(forbidden.toLowerCase())));
    }
    final capability =
        File('lib/application/capabilities/capability.dart').readAsStringSync();
    expect(capability, isNot(contains('agent_runtime')));
    for (final source in [facade, engine, tools, transcript]) {
      expect(source.toLowerCase(), isNot(contains('getit')));
      expect(source.toLowerCase(), isNot(contains('servicelocator')));
    }
  });
}
