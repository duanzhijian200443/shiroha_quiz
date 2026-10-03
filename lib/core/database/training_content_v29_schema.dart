import '../../application/home_training_result.dart';
import '../../application/training/training_contracts.dart';
import '../../domain/training/category_key.dart';
import '../../domain/training/training_content.dart';
import '../../domain/training/training_content_member.dart';
import 'ordinary_training_bank_policy.dart';
import 'sqflite_runtime.dart';

const trainingContentSchemaVersion = 29;
const trainingContentsTable = 'training_contents';
const trainingContentMembersTable = 'training_content_members';
const trainingCategoryPreferencesTable = 'training_category_preferences';
const trainingCategoryIndex = 'idx_training_contents_category';
const currentTrainingCategorySetting = 'current_training_category';

const trainingContentsDdl = '''
CREATE TABLE training_contents (
  content_id TEXT PRIMARY KEY NOT NULL,
  category_key TEXT NOT NULL,
  name TEXT NOT NULL,
  question_limit INTEGER NOT NULL
    CHECK(typeof(question_limit) = 'integer' AND question_limit BETWEEN 1 AND 100),
  sort_order INTEGER NOT NULL CHECK(typeof(sort_order) = 'integer'),
  revision INTEGER NOT NULL CHECK(typeof(revision) = 'integer' AND revision > 0)
);
''';
const trainingContentMembersDdl = '''
CREATE TABLE training_content_members (
  content_id TEXT NOT NULL,
  bank_name TEXT NOT NULL,
  weight_percent INTEGER NOT NULL
    CHECK(typeof(weight_percent) = 'integer' AND weight_percent BETWEEN 0 AND 100),
  position INTEGER NOT NULL CHECK(typeof(position) = 'integer' AND position >= 0),
  binding_status TEXT NOT NULL CHECK(binding_status IN ('valid', 'invalidated')),
  invalidation_reason TEXT
    CHECK(invalidation_reason IN ('bankMissing', 'categoryChanged', 'bankIneligible')),
  PRIMARY KEY(content_id, bank_name),
  UNIQUE(content_id, position),
  CHECK(binding_status <> 'valid' OR invalidation_reason IS NULL),
  FOREIGN KEY(content_id) REFERENCES training_contents(content_id) ON DELETE CASCADE
);
''';
const trainingCategoryPreferencesDdl = '''
CREATE TABLE training_category_preferences (
  category_key TEXT PRIMARY KEY NOT NULL,
  visual_key TEXT CHECK(visual_key IN ('math', 'english', 'computerScience', 'genericLearning')),
  current_content_id TEXT,
  revision INTEGER NOT NULL CHECK(typeof(revision) = 'integer' AND revision > 0)
);
''';
const trainingCategoryIndexDdl = '''
CREATE INDEX idx_training_contents_category ON training_contents(category_key);
''';

final class TrainingContentSchemaException implements Exception {
  const TrainingContentSchemaException();
  @override
  String toString() => 'TrainingContentSchemaException(malformedState)';
}

/// Creates only additive configuration objects; fresh creation never seeds.
Future<void> createTrainingContentV29Schema(DatabaseExecutor db) async {
  for (final ddl in _tables.values) {
    await db.execute(
        ddl.replaceFirst('CREATE TABLE ', 'CREATE TABLE IF NOT EXISTS '));
  }
  await db.execute(trainingCategoryIndexDdl.replaceFirst(
      'CREATE INDEX ', 'CREATE INDEX IF NOT EXISTS '));
  // Materialize the existing setting authority even when a historical DB has
  // never used SettingsRepository; this is not a new V3 settings table.
  await db.execute(
      'CREATE TABLE IF NOT EXISTS app_settings (key TEXT PRIMARY KEY, value TEXT)');
}

