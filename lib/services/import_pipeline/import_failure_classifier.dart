import 'dart:async';
import 'dart:io';

import 'package:http/http.dart' as http;

enum ImportFailureType {
  fileRead,
  providerRequest,
  providerResponseFormat,
  taskCancelled,
  unknown,
}

class ImportFailureClassification {
  const ImportFailureClassification({
    required this.type,
    required this.errorType,
    required this.userMessage,
  });

  final ImportFailureType type;
  final String errorType;
  final String userMessage;
}

class ImportTaskCancelledException implements Exception {
  const ImportTaskCancelledException();
}

abstract final class ImportFailureClassifier {
  static const fileReadFailure = ImportFailureClassification(
    type: ImportFailureType.fileRead,
    errorType: 'FileReadFailure',
    userMessage: '无法读取导入文件，请检查文件是否仍然存在',
  );
  static const providerRequestFailure = ImportFailureClassification(
    type: ImportFailureType.providerRequest,
    errorType: 'ProviderRequestFailure',
    userMessage: 'OCR 服务请求失败，请检查网络或服务配置',
  );
  static const providerResponseFormatFailure = ImportFailureClassification(
    type: ImportFailureType.providerResponseFormat,
    errorType: 'ProviderResponseFormatFailure',
    userMessage: 'OCR 返回结果格式异常，请稍后重试',
  );
  static const taskCancelled = ImportFailureClassification(
    type: ImportFailureType.taskCancelled,
    errorType: 'TaskCancelled',
    userMessage: '导入任务已取消',
  );
  static const unknownFailure = ImportFailureClassification(
    type: ImportFailureType.unknown,
    errorType: 'UnknownImportFailure',
    userMessage: '导入过程中发生异常，请根据 Trace ID 查看诊断',
  );

  static ImportFailureClassification classify(Object error) {
    return switch (error) {
      FileSystemException() => fileReadFailure,
      TimeoutException() => providerRequestFailure,
      SocketException() => providerRequestFailure,
      HttpException() => providerRequestFailure,
      http.ClientException() => providerRequestFailure,
      FormatException() => providerResponseFormatFailure,
      ImportTaskCancelledException() => taskCancelled,
      _ => unknownFailure,
    };
  }
}
