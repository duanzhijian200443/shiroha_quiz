import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive_io.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:shiroha_quiz/domain/backup/archive_path_policy.dart';
import 'package:shiroha_quiz/domain/backup/backup_failure.dart';
import 'package:shiroha_quiz/domain/backup/backup_manifest.dart';
import 'package:shiroha_quiz/domain/backup/backup_values.dart';
import 'package:shiroha_quiz/services/backup/backup_archive_io.dart';
import 'package:shiroha_quiz/services/backup/sha256.dart';

void main() {
  late Directory temp;

  setUp(() async {
    temp = await Directory.systemTemp.createTemp('b0_archive_');
  });

  tearDown(() async {
    if (await temp.exists()) {
      await temp.delete(recursive: true);
    }
  });

  Future<String> writePackage({
    int databaseBytes = 7,
    String? manifestOverride,
    bool includeManagedFile = true,
  }) async {
    final db = File(p.join(temp.path, 'db', 'shiroha.db'));
    await db.parent.create(recursive: true);
    final dbBytes = List<int>.generate(databaseBytes, (i) => i);
    await db.writeAsBytes(dbBytes, flush: true);

    final source = File(p.join(temp.path, 'source.bin'));
    await source.writeAsBytes(<int>[1, 2, 3, 4], flush: true);

    final copied = File(p.join(temp.path, 'files', 'library', 'file-1'));
    await copied.parent.create(recursive: true);
    await source.copy(copied.path);

    final hasManagedFile = includeManagedFile;
    final manifest = BackupManifest(
      schemaVersion: 22,
      createdAtUtc: DateTime.utc(2026, 1, 1),
      database: BackupDatabaseEntry(
        archivePath: BackupValues.databaseArchivePath,
        sizeBytes: dbBytes.length,
        sha256: sha256Hex(dbBytes),
      ),
      managedFiles: <BackupManagedFileEntry>[
        if (hasManagedFile)
          BackupManagedFileEntry(
            fileId: 'file-1',
            storageKey: 'library/file-1',
            archivePath: BackupValues.managedArchivePath('file-1'),
            sizeBytes: 4,
            sha256: sha256Hex(<int>[1, 2, 3, 4]),
          ),
      ],
    );
    final manifestPath = p.join(temp.path, 'manifest.json');
    await File(manifestPath).writeAsString(
      manifestOverride ?? manifest.encode(),
      flush: true,
    );
    final package = p.join(temp.path, 'package.shiroha');
    await BackupArchiveIo.writeStoredPackage(
      packagePath: package,
      manifestPath: manifestPath,
      databasePath: db.path,
      files: <ArchiveSourceFile>[
        if (hasManagedFile)
          ArchiveSourceFile(fileId: 'file-1', path: copied.path),
      ],
    );
    return package;
  }

  test('stored package extracts and validates exact database and file bytes',
      () async {
    final package = await writePackage();
    final staging = p.join(temp.path, 'staging');
    final extracted = await BackupArchiveIo.extractAndValidate(
      packagePath: package,
      stagingRoot: staging,
    );

    expect(extracted.manifest.managedFileCount, 1);
    expect(
      File(extracted.databasePath).readAsBytesSync(),
      List<int>.generate(7, (i) => i),
    );
    expect(
      File(p.join(extracted.managedFilesRoot, 'file-1')).readAsBytesSync(),
      <int>[1, 2, 3, 4],
    );
  });

  test('normalized duplicate archive paths are rejected by admission', () {
    expect(
      ArchivePathPolicy.hasNormalizedDuplicate(<String>[
        'files/library/a',
        'files//library/a',
      ]),
      isTrue,
    );
  });

  test('case-insensitive entry collision is rejected', () async {
    final package = p.join(temp.path, 'case.shiroha');
    final archive = Archive()
      ..addFile(ArchiveFile.string('manifest.json', '{}'))
      ..addFile(ArchiveFile.string('Manifest.JSON', '{}'));
    final output = OutputFileStream(package);
    ZipEncoder().encode(archive, output: output);
    output.closeSync();

    await expectLater(
      BackupArchiveIo.extractAndValidate(
        packagePath: package,
        stagingRoot: p.join(temp.path, 'staging'),
      ),
      throwsA(isA<BackupException>().having(
        (e) => e.failure,
        'failure',
        BackupFailure.duplicateArchiveEntry,
      )),
    );
  });

  test('DB zip declared size must equal manifest sizeBytes', () async {
    final manifest = BackupManifest(
      schemaVersion: 22,
      createdAtUtc: DateTime.utc(2026, 1, 1),
      database: BackupDatabaseEntry(
        archivePath: BackupValues.databaseArchivePath,
        sizeBytes: 999,
        sha256: sha256Hex(List<int>.generate(7, (i) => i)),
      ),
      managedFiles: const <BackupManagedFileEntry>[],
    );
    final package = await writePackage(
      manifestOverride: manifest.encode(),
      includeManagedFile: false,
    );

    await expectLater(
      BackupArchiveIo.extractAndValidate(
        packagePath: package,
        stagingRoot: p.join(temp.path, 'staging'),
      ),
      throwsA(isA<BackupException>().having(
        (e) => e.failure,
        'failure',
        BackupFailure.manifestInvalid,
      )),
    );
  });

  test('unsupported compression method is rejected before extraction',
      () async {
    final package = p.join(temp.path, 'unsupported.shiroha');
    final manifest = BackupManifest(
      schemaVersion: 22,
      createdAtUtc: DateTime.utc(2026, 1, 1),
      database: BackupDatabaseEntry(
        archivePath: BackupValues.databaseArchivePath,
        sizeBytes: 0,
        sha256: sha256Hex(const <int>[]),
      ),
      managedFiles: const <BackupManagedFileEntry>[],
    );
    final archive = Archive()
      ..addFile(ArchiveFile.string(
          BackupValues.manifestArchivePath, manifest.encode()))
      ..addFile(ArchiveFile.string(BackupValues.databaseArchivePath, ''));
    final output = OutputFileStream(package);
    ZipEncoder().encode(archive, output: output);
    output.closeSync();

    // Rewrite the manifest entry compression-method bytes from STORE (0) to
    // BZip2 (12) in both local and central headers.
    final bytes = Uint8List.fromList(File(package).readAsBytesSync());
    for (var i = 0; i < bytes.length - 4; i++) {
      if (bytes[i] == 0x50 &&
          bytes[i + 1] == 0x4b &&
          bytes[i + 2] == 0x01 &&
          bytes[i + 3] == 0x02) {
        // central directory header: compression method offset is +10.
        bytes[i + 10] = 12;
        bytes[i + 11] = 0;
        break;
      }
    }
    for (var i = 0; i < bytes.length - 4; i++) {
      if (bytes[i] == 0x50 &&
          bytes[i + 1] == 0x4b &&
          bytes[i + 2] == 0x03 &&
          bytes[i + 3] == 0x04) {
        // local header: compression method offset is +8.
        bytes[i + 8] = 12;
        bytes[i + 9] = 0;
        break;
      }
    }
    await File(package).writeAsBytes(bytes, flush: true);

    await expectLater(
      BackupArchiveIo.readManifestOnly(package),
      throwsA(isA<BackupException>().having(
        (e) => e.failure,
        'failure',
        BackupFailure.unsupportedCompression,
      )),
    );
  });

  test('deflate output is bounded during streaming', () async {
    final package = p.join(temp.path, 'deflate_bomb.shiroha');
    final zero10 = List<int>.filled(10, 0);
    final manifest = BackupManifest(
      schemaVersion: 22,
      createdAtUtc: DateTime.utc(2026, 1, 1),
      database: BackupDatabaseEntry(
        archivePath: BackupValues.databaseArchivePath,
        sizeBytes: 10,
        sha256: sha256Hex(zero10),
      ),
      managedFiles: const <BackupManagedFileEntry>[],
    );
    final bomb = List<int>.filled(1024 * 1024, 0);
    final archive = Archive()
      ..addFile(
        ArchiveFile.string(BackupValues.manifestArchivePath, manifest.encode()),
      )
      ..addFile(
        ArchiveFile(BackupValues.databaseArchivePath, bomb.length, bomb),
      );
    final output = OutputFileStream(package);
    ZipEncoder().encode(archive, output: output);
    output.closeSync();

    // Rewrite declared uncompressed size from 1 MiB to 10 in both headers;
    // the deflate stream still expands to 1 MiB, so only streaming output
    // accounting can stop the bomb.
    final bytes = Uint8List.fromList(File(package).readAsBytesSync());
    final inspectInput = InputFileStream(package);
    final directory = ZipDirectory.read(inspectInput);
    inspectInput.closeSync();
    final dbHeader = directory.fileHeaders.singleWhere(
      (header) => header.filename == BackupValues.databaseArchivePath,
    );
    final localOffset = dbHeader.localHeaderOffset!;
    void writeUint32(int offset, int value) {
      bytes[offset] = value & 0xff;
      bytes[offset + 1] = (value >> 8) & 0xff;
      bytes[offset + 2] = (value >> 16) & 0xff;
      bytes[offset + 3] = (value >> 24) & 0xff;
    }

    writeUint32(localOffset + 18, 10);
    final centralOffset = directory.centralDirectoryOffset;
    var cursor = centralOffset;
    while (cursor + 46 <= bytes.length &&
        bytes[cursor] == 0x50 &&
        bytes[cursor + 1] == 0x4b &&
        bytes[cursor + 2] == 0x01 &&
        bytes[cursor + 3] == 0x02) {
      final nameLength = bytes[cursor + 28] | (bytes[cursor + 29] << 8);
      final extraLength = bytes[cursor + 30] | (bytes[cursor + 31] << 8);
      final commentLength = bytes[cursor + 32] | (bytes[cursor + 33] << 8);
      final name = String.fromCharCodes(
        bytes.sublist(cursor + 46, cursor + 46 + nameLength),
      );
      if (name == BackupValues.databaseArchivePath) {
        writeUint32(cursor + 24, 10);
      }
      cursor += 46 + nameLength + extraLength + commentLength;
    }
    await File(package).writeAsBytes(bytes, flush: true);

    await expectLater(
      BackupArchiveIo.extractAndValidate(
        packagePath: package,
        stagingRoot: p.join(temp.path, 'bomb_staging'),
      ),
      throwsA(isA<BackupException>().having(
        (e) => e.failure,
        'failure',
        BackupFailure.resourceLimitExceeded,
      )),
    );
  });

  test('encrypted package entry is rejected', () async {
    final package = p.join(temp.path, 'encrypted.shiroha');
    final archive = Archive()
      ..addFile(ArchiveFile.string('manifest.json', '{}'))
      ..addFile(ArchiveFile.string('database/shiroha.db', ''));
    final output = OutputFileStream(package);
    ZipEncoder(password: 'secret').encode(archive, output: output);
    output.closeSync();

    await expectLater(
      BackupArchiveIo.readManifestOnly(package),
      throwsA(isA<BackupException>().having(
        (e) => e.failure,
        'failure',
        BackupFailure.unsupportedCompression,
      )),
    );
  });
}
