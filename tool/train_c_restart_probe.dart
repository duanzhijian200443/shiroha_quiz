import 'dart:convert';
import 'dart:io';

import 'train_c_isolated_runtime.dart';
import 'train_c_restart_proof.dart';

const _capabilityEnvironmentKey = 'TRAIN_C_REATTACH_CAPABILITY';

Future<void> main(List<String> args) async {
  if (args.length != 1 || args.single != '--child') {
    stderr.writeln('TRAIN_C_RESTART_FAILURE');
    exitCode = 2;
    return;
  }
  final capability = Platform.environment[_capabilityEnvironmentKey];
  if (capability == null || capability.trim().isEmpty) {
    stderr.writeln('TRAIN_C_RESTART_FAILURE');
    exitCode = 2;
    return;
  }

  TrainCIsolatedRuntime? runtime;
  try {
    runtime = await TrainCIsolatedRuntime.reattachFromCapability(
      capability,
      deleteRootOnDispose: false,
    );
  } on TrainCIsolationException catch (error) {
    stderr.writeln('TRAIN_C_RESTART_FAILURE');
    exitCode = switch (error.safeDetail) {
      'TRAIN_C_REATTACH_CAPABILITY_INVALID' => 21,
      'TRAIN_C_REATTACH_ROOT_INVALID' => 22,
      'TRAIN_C_REATTACH_NONCE_INVALID' => 23,
      'TRAIN_C_REATTACH_DATABASE_FAILURE' => 24,
      'TRAIN_C_REATTACH_DATABASE_INIT_FAILURE' => 25,
      'TRAIN_C_REATTACH_DATABASE_PATH_FAILURE' => 26,
      'TRAIN_C_REATTACH_DATABASE_PROFILE_FAILURE' => 27,
      'TRAIN_C_REATTACH_DATABASE_OPEN_FAILURE' => 28,
      'TRAIN_C_REATTACH_DATABASE_IDENTITY_FAILURE' => 29,
      _ => 11,
    };
    return;
  } catch (_) {
    stderr.writeln('TRAIN_C_RESTART_FAILURE');
    exitCode = 11;
    return;
  }
  try {
    final checkpoint = await captureTrainCDurableRestartCheckpoint(
      database: await runtime.database,
      managedDirectory: runtime.managedDirectory,
    );
    stdout.writeln(
      jsonEncode(
        trainCRestartProtocolMap(childPid: pid, checkpoint: checkpoint),
      ),
    );
  } catch (_) {
    stderr.writeln('TRAIN_C_RESTART_FAILURE');
    exitCode = 12;
    return;
  }
  try {
    await runtime.closeForRestart();
  } catch (_) {
    stderr.writeln('TRAIN_C_RESTART_FAILURE');
    exitCode = 13;
  }
}
