import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive_io.dart';
import 'package:path/path.dart' as p;

import '../../domain/backup/archive_path_policy.dart';
import '../../domain/backup/backup_failure.dart';
import '../../domain/backup/backup_manifest.dart';
import '../../domain/backup/backup_values.dart';
import 'sha256.dart';

final class ExtractedPackage {
  const ExtractedPackage({
    required this.manifest,
    required this.databasePath,
    required this.managedFilesRoot,
  });

  final BackupManifest manifest;
  final String databasePath;
  final String managedFilesRoot;
}

final class ArchiveEntryRecord {
  const ArchiveEntryRecord({
    required this.path,
    required this.compressionMethod,
    required this.encrypted,
    required this.declaredUncompressedSize,
  });

  final String path;
  final int compressionMethod;
  final bool encrypted;
  final int declaredUncompressedSize;
}

/// Streaming ZIP admission/extraction for `.shiroha`.
///
/// The archive package is used only as a ZIP parser/encoder. Extraction never
/// materializes a whole entry in RAM: stored entries are copied in chunks and
/// deflate entries are inflated into a bounded file/hash output stream.
abstract final class BackupArchiveIo {
  static const int _chunkSize = 1024 * 1024;

  static Future<void> writeStoredPackage({
    required String packagePath,
    required String manifestPath,
    required String databasePath,
    required List<ArchiveSourceFile> files,
  }) async {
    final archive = Archive();
    final inputs = <InputFileStream>[];

    try {
      final manifestStream = InputFileStream(manifestPath);
      inputs.add(manifestStream);
      final manifestFile = ArchiveFile.stream(
        BackupValues.manifestArchivePath,
        File(manifestPath).lengthSync(),
        manifestStream,
      )..compress = false;
      archive.addFile(manifestFile);

      final databaseStream = InputFileStream(databasePath);
      inputs.add(databaseStream);
      final databaseFile = ArchiveFile.stream(
        BackupValues.databaseArchivePath,
        File(databasePath).lengthSync(),
        databaseStream,
      )..compress = false;
      archive.addFile(databaseFile);

      for (final source in files) {
        final stream = InputFileStream(source.path);
        inputs.add(stream);
        final file = ArchiveFile.stream(
          BackupValues.managedArchivePath(source.fileId),
          File(source.path).lengthSync(),
          stream,
        )..compress = false;
        archive.addFile(file);
      }

      final output = OutputFileStream(packagePath);
      final encoder = ZipEncoder();
      encoder.encode(archive, output: output, autoClose: false);
      output.flush();
      output.closeSync();
    } finally {
      for (final input in inputs) {
        input.closeSync();
      }
    }
  }

  static List<ArchiveEntryRecord> inspectZipEntries(String packagePath) {
    final input = InputFileStream(packagePath);
    try {
      final directory = ZipDirectory.read(input);
      final records = <ArchiveEntryRecord>[];
      for (final header in directory.fileHeaders) {
        records.add(
          ArchiveEntryRecord(
            path: header.filename,
            compressionMethod: header.compressionMethod,
            encrypted: (header.generalPurposeBitFlag & 0x1) != 0,
            declaredUncompressedSize: header.uncompressedSize ?? -1,
          ),
        );
      }
      return records;
    } finally {
      input.closeSync();
    }
  }

  static Future<BackupManifest> readManifestOnly(String packagePath) async {
    final input = InputFileStream(packagePath);
    try {
      final directory = ZipDirectory.read(input);
      final manifestHeader = _findEntry(
        directory,
        BackupValues.manifestArchivePath,
        allowMissing: false,
      );
      if (manifestHeader == null) {
        throw const BackupException(BackupFailure.invalidPackage);
      }
      _admitHeader(manifestHeader);
      return BackupManifest.fromJsonString(
        utf8.decode(
          await _readEntryBounded(
            manifestHeader,
            BackupValues.manifestEntryMaxBytes,
            hardCeiling: BackupValues.manifestEntryMaxBytes,
          ),
        ),
      );
    } finally {
      input.closeSync();
    }
  }

