import 'package:flutter_test/flutter_test.dart';
import 'package:shiroha_quiz/domain/backup/archive_path_policy.dart';
import 'package:shiroha_quiz/domain/backup/backup_failure.dart';
import 'package:shiroha_quiz/domain/backup/backup_manifest.dart';
import 'package:shiroha_quiz/domain/backup/backup_values.dart';

void main() {
  Map<String, Object?> validJson({int? schemaVersion}) => <String, Object?>{
        'format': BackupValues.format,
        'packageVersion': BackupValues.packageVersion,
        'schemaVersion': schemaVersion ?? BackupValues.currentSchemaVersion,
        'createdAtUtc': DateTime.utc(2026, 1, 1).toIso8601String(),
        'database': <String, Object?>{
          'archivePath': BackupValues.databaseArchivePath,
          'sizeBytes': 12,
          'sha256': 'a' * 64,
        },
        'managedFiles': <Object?>[
          <String, Object?>{
            'fileId': 'file-1',
            'storageKey': 'library/file-1',
            'archivePath': 'files/library/file-1',
            'sizeBytes': 3,
            'sha256': 'b' * 64,
          },
        ],
      };

  test('manifest v1 round trip is strict and stable', () {
    final manifest = BackupManifest.fromJson(validJson());
    final decoded = BackupManifest.fromJsonString(manifest.encode());
    expect(decoded.packageVersion, 1);
    expect(decoded.schemaVersion, BackupValues.currentSchemaVersion);
    expect(decoded.database.sizeBytes, 12);
    expect(decoded.managedFiles.single.fileId, 'file-1');
    expect(decoded.totalDeclaredBytes, 15);
  });

  test('malformed json is manifestInvalid', () {
    expect(
      () => BackupManifest.fromJsonString('{'),
      throwsA(isA<BackupException>().having(
        (e) => e.failure,
        'failure',
        BackupFailure.manifestInvalid,
      )),
    );
  });

  test('unknown root fields are rejected', () {
    final json = validJson()..['extra'] = true;
    expect(
      () => BackupManifest.fromJson(json),
      throwsA(isA<BackupException>().having(
        (e) => e.failure,
        'failure',
        BackupFailure.manifestInvalid,
      )),
    );
  });

  test('wrong types are rejected', () {
    final json = validJson();
    json['schemaVersion'] = '23';
    expect(
      () => BackupManifest.fromJson(json),
      throwsA(isA<BackupException>().having(
        (e) => e.failure,
        'failure',
        BackupFailure.manifestInvalid,
      )),
    );
  });

  test('duplicate identities are rejected', () {
    final json = validJson();
    final original = (json['managedFiles']! as List<Object?>).single;
    json['managedFiles'] = <Object?>[
      original,
      Map<String, Object?>.from(original! as Map),
    ];
    expect(
      () => BackupManifest.fromJson(json),
      throwsA(isA<BackupException>().having(
        (e) => e.failure,
        'failure',
        BackupFailure.duplicateArchiveEntry,
      )),
    );
  });

  test('unsafe archive path policy rejects traversal and drive escapes', () {
    for (final path in <String>[
      '',
      '/abs',
      r'C:/x',
      r'C|/x',
      '../x',
      'a/../b',
      'a//b',
      'a/.',
      'a\\b',
    ]) {
      expect(ArchivePathPolicy.isSafeArchivePath(path), isFalse, reason: path);
    }
    expect(ArchivePathPolicy.isSafeArchivePath('files/library/file-1'), isTrue);
  });

  test('path policy detects normalized and case-insensitive duplicates', () {
    expect(
      ArchivePathPolicy.hasCaseInsensitiveCollision(<String>[
        'files/library/File',
        'files/library/file',
      ]),
      isTrue,
    );
    expect(
      ArchivePathPolicy.hasNormalizedDuplicate(<String>[
        'files//library/file',
      ]),
      isTrue,
    );
  });

  test('size ceilings and entry count are enforced', () {
    final huge = validJson();
    huge['database'] = <String, Object?>{
      'archivePath': BackupValues.databaseArchivePath,
      'sizeBytes': BackupValues.databaseMaxDeclaredSizeBytes + 1,
      'sha256': 'a' * 64,
    };
    expect(
      () => BackupManifest.fromJson(huge),
      throwsA(isA<BackupException>().having(
        (e) => e.failure,
        'failure',
        BackupFailure.manifestInvalid,
      )),
    );
  });

  test('json objects without backup shape never leak maps', () {
    expect(
      () => BackupManifest.fromJson(<String, Object?>{'format': 'x'}),
      throwsA(isA<BackupException>()),
    );
  });
}