/// Called exclusively by the pre-v29 upgrade callback, in its transaction.
/// Reopening/deleting configurations/importing banks never invokes this seed.
Future<void> migrateTrainingContentToV29(DatabaseExecutor db) async {
  try {
    await createTrainingContentV29Schema(db);
    await validateTrainingContentV29Schema(db);
    for (final table in _tables.keys) {
      if ((await db.query(table, limit: 1)).isNotEmpty) {
        throw const TrainingContentSchemaException();
      }
    }
    if ((await db.query('app_settings',
            where: 'key = ?', whereArgs: [currentTrainingCategorySetting]))
        .isNotEmpty) {
      throw const TrainingContentSchemaException();
    }
    final legacy = await db.query('app_settings',
        columns: ['value'], where: 'key = ?', whereArgs: ['current_bank']);
    if (legacy.isEmpty || legacy.single['value'] == null) return;
    final bank = legacy.single['value'];
    if (bank is! String) throw const TrainingContentSchemaException();
    if (bank.trim().isEmpty) return;
    if (!await _eligible(db, bank)) return;
    final category = await _bankCategory(db, bank);
    final quotaRows = await db.query('app_settings',
        columns: ['value'],
        where: 'key = ?',
        whereArgs: ['${bank}_daily_quota']);
    final rawQuota = quotaRows.isEmpty ? null : quotaRows.single['value'];
    if (rawQuota != null && rawQuota is! String) {
      throw const TrainingContentSchemaException();
    }
    // Exactly SettingsRepository.getDailyQuota(bank, defaultQuota: 40) input
    // semantics, then the V3 non-positive fallback and upper bound.
    final quota = int.tryParse(rawQuota as String? ?? '') ?? 40;
    const id = 'legacy-current-bank-v29';
    final encoded = const CategoryKeyCodec().encodeString(category);
    await db.insert(trainingContentsTable, {
      'content_id': id,
      'category_key': encoded,
      'name': bank,
      'question_limit': quota <= 0 ? 40 : quota.clamp(1, 100),
      'sort_order': 0,
      'revision': 1,
    });
    await db.insert(trainingContentMembersTable, {
      'content_id': id,
      'bank_name': bank,
      'weight_percent': 100,
      'position': 0,
      'binding_status': TrainingBindingStatus.valid.name,
      'invalidation_reason': null,
    });
    await db.insert(trainingCategoryPreferencesTable, {
      'category_key': encoded,
      'visual_key': null,
      'current_content_id': id,
      'revision': 1,
    });
    await db.insert('app_settings',
        {'key': currentTrainingCategorySetting, 'value': encoded});
    await validateTrainingContentV29Data(db);
  } on TrainingContentSchemaException {
    rethrow;
  } catch (_) {
    throw const TrainingContentSchemaException();
  }
}

const _tables = {
  trainingContentsTable: trainingContentsDdl,
  trainingContentMembersTable: trainingContentMembersDdl,
  trainingCategoryPreferencesTable: trainingCategoryPreferencesDdl,
};

String _sql(String value) => value
    .replaceAll(RegExp(r'\bIF\s+NOT\s+EXISTS\b'), '')
    .replaceAll(RegExp(r'\s+'), ' ')
    .replaceAll(RegExp(r'\s*([(),=])\s*'), r'$1')
    .replaceAll(RegExp(r';\s*$'), '')
    .trim();

/// Exact persisted shape, including CHECKs/keys/FK actions, with no repairs.
Future<void> validateTrainingContentV29Schema(DatabaseExecutor db) async {
  try {
    for (final entry in _tables.entries) {
      final rows = await db.rawQuery(
          "SELECT sql FROM sqlite_master WHERE type = 'table' AND name = ?",
          [entry.key]);
      if (rows.length != 1 ||
          _sql(rows.single['sql'] as String) != _sql(entry.value)) {
        throw const TrainingContentSchemaException();
      }
      final indexes = await db.rawQuery('PRAGMA index_list(${entry.key})');
      if (indexes.any((row) => row['origin'] == 'c' && row['unique'] == 1)) {
        throw const TrainingContentSchemaException();
      }
      final triggers = await db.rawQuery(
          "SELECT 1 FROM sqlite_master WHERE type = 'trigger' AND tbl_name = ?",
          [entry.key]);
      if (triggers.isNotEmpty) throw const TrainingContentSchemaException();
    }
    final index = await db.rawQuery(
        "SELECT sql FROM sqlite_master WHERE type = 'index' AND name = ?",
        [trainingCategoryIndex]);
    if (index.length != 1 ||
        _sql(index.single['sql'] as String) != _sql(trainingCategoryIndexDdl)) {
      throw const TrainingContentSchemaException();
    }
    final foreignKeys = await db.rawQuery('PRAGMA foreign_key_check');
    if (foreignKeys.isNotEmpty) throw const TrainingContentSchemaException();
  } on TrainingContentSchemaException {
    rethrow;
  } catch (_) {
    throw const TrainingContentSchemaException();
  }
}

