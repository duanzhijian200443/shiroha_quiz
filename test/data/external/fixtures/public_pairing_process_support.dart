// Test-only public Exchange replication. No protected credential bytes cross.
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'process_file_support.dart';
export 'process_file_support.dart';
import '../windows_pairing_test.dart' show PairingHarness;

Future<void> exportExchange(PairingHarness h, Directory root, String name) =>
    publishPublic(
        root,
        name,
        utf8.encode(jsonEncode([
          for (final entry in h.native.calls.exchangeFiles.entries)
            if (entry.key.$1 ==
                (name.startsWith('submission')
                    ? 1
                    : name.startsWith('challenge')
                        ? 2
                        : 3))
              [entry.key.$1, entry.key.$2, base64Encode(entry.value)]
        ])));

Future<void> importExchange(
    PairingHarness h, Directory root, String name) async {
  final file = await waitPublicFile(root, name);
  final entries = jsonDecode(await file.readAsString()) as List;
  for (final row in entries) {
    final key = (row[0] as int, row[1] as String);
    h.native.calls.exchangeFiles[key] =
        Uint8List.fromList(base64Decode(row[2] as String));
    h.native.calls.exchangeIdentities[key] =
        h.native.calls.nextExchangeIdentity++;
  }
}
