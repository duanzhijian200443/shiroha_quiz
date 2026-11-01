import 'dart:convert';
import 'dart:io';
import '../../../services/backup/sha256.dart';
import 'package:path/path.dart' as p;
import '../bounded_json_object.dart';
import 'link_state_store.dart';
import 'link_values.dart';

/// Immutable source consistency. Hashes are not authentication: only the
/// admitted original adapter and its supervising process produce these files.
final class RegistrationEvidence {
  RegistrationEvidence(this.directory);
  final String directory;
  File file(String name) => File(p.join(directory, name));
  Future<Map<String, dynamic>> read(String name) async =>
      boundedJsonObject(await readBoundedLinkFile(file(name)),
          maxBytes: linkStateLimit);
  Future<String> digest(String name, {int limit = linkStateLimit}) async =>
      (StreamingSha256()
            ..update(await readBoundedLinkFile(file(name), limit: limit)))
          .digestHex();
  static bool same(Object? a, Object? b) => jsonEncode(a) == jsonEncode(b);
  static void registration(Map<String, dynamic> value) {
    linkFields(value, {
      'registrarInstanceId',
      'operationId',
      'generation',
      'runId',
      'resourceId'
    });
    for (final field in value.keys) {
      linkToken(value[field]);
    }
  }

  /// CREATE_NEW staging; interruption never overwrites any original evidence.
  Future<void> publish(String name, Map<String, dynamic> value) async {
    final bytes = utf8.encode(jsonEncode(value));
    if (bytes.length > linkStateLimit) {
      linkFail();
    }
    if (await file(name).exists()) {
      if (!same(await read(name), value)) {
        linkFail('owner_conflict');
      }
      if (await file('$name.pending').exists()) {
        linkFail();
      }
      return;
    }
    final pending = file('$name.pending');
    if (await pending.exists()) {
      if (!same(await read('$name.pending'), value)) {
        linkFail();
      }
    } else {
      await pending.create(exclusive: true);
      final handle = await pending.open(mode: FileMode.writeOnly);
      try {
        await handle.writeFrom(bytes);
        await handle.flush();
      } finally {
        await handle.close();
      }
    }
    // Caller holds the slot control lock; all supported writers obey custody.
    if (await file(name).exists()) {
      linkFail();
    }
    await pending.rename(file(name).path);
    if (!same(await read(name), value)) {
      linkFail();
    }
  }

  Future<void> noPending() async {
    for (final name in [
      'registration-attempt.json',
      'registration-receipt.json',
      'registration-origin.json',
      'registration-joined.json',
      'registration-source.json',
      'registration-adoption-joined.json'
    ]) {
      if (await file('$name.pending').exists()) {
        linkFail();
      }
    }
  }

  Future<Map<String, dynamic>> original(Map<String, dynamic> custody) async {
    final registration = custody['registration'] as Map<String, dynamic>;
    RegistrationEvidence.registration(registration);
    final attempt = await read('registration-attempt.json');
    linkFields(attempt, {'formatVersion', 'slotRef', 'registration'});
    if (attempt['formatVersion'] != 1 ||
        attempt['slotRef'] != custody['slotRef'] ||
        !same(attempt['registration'], registration)) {
      linkFail();
    }
    final origin = await read('registration-origin.json');
    linkFields(origin, {
      'formatVersion',
      'slotRef',
      'origin',
      'registration',
      'target',
      'credentialSlotRef',
      'credentialDigest',
      'associationRevision',
      'clientCertificateDigest',
      'resourceGeneration',
      'settlementRef'
    });
    if (origin['formatVersion'] != 2 ||
        origin['slotRef'] != custody['slotRef'] ||
        origin['origin'] != 'independent_registrar_pairing' ||
        origin['credentialSlotRef'] != 'device.dpapi' ||
        !same(origin['registration'], registration) ||
        origin['resourceGeneration'] != registration['resourceId'] ||
        origin['settlementRef'] != registration['resourceId'] ||
        linkRevision(origin['associationRevision']) < 1) {
      linkFail();
    }
    linkToken(origin['credentialDigest'], digest: true);
    linkToken(origin['clientCertificateDigest'], digest: true);
    LinkVerifiedTarget.fromJson(origin['target'] as Map<String, dynamic>);
    final receipt = await read('registration-receipt.json');
    linkFields(receipt, {
      'formatVersion',
      'operationId',
      'receiptRef',
      'runId',
      'resourceId',
      'processId',
      'processStarted',
      'slotRef',
      'owner',
      'mode',
      'target',
      'targetClose',
      'tlsShutdown',
      'keyRetired'
    });
    if (receipt['formatVersion'] != 2 ||
        receipt['mode'] != 'pairing' ||
        receipt['slotRef'] != custody['slotRef'] ||
        receipt['owner'] != registration['registrarInstanceId'] ||
        receipt['operationId'] != registration['operationId'] ||
        receipt['runId'] != registration['runId'] ||
        receipt['resourceId'] != registration['resourceId'] ||
        receipt['receiptRef'] != origin['settlementRef'] ||
        !same(receipt['target'], origin['target']) ||
        receipt['targetClose'] != true ||
        receipt['tlsShutdown'] != true ||
        receipt['keyRetired'] != true ||
        linkRevision(receipt['processId']) < 1) {
      linkFail();
    }
    linkToken(receipt['processStarted']);
    return origin;
  }

  static void requireJoin(
      Map<String, dynamic> join, Map<String, dynamic> receipt) {
    linkFields(join, {
      'formatVersion',
      'operationId',
      'slotRef',
      'ownerInstanceId',
      'runId',
      'resourceId',
      'processId',
      'processStarted',
      'adapterReceiptRef',
      'target',
      'processExitCode',
      'stdinClosed',
      'stdoutDrained',
      'stderrDrained'
    });
    if (join['formatVersion'] != 1 ||
        join['processExitCode'] != 0 ||
        join['stdinClosed'] != true ||
        join['stdoutDrained'] != true ||
        join['stderrDrained'] != true ||
        join['ownerInstanceId'] != receipt['owner'] ||
        join['adapterReceiptRef'] != receipt['receiptRef'] ||
        !same(join['target'], receipt['target'])) {
      linkFail();
    }
    for (final field in [
      'operationId',
      'slotRef',
      'runId',
      'resourceId',
      'processId',
      'processStarted'
    ]) {
      if (join[field] != receipt[field]) {
        linkFail();
      }
    }
  }

  Future<Map<String, dynamic>> verify(Map<String, dynamic> custody,
      {bool requireManifest = true}) async {
    final origin = await original(custody);
    requireJoin(await read('registration-joined.json'),
        await read('registration-receipt.json'));
    if (await digest('device.dpapi', limit: 65536) !=
        origin['credentialDigest']) {
      linkFail('credential_changed');
    }
    if (requireManifest) {
      final manifest = await read('registration-source.json');
      linkFields(
          manifest, {'formatVersion', 'slotRef', 'registration', 'files'});
      if (manifest['formatVersion'] != 1 ||
          manifest['slotRef'] != custody['slotRef'] ||
          !same(manifest['registration'], custody['registration'])) {
        linkFail();
      }
      final files = manifest['files'] as Map<String, dynamic>;
      linkFields(files, {
        'registration-attempt.json',
        'registration-receipt.json',
        'registration-origin.json',
        'registration-joined.json'
      });
      for (final name in files.keys) {
        if (await digest(name) != files[name]) {
          linkFail('source_changed');
        }
      }
      if (await digest('registration-source.json') != custody['sourceDigest']) {
        linkFail('source_changed');
      }
    }
    return origin;
  }
}