CategoryKey _category(Object? encoded) {
  if (encoded is! String) throw const TrainingContentSchemaException();
  const codec = CategoryKeyCodec();
  final key = codec.decodeString(encoded);
  if (codec.encodeString(key) != encoded) {
    throw const TrainingContentSchemaException();
  }
  return key;
}

Future<bool> _eligible(DatabaseExecutor db, String bank) async {
  final result = await DatabaseOrdinaryTrainingBankEligibility(db)
      .evaluate(OrdinaryTrainingBankInput(bank));
  return switch (result) {
    HomeTrainingSuccess(:final value) =>
      value == OrdinaryTrainingBankEligibilityStatus.eligible,
    HomeTrainingFailed() => throw const TrainingContentSchemaException(),
  };
}

Future<CategoryKey> _bankCategory(DatabaseExecutor db, String bank) async {
  final rows = await db.query('bank_folders',
      columns: ['folder_name'], where: 'bank_name = ?', whereArgs: [bank]);
  if (rows.isEmpty) return const UncategorizedCategoryKey();
  if (rows.length != 1 || rows.single['folder_name'] is! String) {
    throw const TrainingContentSchemaException();
  }
  return FolderCategoryKey(rows.single['folder_name'] as String);
}

/// Portable authoritative state validation, shared by export/staged restore.
/// Invalidated bindings remain historical evidence; valid bindings must prove
/// real-bank eligibility and exact Category without calling self-healing reads.
/// Preference and global Category validation never persist runtime fallback.
Future<void> validateTrainingContentV29Data(DatabaseExecutor db) async {
  try {
    final members = await db.query(trainingContentMembersTable);
    final contents = <String, TrainingContent>{};
    for (final row in await db.query(trainingContentsTable)) {
      final id = row['content_id'] as String;
      final bindings = <TrainingContentMember>[];
      for (final member
          in members.where((member) => member['content_id'] == id)) {
        final binding = TrainingContentMember(
          bankName: member['bank_name'] as String,
          weightPercent: member['weight_percent'] as int,
          position: member['position'] as int,
          bindingStatus: TrainingBindingStatus.values
              .byName(member['binding_status'] as String),
          invalidationReason: member['invalidation_reason'] == null
              ? null
              : TrainingBindingInvalidationReason.values
                  .byName(member['invalidation_reason'] as String),
        );
        bindings.add(binding);
      }
      final content = TrainingContent(
          contentId: id,
          categoryKey: _category(row['category_key']),
          name: row['name'] as String,
          questionLimit: row['question_limit'] as int,
          sortOrder: row['sort_order'] as int,
          revision: row['revision'] as int,
          members: bindings);
      if (contents.containsKey(id)) {
        throw const TrainingContentSchemaException();
      }
      contents[id] = content;
      for (final binding in bindings) {
        if (binding.bindingStatus == TrainingBindingStatus.invalidated) {
          continue;
        }
        if (!await _eligible(db, binding.bankName) ||
            await _bankCategory(db, binding.bankName) != content.categoryKey) {
          throw const TrainingContentSchemaException();
        }
      }
    }
    if (members.any((member) => !contents.containsKey(member['content_id']))) {
      throw const TrainingContentSchemaException();
    }
    for (final row in await db.query(trainingCategoryPreferencesTable)) {
      final key = _category(row['category_key']);
      final current = row['current_content_id'];
      if (current != null &&
          (!contents.containsKey(current) ||
              contents[current]!.categoryKey != key)) {
        throw const TrainingContentSchemaException();
      }
      TrainingCategoryPreference(
          categoryKey: key,
          revision: row['revision'] as int,
          currentContentId: current as String?,
          visualKey: row['visual_key'] == null
              ? null
              : CategoryVisualKey.values.byName(row['visual_key'] as String));
    }
    final settings = await db.query('app_settings',
        columns: ['value'],
        where: 'key = ?',
        whereArgs: [currentTrainingCategorySetting]);
    if (settings.length > 1) throw const TrainingContentSchemaException();
    if (settings.isNotEmpty) _category(settings.single['value']);
  } on TrainingContentSchemaException {
    rethrow;
  } catch (_) {
    throw const TrainingContentSchemaException();
  }
}