  static Future<ExtractedPackage> extractAndValidate({
    required String packagePath,
    required String stagingRoot,
  }) async {
    final staging = Directory(stagingRoot);
    await staging.create(recursive: true);

    final input = InputFileStream(packagePath);
    try {
      final directory = ZipDirectory.read(input);
      final headers = directory.fileHeaders;
      if (headers.length > BackupValues.maxArchiveEntries) {
        throw const BackupException(BackupFailure.resourceLimitExceeded);
      }

      final paths = <String>[];
      for (final header in headers) {
        _admitHeader(header);
        if (paths.contains(header.filename)) {
          throw const BackupException(BackupFailure.duplicateArchiveEntry);
        }
        paths.add(header.filename);
      }
      if (ArchivePathPolicy.hasCaseInsensitiveCollision(paths)) {
        throw const BackupException(BackupFailure.duplicateArchiveEntry);
      }

      final manifestHeader = _findEntry(
        directory,
        BackupValues.manifestArchivePath,
        allowMissing: false,
      );
      if (manifestHeader == null) {
        throw const BackupException(BackupFailure.invalidPackage);
      }
      final manifestBytes = await _readEntryBounded(
        manifestHeader,
        BackupValues.manifestEntryMaxBytes,
        hardCeiling: BackupValues.manifestEntryMaxBytes,
      );
      final manifest =
          BackupManifest.fromJsonString(utf8.decode(manifestBytes));

      final expectedPaths = <String>{
        BackupValues.manifestArchivePath,
        BackupValues.databaseArchivePath,
        ...manifest.managedFiles.map((file) => file.archivePath),
      };
      if (expectedPaths.length != headers.length) {
        throw const BackupException(BackupFailure.invalidPackage);
      }
      for (final header in headers) {
        if (!expectedPaths.contains(header.filename)) {
          throw const BackupException(BackupFailure.invalidPackage);
        }
        final declared = header.uncompressedSize ?? -1;
        if (header.filename == BackupValues.manifestArchivePath) {
          if (declared > BackupValues.manifestEntryMaxBytes) {
            throw const BackupException(BackupFailure.resourceLimitExceeded);
          }
          continue;
        }
        final expected = _expectedSizeAndHash(manifest, header.filename);
        if (declared != expected.sizeBytes) {
          throw const BackupException(BackupFailure.manifestInvalid);
        }
      }

      final databasePath = p.join(
        stagingRoot,
        BackupValues.databaseArchivePath,
      );
      final managedRoot = p.join(stagingRoot, 'files', 'library');
      await Directory(p.dirname(databasePath)).create(recursive: true);
      await Directory(managedRoot).create(recursive: true);

      var totalActualBytes = 0;
      for (final header in headers) {
        final zf = header.file;
        if (zf == null) {
          throw const BackupException(BackupFailure.invalidPackage);
        }
        final targetPath = p.join(stagingRoot, header.filename);
        final declaredLimit = _declaredLimitFor(header, manifest);
        final isManifest = header.filename == BackupValues.manifestArchivePath;
        final actualBytes = await _extractEntryStreaming(
          zf,
          targetPath,
          declaredLimit,
          hardCeiling: isManifest
              ? BackupValues.manifestEntryMaxBytes
              : BackupValues.packageMaxDeclaredUncompressedBytes,
        );
        totalActualBytes += actualBytes;
        if (totalActualBytes >
            BackupValues.packageMaxDeclaredUncompressedBytes) {
          throw const BackupException(BackupFailure.resourceLimitExceeded);
        }
        if (isManifest) {
          if (actualBytes > BackupValues.manifestEntryMaxBytes) {
            throw const BackupException(BackupFailure.resourceLimitExceeded);
          }
          continue;
        }
        final expected = _expectedSizeAndHash(manifest, header.filename);
        if (actualBytes != expected.sizeBytes) {
          throw const BackupException(BackupFailure.integrityMismatch);
        }
        if (_sha256File(targetPath) != expected.sha256) {
          throw const BackupException(BackupFailure.integrityMismatch);
        }
      }

      return ExtractedPackage(
        manifest: manifest,
        databasePath: databasePath,
        managedFilesRoot: managedRoot,
      );
    } finally {
      input.closeSync();
    }
  }

  static Future<void> verifyPackage({
    required String packagePath,
    required BackupManifest manifest,
  }) async {
    final temp = await Directory.systemTemp.createTemp('b0_verify_');
    try {
      await extractAndValidate(
        packagePath: packagePath,
        stagingRoot: temp.path,
      );
    } finally {
      if (await temp.exists()) {
        await temp.delete(recursive: true);
      }
    }
  }

  static ({int sizeBytes, String sha256}) _expectedSizeAndHash(
    BackupManifest manifest,
    String archivePath,
  ) {
    if (archivePath == BackupValues.databaseArchivePath) {
      return (
        sizeBytes: manifest.database.sizeBytes,
        sha256: manifest.database.sha256,
      );
    }
    final file = manifest.managedFiles.firstWhere(
      (entry) => entry.archivePath == archivePath,
    );
    return (sizeBytes: file.sizeBytes, sha256: file.sha256);
  }

