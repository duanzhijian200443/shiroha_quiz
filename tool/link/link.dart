import 'dart:io';
import 'package:shiroha_quiz/data/external/link/link_installation.dart';
import 'package:shiroha_quiz/data/external/link/link_runtime.dart';
import 'package:shiroha_quiz/data/external/link/link_initialization.dart';
import 'package:shiroha_quiz/data/external/link/link_verification_log.dart';
import 'package:shiroha_quiz/data/external/windows_local_relay.dart';

Future<void> main(List<String> arguments) async {
  if (arguments.isNotEmpty &&
      (arguments.length != 1 || arguments.single != '--initialize')) {
    stderr.writeln('invalid_arguments');
    exitCode = 64;
    return;
  }
  LinkRuntime? runtime;
  LinkVerificationLog? verification;
  WindowsLocalRelay? business, control;
  var phase = 'business_ipc';
  try {
    // Native role admission precedes any mutable state or device credential.
    business = WindowsLocalRelay.openLinkBusiness(server: true);
    phase = 'control_ipc';
    control = WindowsLocalRelay.openLinkControl(server: true);
    phase = 'installation';
    final config = await LinkInstallation.load();
    phase = 'state';
    final store =
        await LinkInitialization(config).open(initialize: arguments.isNotEmpty);
    if (store.state.connectorInstanceId != config.connectorInstanceId) {
      await store.close();
      throw StateError('invalid_installation');
    }
    const verify = bool.fromEnvironment('SHIROHA_LINK_VERIFY_SUPERVISION');
    runtime = LinkRuntime(
        installation: config,
        store: store,
        verificationObserver:
            verify ? (event) => verification!.record(event) : null);
    if (verify) {
      verification = LinkVerificationLog(config.stateDirectory, runtime.runId);
    }
    phase = 'serving';
    stderr.writeln('link_started');
    await LinkPipeServer(runtime, business, control).serve();
  } catch (error) {
    stderr.writeln(error is LocalRelayException && error.independentAppRequired
        ? 'link_desktop_launch_required'
        : 'link_${phase}_unavailable');
    exitCode = 78;
  } finally {
    try {
      await runtime?.close();
      await business?.close();
      await control?.close();
    } catch (_) {
      stderr.writeln('link_settlement_unknown');
      exitCode = 79;
    }
    if (verification != null && !await verification.finish()) {
      stderr.writeln('link_verification_log_failed');
      if (exitCode == 0) exitCode = 80;
    }
  }
}
