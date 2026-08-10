final class AgentRuntimeLimits {
  const AgentRuntimeLimits({
    this.maxHistoryMessages = 40,
    this.maxHistoryUtf8Bytes = 64 * 1024,
    this.maxToolArgumentUtf8Bytes = 16 * 1024,
    this.maxToolResultUtf8Bytes = 64 * 1024,
    this.maxToolRounds = 4,
    this.maxLocalCalls = 8,
    this.turnTimeout = const Duration(seconds: 120),
    this.maxOutputTokens = 4096,
  })  : assert(maxHistoryMessages > 0),
        assert(maxHistoryUtf8Bytes > 0),
        assert(maxToolArgumentUtf8Bytes > 0),
        assert(maxToolResultUtf8Bytes > 0),
        assert(maxToolRounds > 0),
        assert(maxLocalCalls > 0),
        assert(maxOutputTokens > 0);

  final int maxHistoryMessages;
  final int maxHistoryUtf8Bytes;
  final int maxToolArgumentUtf8Bytes;
  final int maxToolResultUtf8Bytes;
  final int maxToolRounds;
  final int maxLocalCalls;
  final Duration turnTimeout;
  final int maxOutputTokens;
}
