import 'dart:io';
import 'package:path/path.dart' as p;
import '../bounded_json_object.dart';
import 'link_state_store.dart';
import 'link_values.dart';

/// Local installer input only, never accepted over model/business IPC.
final class LinkInstallation {
  const LinkInstallation(
      {required this.stateDirectory,
      required this.slotDirectory,
      required this.slotRef,
      required this.connectorInstanceId,
      required this.adapterExecutable,
      this.windowsClientExecutable});
  final String stateDirectory,
      slotDirectory,
      slotRef,
      connectorInstanceId,
      adapterExecutable;
  final String? windowsClientExecutable;

  static Future<LinkInstallation> load() async {
    final root = p.dirname(Platform.resolvedExecutable);
    final value = boundedJsonObject(
        await readBoundedLinkFile(File(p.join(root, 'link-installation.json')),
            limit: 16384),
        maxBytes: 16384);
    linkFields(value, {
      'version',
      'stateDirectory',
      'slotDirectory',
      'slotRef',
      'connectorInstanceId',
      'adapterExecutable',
      'windowsClientExecutable'
    });
    if (value['version'] != 1) linkFail('invalid_configuration');
    String path(Object? raw) {
      if (raw is! String ||
          !p.isAbsolute(raw) ||
          !p.equals(raw, p.normalize(raw))) {
        linkFail('invalid_configuration');
      }
      return raw;
    }

    final adapter = path(value['adapterExecutable']);
    if (!p.equals(adapter, p.join(root, 'AndroidDeviceAdapter.exe'))) {
      linkFail('invalid_configuration');
    }
    final state = path(value['stateDirectory']);
    if (p.isWithin(root, state) || p.equals(root, state)) {
      linkFail('invalid_configuration');
    }
    return LinkInstallation(
        stateDirectory: state,
        slotDirectory: path(value['slotDirectory']),
        slotRef: linkToken(value['slotRef']),
        connectorInstanceId: linkToken(value['connectorInstanceId']),
        adapterExecutable: adapter,
        windowsClientExecutable: value['windowsClientExecutable'] == null
            ? null
            : path(value['windowsClientExecutable']));
  }
}