  static int _declaredLimitFor(
    ZipFileHeader header,
    BackupManifest manifest,
  ) {
    if (header.filename == BackupValues.manifestArchivePath) {
      return BackupValues.manifestEntryMaxBytes;
    }
    if (header.filename == BackupValues.databaseArchivePath) {
      return manifest.database.sizeBytes;
    }
    return manifest.managedFiles
        .firstWhere((file) => file.archivePath == header.filename)
        .sizeBytes;
  }

  static void _admitHeader(ZipFileHeader header) {
    final path = header.filename;
    if (ArchivePathPolicy.unsafeReason(path) != null ||
        ArchivePathPolicy.normalizeAdmittedPath(path) == null) {
      throw const BackupException(BackupFailure.unsafeArchivePath);
    }
    if (path.endsWith('/')) {
      throw const BackupException(BackupFailure.unsafeArchivePath);
    }
    if ((header.generalPurposeBitFlag & 0x1) != 0) {
      throw const BackupException(BackupFailure.unsupportedCompression);
    }
    if (header.compressionMethod != ArchiveFile.STORE &&
        header.compressionMethod != ArchiveFile.DEFLATE) {
      throw const BackupException(BackupFailure.unsupportedCompression);
    }
    final mode = (header.externalFileAttributes ?? 0) >> 16;
    if ((header.versionMadeBy >> 8) == 3 && (mode & 0xf000) == 0xa000) {
      throw const BackupException(BackupFailure.unsafeArchivePath);
    }
  }

  static ZipFileHeader? _findEntry(
    ZipDirectory directory,
    String path, {
    required bool allowMissing,
  }) {
    ZipFileHeader? found;
    for (final header in directory.fileHeaders) {
      if (header.filename == path) {
        if (found != null) {
          throw const BackupException(BackupFailure.duplicateArchiveEntry);
        }
        found = header;
      }
    }
    if (found == null && !allowMissing) {
      throw const BackupException(BackupFailure.invalidPackage);
    }
    return found;
  }

  static Future<Uint8List> _readEntryBounded(
    ZipFileHeader header,
    int declaredLimit, {
    required int hardCeiling,
  }) async {
    final zf = header.file;
    if (zf == null) throw const BackupException(BackupFailure.invalidPackage);
    final raw = zf.rawContent;
    if (raw == null) throw const BackupException(BackupFailure.invalidPackage);
    if (raw.length > BackupValues.manifestEntryMaxBytes) {
      throw const BackupException(BackupFailure.resourceLimitExceeded);
    }
    final declared = header.uncompressedSize ?? -1;
    if (declared < 0 || declared > hardCeiling) {
      throw const BackupException(BackupFailure.resourceLimitExceeded);
    }

    final output = _BoundedBytesOutput(
      hardCeiling: BackupValues.manifestEntryMaxBytes,
    );
    try {
      if (header.compressionMethod == ArchiveFile.DEFLATE) {
        Inflate.stream(raw, output);
      } else {
        _copyRawStream(raw, output, BackupValues.manifestEntryMaxBytes);
      }
    } on BackupException {
      rethrow;
    } catch (_) {
      throw const BackupException(BackupFailure.invalidPackage);
    }
    if (output.length > declaredLimit || output.length > hardCeiling) {
      throw const BackupException(BackupFailure.resourceLimitExceeded);
    }
    return output.bytes;
  }

  static Future<int> _extractEntryStreaming(
    ZipFile zf,
    String targetPath,
    int declaredLimit, {
    required int hardCeiling,
  }) async {
    final raw = zf.rawContent;
    if (raw == null) throw const BackupException(BackupFailure.invalidPackage);
    await File(targetPath).parent.create(recursive: true);
    final file = await File(targetPath).open(mode: FileMode.write);
    final output = _FileHashOutput(file);
    try {
      if (zf.compressionMethod == ArchiveFile.DEFLATE) {
        Inflate.stream(raw, output);
      } else {
        _copyRawStream(raw, output, declaredLimit);
      }
      output.flush();
    } catch (_) {
      await file.close();
      throw const BackupException(BackupFailure.resourceLimitExceeded);
    }
    await file.close();
    return output.length;
  }

