// Isolated ordinary-process regression host. No Flutter, database or credentials.
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:shiroha_quiz/composition/mcp_vnext_app_owned_relay.dart';
import 'package:shiroha_quiz/composition/mcp_vnext_development_lifetime.dart';
import 'package:shiroha_quiz/application/external/external_device_connection.dart';

final class _SelectionStore implements ExternalDeviceSelectionStore {
  @override
  Future<void> acknowledgeDeviceCleanup(
          ExternalDeviceSelection expected, ExternalDeviceSelection replacement,
          {required bool Function() isCurrent}) async =>
      throw UnsupportedError('Recovery is not enabled in this fixture');
  @override
  Future<void> settleDeviceLease(ExternalDeviceLease lease) async {
    lease.requireSettlement(this);
    await saveDeviceSelection(ExternalDeviceSelection(
        target: lease.target, generation: lease.generation));
  }

  _SelectionStore(this.file);
  final File file;
  @override
  Future<ExternalDeviceSelection?> readDeviceSelection() async => null;
  @override
  Future<void> saveDeviceSelection(ExternalDeviceSelection value) async =>
      file.writeAsStringSync(
          jsonEncode({
            'generation': value.generation,
            'needsCleanup': value.needsCleanup
          }),
          flush: true);
}

Future<void> main() async {
  final root = p.dirname(Platform.resolvedExecutable);
  final events = File(p.join(root, 'app.jsonl'));
  void report(String event, int connection) => events.writeAsStringSync(
      '${jsonEncode({'event': event, 'connection': connection, 'pid': pid})}\n',
      mode: FileMode.append,
      flush: true);
  final scenario = File(p.join(root, 'scenario')).readAsStringSync();
  late final McpVnextAppOwnedRelay relay;
  final devices = File(p.join(root, 'unified')).existsSync()
      ? ExternalDeviceConnection(
          store: _SelectionStore(File(p.join(root, 'selection.json'))),
          availableTargets: () async => [const ExternalDeviceTarget.windows()],
          endConnection: () => relay.endCurrentConnection())
      : null;
  relay = McpVnextAppOwnedRelay(
      devices: devices,
      onEvent: report,
      idleTimeout:
          scenario.contains('idle') || scenario.startsWith('adapter-reconnect')
              ? const Duration(seconds: 1)
              : const Duration(seconds: 30));
  if (devices != null) {
    await devices.load();
    await devices.select(const ExternalDeviceTarget.windows());
  }
  relay.start();
  report(relay.available ? 'ready' : 'unavailable', 0);
  Timer? monitor;
  if (scenario.startsWith('pending-peer')) {
    // The production monitor and native launch query run over the actual relay.
    // This fixture owns no protected Host; the portable companion covers P0.
    relay.onDisconnected = () async => report('enableWithdrawn', 0);
    monitor = monitorWindowsDevelopmentLifetime(
        isCurrent: () {
          final current = relay.launchCurrent;
          report(current ? 'launchCurrent' : 'launchLost', 0);
          return current;
        },
        isExpired: () => false,
        launchIsCurrent: () => relay.launchCurrent,
        stop: (_) async {
          monitor?.cancel();
          report('deploymentStopped', 0);
          await relay.close();
        });
  }
  final watch = Stopwatch()..start();
  while (!File(p.join(root, 'stop')).existsSync() &&
      watch.elapsed < const Duration(seconds: 90)) {
    await Future<void>.delayed(const Duration(milliseconds: 20));
  }
  try {
    monitor?.cancel();
    await relay.close();
    report('appClosed', 0);
  } catch (_) {
    report('appCloseFailed', 0);
    exitCode = 23;
  }
}
