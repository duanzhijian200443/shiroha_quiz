import 'package:shiroha_quiz/data/external/windows_codex_client.dart';

/// Offline compatibility input only. Actual clients are inspected separately.
final class FakeCodexExecutable implements WindowsCodexExecutable {
  FakeCodexExecutable(
      [this.digest = WindowsCodexClientSelection.isolatedPatchDigest]);
  String digest;
  @override
  Future<String> sha256() async => digest;
}

Future<WindowsCodexClientSelection> isolatedClientSelection({
  WindowsCodexConnectionMode mode = WindowsCodexConnectionMode.direct,
}) =>
    WindowsCodexClientSelection.inspect(
        executable: FakeCodexExecutable(),
        use: WindowsCodexClientUse.isolatedValidation,
        mode: mode);