  static void _copyRawStream(
    InputStreamBase raw,
    OutputStreamBase output,
    int maxBytes,
  ) {
    var total = 0;
    while (!raw.isEOS) {
      final remaining = maxBytes - total;
      if (remaining <= 0) {
        throw const BackupException(BackupFailure.resourceLimitExceeded);
      }
      final count = remaining < _chunkSize ? remaining : _chunkSize;
      final chunk = raw.readBytes(count).toUint8List();
      if (chunk.isEmpty) break;
      total += chunk.length;
      output.writeBytes(chunk);
    }
  }

  static String _sha256File(String path) {
    final file = File(path).openSync();
    try {
      final hasher = StreamingSha256();
      final chunk = Uint8List(_chunkSize);
      while (true) {
        final read = file.readIntoSync(chunk);
        if (read <= 0) break;
        hasher.update(chunk, 0, read);
      }
      return hasher.digestHex();
    } finally {
      file.closeSync();
    }
  }
}

final class ArchiveSourceFile {
  const ArchiveSourceFile({required this.fileId, required this.path});

  final String fileId;
  final String path;
}

final class _BoundedBytesOutput extends OutputStreamBase {
  _BoundedBytesOutput({required this.hardCeiling});

  final int hardCeiling;
  final BytesBuilder _builder = BytesBuilder(copy: false);
  int _length = 0;

  @override
  int get length => _length;
  Uint8List get bytes => _builder.takeBytes();

  void _ensure(int count) {
    if (_length + count > hardCeiling) {
      throw const BackupException(BackupFailure.resourceLimitExceeded);
    }
  }

  @override
  void flush() {}

  @override
  void writeByte(int value) {
    _ensure(1);
    _builder.addByte(value);
    _length++;
  }

  @override
  void writeBytes(List<int> bytes, [int? len]) {
    final count = len ?? bytes.length;
    _ensure(count);
    _builder.add(bytes is Uint8List ? bytes : Uint8List.fromList(bytes));
    _length += count;
  }

  @override
  void writeInputStream(InputStreamBase stream) {
    while (!stream.isEOS) {
      final chunk = stream
          .readBytes(
            _chunkSizeFor(stream),
          )
          .toUint8List();
      if (chunk.isEmpty) break;
      writeBytes(chunk);
    }
  }

  int _chunkSizeFor(InputStreamBase stream) =>
      stream.length < 1024 * 1024 ? stream.length : 1024 * 1024;

  @override
  void writeUint16(int value) {
    writeByte(value & 0xff);
    writeByte((value >> 8) & 0xff);
  }

  @override
  void writeUint32(int value) {
    writeByte(value & 0xff);
    writeByte((value >> 8) & 0xff);
    writeByte((value >> 16) & 0xff);
    writeByte((value >> 24) & 0xff);
  }

  @override
  void writeUint64(int value) {
    writeByte(value & 0xff);
    writeByte((value >> 8) & 0xff);
    writeByte((value >> 16) & 0xff);
    writeByte((value >> 24) & 0xff);
    writeByte((value >> 32) & 0xff);
    writeByte((value >> 40) & 0xff);
    writeByte((value >> 48) & 0xff);
    writeByte((value >> 56) & 0xff);
  }
}

final class _FileHashOutput extends OutputStreamBase {
  _FileHashOutput(this._file);

  final RandomAccessFile _file;
  final StreamingSha256 _hasher = StreamingSha256();
  int _length = 0;

  @override
  int get length => _length;

  @override
  void flush() => _file.flushSync();

  @override
  void writeByte(int value) {
    _file.writeByteSync(value);
    _hasher.update(<int>[value]);
    _length++;
  }

  @override
  void writeBytes(List<int> bytes, [int? len]) {
    final count = len ?? bytes.length;
    _file.writeFromSync(bytes, 0, count);
    _hasher.update(bytes, 0, count);
    _length += count;
  }

  @override
  void writeInputStream(InputStreamBase stream) {
    const chunkSize = 1024 * 1024;
    while (!stream.isEOS) {
      final count = stream.length < chunkSize ? stream.length : chunkSize;
      final bytes = stream.readBytes(count).toUint8List();
      if (bytes.isEmpty) break;
      writeBytes(bytes);
    }
  }

  @override
  void writeUint16(int value) {
    writeByte(value & 0xff);
    writeByte((value >> 8) & 0xff);
  }

  @override
  void writeUint32(int value) {
    writeByte(value & 0xff);
    writeByte((value >> 8) & 0xff);
    writeByte((value >> 16) & 0xff);
    writeByte((value >> 24) & 0xff);
  }

  @override
  void writeUint64(int value) {
    for (var shift = 0; shift < 64; shift += 8) {
      writeByte((value >> shift) & 0xff);
    }
  }
}
