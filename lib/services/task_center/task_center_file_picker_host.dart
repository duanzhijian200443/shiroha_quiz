import 'dart:io';
import 'package:file_picker/file_picker.dart';
import '../../application/task_center/retry_file_selection.dart';
import '../../application/task_center/task_center_contracts.dart';
import 'task_center_facade.dart';

/// The only TaskCenter picker boundary; selected locations never enter read state.
final class TaskCenterFilePickerHost implements RetryFileSelectionHost {
  TaskCenterFilePickerHost(
      {Future<FilePickerResult?> Function()? picker,
      Future<bool> Function(String)? exists})
      : _picker = picker ??
            (() => FilePicker.platform.pickFiles(
                type: FileType.custom,
                allowedExtensions: const ['pdf', 'png', 'jpg', 'jpeg'],
                allowMultiple: true)),
        _exists = exists ?? ((path) => File(path).exists());
  final Future<FilePickerResult?> Function() _picker;
  final Future<bool> Function(String) _exists;

  @override
  Future<RetryFileSelectionResult> select(
      RetryFileSelectionRequest request) async {
    try {
      final result = await _picker();
      if (result == null || result.files.isEmpty) {
        return const RetryFileSelectionCancelled();
      }
      final paths = <String>[];
      final names = <String>[];
      for (final file in result.files) {
        final location = file.path;
        if (location == null ||
            location.trim().isEmpty ||
            !isSafeTaskCenterDisplayName(file.name) ||
            !await _exists(location)) {
          return const RetryFileSelectionCancelled();
        }
        paths.add(location);
        names.add(file.name);
      }
      return RetryFileSelectionSelected(
          request: request,
          selection: TaskCenterLocalRetrySource(paths: paths, names: names));
    } catch (_) {
      return const RetryFileSelectionCancelled();
    }
  }
}
