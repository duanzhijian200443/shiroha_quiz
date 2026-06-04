typedef ParseBatchChunk = Future<List<Map<String, dynamic>>> Function(
  String chunk,
);

typedef ParseBatchSuccess = void Function(
  String chunk,
  List<Map<String, dynamic>> questions,
);

typedef ParseBatchFailure = void Function(String chunk);

typedef ParseBatchLog = void Function(String message);

class ParseBatchRunResult {
  const ParseBatchRunResult({
    required this.questions,
    required this.failedCount,
  });

  final List<Map<String, dynamic>> questions;
  final int failedCount;

  bool get hasFailures => failedCount > 0;
}

class ParseBatchRunner {
  const ParseBatchRunner({
    this.maxConcurrent = 3,
    this.maxRetries = 3,
    this.successPause = const Duration(milliseconds: 500),
    this.retryDelayFor = defaultRetryDelayFor,
  });

  final int maxConcurrent;
  final int maxRetries;
  final Duration successPause;
  final Duration Function(Object error, int retry) retryDelayFor;

  static Duration defaultRetryDelayFor(Object error, int retry) {
    final message = error.toString().toLowerCase();
    final isRateLimitOrNetworkIssue = message.contains('429') ||
        message.contains('timeout') ||
        message.contains('socketexception') ||
        message.contains('clientexception');
    return Duration(seconds: isRateLimitOrNetworkIssue ? 5 * retry : 2);
  }

  Future<ParseBatchRunResult> run({
    required List<String> chunks,
    required ParseBatchChunk parseChunk,
    ParseBatchSuccess? onChunkSuccess,
    ParseBatchFailure? onChunkFailed,
    ParseBatchLog? onLog,
  }) async {
    final results = List<List<Map<String, dynamic>>?>.filled(
      chunks.length,
      null,
    );
    var currentIndex = 0;
    var failedCount = 0;

    Future<void> worker(int workerId) async {
      while (true) {
        if (currentIndex >= chunks.length) break;
        final index = currentIndex++;
        final chunk = chunks[index];

        onLog?.call(
          '🚀 [并发线程 ${workerId + 1}] 正在解析第 ${index + 1}/${chunks.length} 块...',
        );

        var retry = 0;
        while (retry < maxRetries) {
          try {
            final questions = await parseChunk(chunk);
            results[index] = questions;
            onChunkSuccess?.call(chunk, questions);
            if (successPause > Duration.zero) {
              await Future.delayed(successPause);
            }
            return;
          } catch (error) {
            retry++;
            onLog?.call(
              '⚠️ 第 ${index + 1} 块解析失败 (重试 $retry/$maxRetries): $error',
            );

            if (retry >= maxRetries) {
              failedCount++;
              onChunkFailed?.call(chunk);
              return;
            }

            final delay = retryDelayFor(error, retry);
            onLog?.call('⚠️ 触发频率限制/错误，冷却 ${delay.inSeconds} 秒后重试...');
            if (delay > Duration.zero) {
              await Future.delayed(delay);
            }
          }
        }
      }
    }

    final workerCount =
        chunks.length < maxConcurrent ? chunks.length : maxConcurrent;
    await Future.wait([
      for (var workerId = 0; workerId < workerCount; workerId++)
        worker(workerId),
    ]);

    return ParseBatchRunResult(
      questions: [
        for (final result in results)
          if (result != null) ...result,
      ],
      failedCount: failedCount,
    );
  }
}
