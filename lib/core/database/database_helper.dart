import 'dart:convert';
import 'package:sqflite/sqflite.dart';
import 'package:path/path.dart';
import 'dart:io';
import 'package:flutter/foundation.dart';
import '../../data/models/ai_engine_profile.dart';
import '../../data/persistence/ai_engine_store.dart';
import '../../data/persistence/question_v2_persistence_mapper.dart';
import 'question_v2_schema_exception.dart';

enum DatabaseRuntimeProfile {
  production,
  isolatedSmokeInMemory,
}

class DatabaseHelper implements AiEngineStore {
  DatabaseHelper._();

  static const String _dbName = 'shiroha_core_v1.db';
  static const int _dbVersion = 15;

  static const String _questionV2SidecarTable = 'question_v2_payloads';

  /// Exact frozen v15 additive sidecar definition.
  static const String _questionV2SidecarDdl = '''
CREATE TABLE question_v2_payloads (
  question_id TEXT PRIMARY KEY NOT NULL,
  payload_schema_version INTEGER NOT NULL CHECK(payload_schema_version > 0),
  payload_json TEXT NOT NULL CHECK(length(payload_json) > 0),
  FOREIGN KEY(question_id) REFERENCES questions(id) ON DELETE CASCADE
);
''';

  /// Idempotent upgrade variant of the same frozen sidecar definition.
  static const String _questionV2SidecarDdlIfNotExists = '''
CREATE TABLE IF NOT EXISTS question_v2_payloads (
  question_id TEXT PRIMARY KEY NOT NULL,
  payload_schema_version INTEGER NOT NULL CHECK(payload_schema_version > 0),
  payload_json TEXT NOT NULL CHECK(length(payload_json) > 0),
  FOREIGN KEY(question_id) REFERENCES questions(id) ON DELETE CASCADE
);
''';

  static DatabaseHelper? _instance;
  static Database? _database;
  static Future<Database>? _openingDatabase;
  static DatabaseRuntimeProfile _runtimeProfile =
      DatabaseRuntimeProfile.production;
  static bool _runtimeProfileConfigured = false;
  static String? _openedDatabasePath;

  static DatabaseRuntimeProfile get runtimeProfile => _runtimeProfile;

  @visibleForTesting
  static String? get openedDatabasePathForTesting => _openedDatabasePath;

  static void configureRuntimeProfile(DatabaseRuntimeProfile profile) {
    if (_runtimeProfileConfigured ||
        _database != null ||
        _openingDatabase != null) {
      throw StateError(
        'Database runtime profile can be configured only once before opening.',
      );
    }
    _runtimeProfile = profile;
    _runtimeProfileConfigured = true;
  }

  static DatabaseHelper get instance => _instance ??= DatabaseHelper._();

  Future<Database> get database async {
    if (_database != null) return _database!;
    if (_openingDatabase != null) return _openingDatabase!;

    _runtimeProfileConfigured = true;
    final opening = _initDatabase();
    _openingDatabase = opening;
    try {
      final database = await opening;
      _database = database;
      return database;
    } finally {
      if (identical(_openingDatabase, opening)) {
        _openingDatabase = null;
      }
    }
  }

  Future<void> close() async {
    final opening = _openingDatabase;
    if (opening != null) {
      try {
        await opening;
      } catch (_) {
        // Opening failures do not leave a database handle to close.
      }
    }
    if (_database != null) {
      await _database!.close();
      _database = null;
    }
    _openedDatabasePath = null;
  }

  /// Opens a database handle with the exact production v15 callbacks.
  ///
  /// Available only under `FLUTTER_TEST`. The returned handle is owned by
  /// the caller and must be closed by the caller. This seam never mutates
  /// the singleton database, opening, path, or runtime-profile state.
  @visibleForTesting
  Future<Database> openPathForTesting(String path) async {
    if (!Platform.environment.containsKey('FLUTTER_TEST')) {
      throw StateError(
        'DatabaseHelper.openPathForTesting requires the FLUTTER_TEST '
        'environment variable.',
      );
    }
    return openDatabase(
      path,
      version: _dbVersion,
      onConfigure: _onConfigure,
      onCreate: _onCreate,
      onUpgrade: _onUpgrade,
    );
  }

  Future<Database> _initDatabase() async {
    final bool isTest = Platform.environment.containsKey('FLUTTER_TEST');
    final useInMemory = isTest ||
        _runtimeProfile == DatabaseRuntimeProfile.isolatedSmokeInMemory;
    final path = useInMemory
        ? inMemoryDatabasePath
        : join(await getDatabasesPath(), _dbName);

    final database = await openDatabase(
      path,
      version: _dbVersion,
      onConfigure: _onConfigure,
      onCreate: _onCreate,
      onUpgrade: _onUpgrade,
    );
    _openedDatabasePath = path;
    return database;
  }

  Future<void> _onConfigure(Database db) async {
    await db.execute('PRAGMA foreign_keys = ON');
  }

  Future<void> _onCreate(Database db, int version) async {
    await db.execute('''
      CREATE TABLE questions (
          id TEXT PRIMARY KEY,
          type INTEGER NOT NULL,
          content TEXT NOT NULL,
          options TEXT,
          standard_answer TEXT NOT NULL,
          explanation TEXT,
          raw_explanation TEXT,
          created_at INTEGER NOT NULL,
          bank_name TEXT DEFAULT '默认题库'
      );
    ''');

    await db.execute(_questionV2SidecarDdl);

    await db.execute('''
      CREATE TABLE review_states (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        question_id TEXT NOT NULL UNIQUE,
        state INTEGER NOT NULL DEFAULT 0,
        next_review_time INTEGER,
        lapses INTEGER NOT NULL DEFAULT 0,
        difficulty REAL NOT NULL DEFAULT 5.0,
        stability REAL NOT NULL DEFAULT 0.0,
        reps INTEGER NOT NULL DEFAULT 0,
        last_lapse_time INTEGER,
        last_review_time INTEGER,
        FOREIGN KEY (question_id) REFERENCES questions(id) ON DELETE CASCADE
      );
    ''');

    await db.execute(
      'CREATE INDEX idx_review_states_question_id ON review_states(question_id);',
    );

    await db.execute('''
      CREATE TABLE review_logs (
        id TEXT PRIMARY KEY,
        question_id TEXT NOT NULL,
        grade INTEGER NOT NULL,
        llm_score REAL,
        review_time INTEGER NOT NULL,
        duration_ms INTEGER NOT NULL,
        user_answer TEXT,
        ai_evaluation TEXT,
        FOREIGN KEY (question_id) REFERENCES questions(id) ON DELETE CASCADE
      );
    ''');

    await db.execute('''
      CREATE TABLE IF NOT EXISTS pomodoro_sessions (
          id TEXT PRIMARY KEY,
          bank_name TEXT NOT NULL,
          start_time INTEGER NOT NULL,
          end_time INTEGER NOT NULL,
          target_duration INTEGER NOT NULL,
          actual_duration INTEGER NOT NULL,
          status INTEGER NOT NULL,
          questions_solved INTEGER NOT NULL
      );
    ''');

    await db.execute('''
      CREATE TABLE IF NOT EXISTS ai_profiles (
        id TEXT PRIMARY KEY,
        name TEXT NOT NULL,
        text_api_key TEXT,
        text_base_url TEXT,
        text_model TEXT,
        vision_api_key TEXT,
        vision_base_url TEXT,
        vision_model TEXT,
        is_active INTEGER DEFAULT 0
      );
    ''');

    await db.execute('''
      CREATE TABLE IF NOT EXISTS bank_folders (
        bank_name TEXT PRIMARY KEY,
        folder_name TEXT NOT NULL DEFAULT '默认学科'
      );
    ''');

    await db.execute('''
      CREATE TABLE IF NOT EXISTS ai_engines (
        id TEXT PRIMARY KEY,
        engine_type TEXT NOT NULL,
        name TEXT NOT NULL,
        api_key TEXT,
        base_url TEXT,
        model_name TEXT,
        temperature REAL DEFAULT 0.7,
        reasoning_effort TEXT DEFAULT '',
        is_active INTEGER DEFAULT 0
      )
    ''');

    await db.execute('''
      CREATE TABLE IF NOT EXISTS import_tasks (
        id TEXT PRIMARY KEY,
        title TEXT NOT NULL,
        status INTEGER NOT NULL,
        progress_text TEXT NOT NULL,
        percent REAL NOT NULL,
        error_msg TEXT,
        parsed_data TEXT,
        bank_name TEXT,
        folder_name TEXT,
        created_at INTEGER NOT NULL,
        completed_at INTEGER,
        source_type TEXT,
        pending_chunks TEXT,
        failed_chunks TEXT,
        warnings TEXT,
        diagnostics TEXT
      );
    ''');

    await _validateV15Schema(db);
  }

  Future<void> _onUpgrade(Database db, int oldVersion, int newVersion) async {
    if (oldVersion < 10) {
      throw const QuestionV2SchemaException(
        QuestionV2SchemaFailure.unsupportedSourceVersion,
      );
    }
    if (oldVersion < 8) {
      try {
        await db.execute('ALTER TABLE review_logs ADD COLUMN user_answer TEXT');
        await db
            .execute('ALTER TABLE review_logs ADD COLUMN ai_evaluation TEXT');
      } catch (e) {
        // Ignore
      }
    }
    if (oldVersion < 9) {
      await db.execute('''
        CREATE TABLE IF NOT EXISTS ai_profiles (
          id TEXT PRIMARY KEY,
          name TEXT NOT NULL,
          text_api_key TEXT,
          text_base_url TEXT,
          text_model TEXT,
          vision_api_key TEXT,
          vision_base_url TEXT,
          vision_model TEXT,
          is_active INTEGER DEFAULT 0
        );
      ''');
    }
    if (oldVersion < 10) {
      await db.execute('''
        CREATE TABLE IF NOT EXISTS ai_engines (
          id TEXT PRIMARY KEY,
          engine_type TEXT NOT NULL,
          name TEXT NOT NULL,
          api_key TEXT,
          base_url TEXT,
          model_name TEXT,
          temperature REAL DEFAULT 0.7,
          reasoning_effort TEXT DEFAULT '',
          is_active INTEGER DEFAULT 0
        )
      ''');
      try {
        await db.execute('''
          INSERT OR IGNORE INTO ai_engines (id, engine_type, name, api_key, base_url, model_name, temperature, reasoning_effort, is_active)
          SELECT id || '_text', 'text', name || ' (文本)', text_api_key, text_base_url, text_model, temperature, reasoning_effort, is_active 
          FROM ai_profiles
        ''');
        await db.execute('''
          INSERT OR IGNORE INTO ai_engines (id, engine_type, name, api_key, base_url, model_name, temperature, reasoning_effort, is_active)
          SELECT id || '_vision', 'vision', name || ' (视觉)', vision_api_key, vision_base_url, vision_model, 0.7, '', is_active 
          FROM ai_profiles
        ''');
      } catch (_) {}
    }
    if (oldVersion < 11) {
      await db.execute('''
        CREATE TABLE IF NOT EXISTS import_tasks (
          id TEXT PRIMARY KEY,
          title TEXT NOT NULL,
          status INTEGER NOT NULL,
          progress_text TEXT NOT NULL,
          percent REAL NOT NULL,
          error_msg TEXT,
          parsed_data TEXT,
          bank_name TEXT,
          folder_name TEXT,
          created_at INTEGER NOT NULL,
          completed_at INTEGER,
          source_type TEXT,
          pending_chunks TEXT,
          failed_chunks TEXT
        )
      ''');
    }
    if (oldVersion < 12) {
      try {
        await db
            .execute('ALTER TABLE import_tasks ADD COLUMN source_type TEXT');
        await db
            .execute('ALTER TABLE import_tasks ADD COLUMN pending_chunks TEXT');
        await db
            .execute('ALTER TABLE import_tasks ADD COLUMN failed_chunks TEXT');
      } catch (e) {
        // Ignore
      }
    }
    if (oldVersion < 13) {
      try {
        await db
            .execute('ALTER TABLE questions ADD COLUMN raw_explanation TEXT');
      } catch (e) {
        // Ignore
      }
    }
    if (oldVersion < 14) {
      try {
        await db.execute('ALTER TABLE import_tasks ADD COLUMN warnings TEXT');
        await db
            .execute('ALTER TABLE import_tasks ADD COLUMN diagnostics TEXT');
      } catch (e) {
        // Ignore
      }
    }
    if (oldVersion < 15) {
      await db.execute(_questionV2SidecarDdlIfNotExists);
    }
    await _validateV15Schema(db);
  }

  /// Validates the frozen v15 schema before the open/upgrade can succeed.
  ///
  /// The open callbacks already run inside the SQLite open transaction, so
  /// this method must not start a nested transaction; a thrown failure rolls
  /// back every DDL change and leaves `user_version` and existing rows
  /// unchanged. The sidecar CHECKs and trigger visibility are exercised by
  /// rollback-only SAVEPOINT probes, so benign sidecar triggers stay allowed
  /// while blocking triggers fail the open through the legal probe path.
  static Future<void> _validateV15Schema(Database db) async {
    final foreignKeys = await db.rawQuery('PRAGMA foreign_keys');
    if (foreignKeys.isEmpty || foreignKeys.first.values.first != 1) {
      throw const QuestionV2SchemaException(
        QuestionV2SchemaFailure.foreignKeysDisabled,
      );
    }

    final tables = <String, String?>{};
    for (final row in await db.rawQuery(
      "SELECT name, sql FROM sqlite_master WHERE type = 'table'",
    )) {
      tables[row['name'] as String] = row['sql'] as String?;
    }

    await _validateSidecarSchema(db, tables);
    await _validateParentSchema(db, tables);
    await _validateBankFoldersSchema(db, tables);
    await _probeSidecarWrites(db);

    final violations = await db.rawQuery('PRAGMA foreign_key_check');
    if (violations.isNotEmpty) {
      throw const QuestionV2SchemaException(
        QuestionV2SchemaFailure.foreignKeyViolation,
      );
    }
  }

  static const List<String> _sidecarColumnOrder = <String>[
    'question_id',
    'payload_schema_version',
    'payload_json',
  ];

  static const List<String> _sidecarColumnAffinities = <String>[
    'TEXT',
    'INTEGER',
    'TEXT',
  ];

  static Future<void> _validateSidecarSchema(
    Database db,
    Map<String, String?> tables,
  ) async {
    final storedSql = tables[_questionV2SidecarTable];
    if (storedSql == null ||
        _canonicalizeSql(storedSql) !=
            _canonicalizeSql(_questionV2SidecarDdl)) {
      throw const QuestionV2SchemaException(
        QuestionV2SchemaFailure.malformedSidecarSchema,
      );
    }

    final columns = await db.rawQuery(
      'PRAGMA table_info(question_v2_payloads)',
    );
    if (columns.length != _sidecarColumnOrder.length) {
      throw const QuestionV2SchemaException(
        QuestionV2SchemaFailure.malformedSidecarSchema,
      );
    }
    for (var index = 0; index < columns.length; index++) {
      final column = columns[index];
      if (column['name'] != _sidecarColumnOrder[index] ||
          column['notnull'] != 1 ||
          _columnAffinity(column['type'] as String? ?? '') !=
              _sidecarColumnAffinities[index]) {
        throw const QuestionV2SchemaException(
          QuestionV2SchemaFailure.malformedSidecarSchema,
        );
      }
    }
    final primaryKeys = columns.where((column) => column['pk'] != 0).toList();
    if (primaryKeys.length != 1 ||
        primaryKeys.single['name'] != 'question_id') {
      throw const QuestionV2SchemaException(
        QuestionV2SchemaFailure.malformedSidecarSchema,
      );
    }

    final foreignKeys = await db.rawQuery(
      'PRAGMA foreign_key_list(question_v2_payloads)',
    );
    if (foreignKeys.length != 1) {
      throw const QuestionV2SchemaException(
        QuestionV2SchemaFailure.malformedSidecarSchema,
      );
    }
    final foreignKey = foreignKeys.single;
    if (foreignKey['table'] != 'questions' ||
        foreignKey['from'] != 'question_id' ||
        foreignKey['to'] != 'id' ||
        foreignKey['on_update'] != 'NO ACTION' ||
        foreignKey['on_delete'] != 'CASCADE') {
      throw const QuestionV2SchemaException(
        QuestionV2SchemaFailure.malformedSidecarSchema,
      );
    }
  }

  /// Required V1 question columns (name, affinity, required NOT NULL).
  static const Map<String, (String, bool)> _requiredQuestionColumns =
      <String, (String, bool)>{
    'id': ('TEXT', false),
    'type': ('INTEGER', true),
    'content': ('TEXT', true),
    'options': ('TEXT', false),
    'standard_answer': ('TEXT', true),
    'explanation': ('TEXT', false),
    'raw_explanation': ('TEXT', false),
    'created_at': ('INTEGER', true),
    'bank_name': ('TEXT', false),
  };

  static Future<void> _validateParentSchema(
    Database db,
    Map<String, String?> tables,
  ) async {
    if (!tables.containsKey('questions')) {
      throw const QuestionV2SchemaException(
        QuestionV2SchemaFailure.malformedParentSchema,
      );
    }
    final columns = await db.rawQuery('PRAGMA table_info(questions)');
    final columnByName = <String, Map<String, Object?>>{
      for (final column in columns) column['name'] as String: column,
    };
    for (final entry in _requiredQuestionColumns.entries) {
      final column = columnByName[entry.key];
      if (column == null ||
          _columnAffinity(column['type'] as String? ?? '') != entry.value.$1 ||
          (entry.value.$2 && column['notnull'] != 1)) {
        throw const QuestionV2SchemaException(
          QuestionV2SchemaFailure.malformedParentSchema,
        );
      }
    }
    final primaryKeys = columns.where((column) => column['pk'] != 0).toList();
    if (primaryKeys.length != 1 || primaryKeys.single['name'] != 'id') {
      throw const QuestionV2SchemaException(
        QuestionV2SchemaFailure.malformedParentSchema,
      );
    }
  }

  static Future<void> _validateBankFoldersSchema(
    Database db,
    Map<String, String?> tables,
  ) async {
    if (!tables.containsKey('bank_folders')) {
      throw const QuestionV2SchemaException(
        QuestionV2SchemaFailure.malformedParentSchema,
      );
    }
    final columns = await db.rawQuery('PRAGMA table_info(bank_folders)');
    if (columns.length != 2) {
      throw const QuestionV2SchemaException(
        QuestionV2SchemaFailure.malformedParentSchema,
      );
    }
    final bankName = columns[0];
    final folderName = columns[1];
    if (bankName['name'] != 'bank_name' ||
        _columnAffinity(bankName['type'] as String? ?? '') != 'TEXT' ||
        bankName['pk'] != 1) {
      throw const QuestionV2SchemaException(
        QuestionV2SchemaFailure.malformedParentSchema,
      );
    }
    if (folderName['name'] != 'folder_name' ||
        _columnAffinity(folderName['type'] as String? ?? '') != 'TEXT' ||
        folderName['notnull'] != 1) {
      throw const QuestionV2SchemaException(
        QuestionV2SchemaFailure.malformedParentSchema,
      );
    }
    final defaultValue =
        (folderName['dflt_value'] as String?)?.replaceAll("'", '');
    if (defaultValue != '默认学科') {
      throw const QuestionV2SchemaException(
        QuestionV2SchemaFailure.malformedParentSchema,
      );
    }
    final primaryKeys = columns.where((column) => column['pk'] != 0).toList();
    if (primaryKeys.length != 1 || primaryKeys.single['name'] != 'bank_name') {
      throw const QuestionV2SchemaException(
        QuestionV2SchemaFailure.malformedParentSchema,
      );
    }
  }

  static const String _sidecarProbeSavepoint = 'r6b_v15_sidecar_probe';
  static const String _sidecarProbeParentPrefix = 'r6b_v15_probe_parent_';
  static const int _sidecarProbeParentMax = 1000000;

  /// Runs rollback-only write probes inside a fixed SAVEPOINT: a synthetic
  /// parent question, a version-0 and an empty-payload sidecar insert that
  /// must each fail via [DatabaseException], and a legal version-2 insert
  /// that must round-trip exactly. Once the SAVEPOINT exists, rollback and
  /// release are always attempted, so the synthetic parent, probe rows, and
  /// any trigger audit rows disappear. SAVEPOINT creation, body, rollback,
  /// and release failures each surface only
  /// [QuestionV2SchemaFailure.malformedSidecarSchema] without retaining or
  /// echoing the raw exception; a fixed original schema failure is preserved
  /// when cleanup succeeds.
  static Future<void> _probeSidecarWrites(Database db) async {
    var savepointCreated = false;
    QuestionV2SchemaException? probeFailure;
    try {
      await db.execute('SAVEPOINT $_sidecarProbeSavepoint');
      savepointCreated = true;
      try {
        final parentId = await _nextSidecarProbeParentId(db);
        await db.insert('questions', <String, Object?>{
          'id': parentId,
          'type': 0,
          'content': 'r6b v15 synthetic probe',
          'options': '["A","B"]',
          'standard_answer': 'A',
          'explanation': 'r6b v15 synthetic probe explanation',
          'raw_explanation': 'r6b v15 synthetic probe raw',
          'created_at': 1,
          'bank_name': 'r6b_v15_probe_bank',
        });
        await _expectSidecarProbeRejected(
          db,
          parentId,
          0,
          '{"synthetic":true}',
        );
        await _expectSidecarProbeRejected(db, parentId, 2, '');
        await db.insert('question_v2_payloads', <String, Object?>{
          'question_id': parentId,
          'payload_schema_version': 2,
          'payload_json': '{"synthetic":true,"r6b":2}',
        });
        final rows = await db.query(
          'question_v2_payloads',
          where: 'question_id = ?',
          whereArgs: <Object?>[parentId],
        );
        if (rows.length != 1 ||
            rows.single['question_id'] != parentId ||
            rows.single['payload_schema_version'] != 2 ||
            rows.single['payload_json'] != '{"synthetic":true,"r6b":2}') {
          throw const QuestionV2SchemaException(
            QuestionV2SchemaFailure.malformedSidecarSchema,
          );
        }
      } on QuestionV2SchemaException catch (error) {
        probeFailure = error;
      } catch (_) {
        probeFailure = const QuestionV2SchemaException(
          QuestionV2SchemaFailure.malformedSidecarSchema,
        );
      }
    } catch (_) {
      probeFailure = const QuestionV2SchemaException(
        QuestionV2SchemaFailure.malformedSidecarSchema,
      );
    } finally {
      if (savepointCreated) {
        try {
          await db.execute('ROLLBACK TO $_sidecarProbeSavepoint');
          await db.execute('RELEASE $_sidecarProbeSavepoint');
        } catch (_) {
          probeFailure = const QuestionV2SchemaException(
            QuestionV2SchemaFailure.malformedSidecarSchema,
          );
        }
      }
    }
    if (probeFailure != null) {
      throw probeFailure;
    }
  }

  /// Expects one sidecar insert to be rejected by the live CHECK constraint.
  /// A statement that succeeds (for example under a `RAISE(IGNORE)` trigger)
  /// means the frozen constraint is not enforced and maps to
  /// [QuestionV2SchemaFailure.malformedSidecarSchema].
  static Future<void> _expectSidecarProbeRejected(
    Database db,
    String parentId,
    int schemaVersion,
    String payloadJson,
  ) async {
    try {
      await db.insert('question_v2_payloads', <String, Object?>{
        'question_id': parentId,
        'payload_schema_version': schemaVersion,
        'payload_json': payloadJson,
      });
    } on DatabaseException {
      return;
    }
    throw const QuestionV2SchemaException(
      QuestionV2SchemaFailure.malformedSidecarSchema,
    );
  }

  /// Deterministic collision-free probe parent id: the first absent integer
  /// candidate in the bounded range 1..1,000,000 for the reserved prefix,
  /// selected by exact-equality queries only. Existing ids with arbitrary
  /// suffixes are never parsed or ordered lexicographically, so nonnumeric,
  /// oversized, or gapped user ids cannot block or collide with another
  /// absent candidate. No random, path, or time input is involved.
  static Future<String> _nextSidecarProbeParentId(Database db) async {
    for (var candidate = 1; candidate <= _sidecarProbeParentMax; candidate++) {
      final rows = await db.rawQuery(
        'SELECT 1 FROM questions WHERE id = ? LIMIT 1',
        <Object?>['$_sidecarProbeParentPrefix$candidate'],
      );
      if (rows.isEmpty) {
        return '$_sidecarProbeParentPrefix$candidate';
      }
    }
    throw const QuestionV2SchemaException(
      QuestionV2SchemaFailure.malformedSidecarSchema,
    );
  }

  /// Token-aware canonical form of one CREATE TABLE statement: comments are
  /// stripped, identifiers are unquoted and lowercased, case and whitespace
  /// are normalized, and the terminal semicolon is removed.
  static String _canonicalizeSql(String sql) {
    final tokens = _sqlTokens(sql);
    if (tokens.length >= 5 &&
        tokens[0] == 'create' &&
        tokens[1] == 'table' &&
        tokens[2] == 'if' &&
        tokens[3] == 'not' &&
        tokens[4] == 'exists') {
      tokens.removeRange(0, 5);
    }
    var result = tokens.join(' ').trim();
    if (result.endsWith(';')) {
      result = result.substring(0, result.length - 1).trim();
    }
    return result;
  }

  static List<String> _sqlTokens(String sql) {
    final tokens = <String>[];
    var index = 0;
    while (index < sql.length) {
      final char = sql[index];
      if (_isSqlWhitespace(char)) {
        index++;
        continue;
      }
      if (char == '-' && index + 1 < sql.length && sql[index + 1] == '-') {
        index += 2;
        while (index < sql.length && sql[index] != '\n') {
          index++;
        }
        continue;
      }
      if (char == '/' && index + 1 < sql.length && sql[index + 1] == '*') {
        index += 2;
        var closed = false;
        while (index < sql.length) {
          if (sql[index] == '*' &&
              index + 1 < sql.length &&
              sql[index + 1] == '/') {
            index += 2;
            closed = true;
            break;
          }
          index++;
        }
        if (!closed) {
          break;
        }
        continue;
      }
      if (char == "'") {
        final start = index;
        index++;
        while (index < sql.length) {
          if (sql[index] == "'") {
            if (index + 1 < sql.length && sql[index + 1] == "'") {
              index += 2;
              continue;
            }
            index++;
            break;
          }
          index++;
        }
        tokens.add(sql.substring(start, index));
        continue;
      }
      if (char == '"' || char == '`') {
        final quote = char;
        index++;
        final start = index;
        while (index < sql.length && sql[index] != quote) {
          index++;
        }
        tokens.add(sql.substring(start, index).toLowerCase());
        if (index < sql.length) {
          index++;
        }
        continue;
      }
      if (char == '[') {
        index++;
        final start = index;
        while (index < sql.length && sql[index] != ']') {
          index++;
        }
        tokens.add(sql.substring(start, index).toLowerCase());
        if (index < sql.length) {
          index++;
        }
        continue;
      }
      final operator = _sqlOperatorAt(sql, index);
      if (operator != null) {
        tokens.add(operator);
        index += operator.length;
        continue;
      }
      if (char == '(' || char == ')' || char == ',' || char == ';') {
        tokens.add(char);
        index++;
        continue;
      }
      final start = index;
      while (index < sql.length) {
        final next = sql[index];
        if (_isSqlWhitespace(next) ||
            next == '(' ||
            next == ')' ||
            next == ',' ||
            next == ';' ||
            next == "'" ||
            next == '"' ||
            next == '`' ||
            next == '[' ||
            _sqlOperatorAt(sql, index) != null ||
            (next == '-' && index + 1 < sql.length && sql[index + 1] == '-') ||
            (next == '/' && index + 1 < sql.length && sql[index + 1] == '*')) {
          break;
        }
        index++;
      }
      tokens.add(sql.substring(start, index).toLowerCase());
    }
    return tokens;
  }

  /// SQL comparison and arithmetic operators, longest first so two-character
  /// operators win over single-character ones. Operators are tokenized so
  /// whitespace around them is irrelevant to canonical equality.
  static const List<String> _sqlOperators = <String>[
    '>=',
    '<=',
    '!=',
    '<>',
    '==',
    '||',
    '+',
    '-',
    '*',
    '/',
    '%',
    '=',
    '<',
    '>',
    '!',
  ];

  static String? _sqlOperatorAt(String sql, int index) {
    for (final operator in _sqlOperators) {
      if (sql.startsWith(operator, index)) {
        return operator;
      }
    }
    return null;
  }

  static bool _isSqlWhitespace(String char) {
    return char == ' ' ||
        char == '\t' ||
        char == '\n' ||
        char == '\r' ||
        char == '\u000B' ||
        char == '\u000C';
  }

  /// SQLite column affinity derived from the declared type.
  static String _columnAffinity(String declaredType) {
    final type = declaredType.toUpperCase();
    if (type.contains('INT')) return 'INTEGER';
    if (type.contains('CHAR') ||
        type.contains('CLOB') ||
        type.contains('TEXT')) {
      return 'TEXT';
    }
    if (type.contains('BLOB') || type.isEmpty) return 'BLOB';
    if (type.contains('REAL') ||
        type.contains('FLOA') ||
        type.contains('DOUB')) {
      return 'REAL';
    }
    return 'NUMERIC';
  }

  static Future<void> deleteDatabaseFile() async {
    final isEphemeral = Platform.environment.containsKey('FLUTTER_TEST') ||
        _runtimeProfile == DatabaseRuntimeProfile.isolatedSmokeInMemory;
    if (isEphemeral) {
      await instance.close();
      return;
    }
    await instance.close();
    final String dbPath = await getDatabasesPath();
    final String path = join(dbPath, _dbName);
    await databaseFactory.deleteDatabase(path);
  }

  @visibleForTesting
  static Future<void> resetRuntimeProfileForTesting() async {
    await instance.close();
    _openingDatabase = null;
    _openedDatabasePath = null;
    _runtimeProfile = DatabaseRuntimeProfile.production;
    _runtimeProfileConfigured = false;
  }

  Future<List<Map<String, dynamic>>> getQuestionBanksSummary() async {
    final db = await instance.database;
    return await db.rawQuery(
        'SELECT bank_name, COUNT(id) as total_count FROM questions GROUP BY bank_name;');
  }

  Future<void> deleteQuestionBank(String bankName) async {
    final db = await instance.database;
    await db.transaction((txn) async {
      await txn.rawDelete(
          'DELETE FROM review_logs WHERE question_id IN (SELECT id FROM questions WHERE bank_name = ?)',
          [bankName]);
      await txn.rawDelete(
          'DELETE FROM review_states WHERE question_id IN (SELECT id FROM questions WHERE bank_name = ?)',
          [bankName]);
      await txn
          .rawDelete('DELETE FROM questions WHERE bank_name = ?', [bankName]);
    });
  }

  Future<void> deleteSingleQuestion(String questionId) async {
    final db = await instance.database;
    await db.transaction((txn) async {
      await txn.rawDelete(
          'DELETE FROM review_logs WHERE question_id = ?', [questionId]);
      await txn.rawDelete(
          'DELETE FROM review_states WHERE question_id = ?', [questionId]);
      await txn.rawDelete('DELETE FROM questions WHERE id = ?', [questionId]);
    });
  }

  Future<void> insertPomodoroSession(Map<String, dynamic> sessionData) async {
    final db = await database;
    await db.insert(
      'pomodoro_sessions',
      sessionData,
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  Future<List<Map<String, dynamic>>> getAiProfiles() async {
    final db = await database;
    return await db.query('ai_profiles', orderBy: 'name ASC');
  }

  Future<void> saveAiProfile(Map<String, dynamic> profile) async {
    final db = await database;
    try {
      await db.execute(
          'ALTER TABLE ai_profiles ADD COLUMN temperature REAL DEFAULT 0.7');
      await db.execute(
          'ALTER TABLE ai_profiles ADD COLUMN reasoning_effort TEXT DEFAULT ""');
    } catch (_) {}
    await db.insert('ai_profiles', profile,
        conflictAlgorithm: ConflictAlgorithm.replace);
  }

  Future<void> setActiveAiProfile(String id) async {
    final db = await database;
    await db.transaction((txn) async {
      await txn.update('ai_profiles', {'is_active': 0});
      await txn.update('ai_profiles', {'is_active': 1},
          where: 'id = ?', whereArgs: [id]);
    });
  }

  Future<void> deleteAiProfile(String id) async {
    final db = await database;
    await db.delete('ai_profiles', where: 'id = ?', whereArgs: [id]);
  }

  Future<Map<String, List<Map<String, dynamic>>>> getSubjectTree() async {
    final db = await database;

    // 热修复：强制确保映射表存在（绕过 onCreate 未触发的问题）
    await db.execute('''
      CREATE TABLE IF NOT EXISTS bank_folders (
        bank_name TEXT PRIMARY KEY,
        folder_name TEXT NOT NULL DEFAULT '默认学科'
      )
    ''');
    await db.execute(
        'CREATE TABLE IF NOT EXISTS custom_folders (name TEXT PRIMARY KEY)');
    await db.execute(
        'CREATE TABLE IF NOT EXISTS app_settings (key TEXT PRIMARY KEY, value TEXT)');
    await db.execute(
        'CREATE INDEX IF NOT EXISTS idx_questions_bank_name ON questions(bank_name)');

    // 绝对自愈防御：自动修复由于历史 AI 幻觉导致的题型分类错误
    await db.execute('''
      UPDATE questions 
      SET type = 0 
      WHERE options IS NOT NULL 
        AND options != '' 
        AND options != '[]' 
        AND type != 0
        AND NOT EXISTS (
          SELECT 1 FROM $_questionV2SidecarTable p WHERE p.question_id = questions.id
        )
    ''');

    // 绝对自愈防御2：自动修复由于早期 AI 组卷漏插入复习状态而导致的“幽灵题目”（自动归为已掌握）
    await db.execute('''
      INSERT INTO review_states (question_id, state, difficulty, stability, last_review_time, next_review_time, reps, lapses, last_lapse_time)
      SELECT id, 0, 5.0, 0.0, 0, 0, 0, 0, 0 
      FROM questions 
      WHERE id NOT IN (SELECT question_id FROM review_states)
    ''');

    final List<Map<String, dynamic>> bankStats = await db.rawQuery('''
      SELECT bank_name, COUNT(id) as count 
      FROM questions 
      GROUP BY bank_name
    ''');

    final List<Map<String, dynamic>> mappings = await db.query('bank_folders');
    final Map<String, String> folderMap = {
      for (var item in mappings)
        item['bank_name'] as String: item['folder_name'] as String
    };

    Map<String, List<Map<String, dynamic>>> tree = {};
    for (var stat in bankStats) {
      String bName = stat['bank_name'] as String;
      int count = stat['count'] as int;
      String folder = folderMap[bName] ?? '📁 未分类题库';

      if (!tree.containsKey(folder)) {
        tree[folder] = [];
      }
      tree[folder]!.add({'name': bName, 'count': count});
    }

    final List<Map<String, dynamic>> emptyFolders =
        await db.query('custom_folders');
    for (var f in emptyFolders) {
      String fName = f['name'] as String;
      if (!tree.containsKey(fName)) {
        tree[fName] = []; // 注入空文件夹
      }
    }

    return tree;
  }

  Future<void> updateBankFolder(String bankName, String folderName) async {
    final db = await database;
    await db.insert(
      'bank_folders',
      {'bank_name': bankName, 'folder_name': folderName},
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  Future<void> addCustomFolder(String folderName) async {
    final db = await database;
    await db.insert(
      'custom_folders',
      {'name': folderName},
      conflictAlgorithm: ConflictAlgorithm.ignore,
    );
  }

  Future<void> saveSetting(String key, String value) async {
    final db = await database;
    await db.execute(
        'CREATE TABLE IF NOT EXISTS app_settings (key TEXT PRIMARY KEY, value TEXT)');
    await db.insert('app_settings', {'key': key, 'value': value},
        conflictAlgorithm: ConflictAlgorithm.replace);
  }

  Future<String?> getSetting(String key) async {
    final db = await database;
    await db.execute(
        'CREATE TABLE IF NOT EXISTS app_settings (key TEXT PRIMARY KEY, value TEXT)');
    final result =
        await db.query('app_settings', where: 'key = ?', whereArgs: [key]);
    if (result.isNotEmpty) {
      return result.first['value'] as String?;
    }
    return null;
  }

  Future<Map<String, dynamic>?> getActiveAiProfile() async {
    final db = await database;
    try {
      await db.execute(
          'ALTER TABLE ai_profiles ADD COLUMN temperature REAL DEFAULT 0.7');
      await db.execute(
          'ALTER TABLE ai_profiles ADD COLUMN reasoning_effort TEXT DEFAULT ""');
    } catch (_) {}
    final result =
        await db.query('ai_profiles', where: 'is_active = 1', limit: 1);
    if (result.isNotEmpty) {
      return result.first;
    }
    return null;
  }

  @override
  Future<List<AiEngineProfile>> listAiEngines(AiEngineType type) async {
    final db = await database;
    // 打通文本与视觉的模型列表，共享所有已配置引擎
    final rows = await db.query('ai_engines', orderBy: 'name ASC');
    return rows
        .map(
          (row) => AiEngineProfile.fromMap(
            row,
            fallbackType: type,
          ),
        )
        .toList(growable: false);
  }

  @override
  Future<AiEngineProfile?> getActiveAiEngine(AiEngineType type) async {
    final db = await database;
    final dbValue = type.dbValue;
    // 优先从设置表独立获取该类型激活的引擎 ID
    final activeId = await getSetting('active_${dbValue}_engine_id');
    if (activeId != null) {
      final res = await db.query('ai_engines',
          where: 'id = ?', whereArgs: [activeId], limit: 1);
      if (res.isNotEmpty) {
        return AiEngineProfile.fromMap(res.first, fallbackType: type);
      }
    }
    // 兼容老版本逻辑
    final res = await db.query('ai_engines',
        where: 'engine_type = ? AND is_active = 1',
        whereArgs: [dbValue],
        limit: 1);
    if (res.isNotEmpty) {
      return AiEngineProfile.fromMap(res.first, fallbackType: type);
    }

    // 如果都没有，尝试找全局任意一个 is_active = 1 的
    final resGlobal =
        await db.query('ai_engines', where: 'is_active = 1', limit: 1);
    return resGlobal.isNotEmpty
        ? AiEngineProfile.fromMap(resGlobal.first, fallbackType: type)
        : null;
  }

  @override
  Future<void> saveAiEngine(AiEngineProfile profile) async {
    final db = await database;
    await db.insert('ai_engines', profile.toMap(),
        conflictAlgorithm: ConflictAlgorithm.replace);
  }

  @override
  Future<void> setActiveAiEngine(String id, AiEngineType type) async {
    final dbValue = type.dbValue;
    // 使用设置表独立保存各自激活的引擎，不再互相干扰
    await saveSetting('active_${dbValue}_engine_id', id);

    // 为了向前兼容，依然更新一下 is_active
    final db = await database;
    await db.transaction((txn) async {
      await txn.update('ai_engines', {'is_active': 0},
          where: 'engine_type = ?', whereArgs: [dbValue]);
      await txn.update('ai_engines', {'is_active': 1},
          where: 'id = ?', whereArgs: [id]);
    });
  }

  @override
  Future<void> deleteAiEngine(String id) async {
    final db = await database;
    await db.delete('ai_engines', where: 'id = ?', whereArgs: [id]);
  }

  Future<String> getFolderForBank(String bankName) async {
    final db = await database;
    final result = await db.query('bank_folders',
        columns: ['folder_name'],
        where: 'bank_name = ?',
        whereArgs: [bankName],
        limit: 1);
    if (result.isNotEmpty) {
      return result.first['folder_name'] as String;
    }
    return '📁 未分类题库';
  }

  Future<List<Map<String, dynamic>>> getQuestionsByBank(String bankName) async {
    final db = await database;

    // 核心拦截：虚空错题本映射
    if (bankName == '🔥 全局错题本') {
      return await db.rawQuery('''
        SELECT q.* 
        FROM questions q
        JOIN review_states r ON q.id = r.question_id
        WHERE r.lapses > 0
        ORDER BY r.last_lapse_time DESC
      ''');
    }

    return await db.query('questions',
        where: 'bank_name = ?',
        whereArgs: [bankName],
        orderBy: 'created_at DESC');
  }

  // --- 高级数据结构: 挂载 FTS5 倒排索引检索引擎 ---
  Future<List<Map<String, dynamic>>> searchQuestionsByBank(
      String bankName, String keyword) async {
    final db = await database;

    // 1. 初始化/热挂载 FTS 虚拟表引擎与自动化触发器
    try {
      await db.execute(
          'CREATE VIRTUAL TABLE IF NOT EXISTS questions_fts USING fts5(id UNINDEXED, content, options, explanation)');
      // 植入自动化监控挂钩
      await db.execute(
          'CREATE TRIGGER IF NOT EXISTS q_ai AFTER INSERT ON questions BEGIN INSERT INTO questions_fts(id, content, options, explanation) VALUES (new.id, new.content, new.options, new.explanation); END;');
      await db.execute(
          'CREATE TRIGGER IF NOT EXISTS q_ad AFTER DELETE ON questions BEGIN DELETE FROM questions_fts WHERE id = old.id; END;');
      await db.execute(
          'CREATE TRIGGER IF NOT EXISTS q_au AFTER UPDATE ON questions BEGIN DELETE FROM questions_fts WHERE id = old.id; INSERT INTO questions_fts(id, content, options, explanation) VALUES (new.id, new.content, new.options, new.explanation); END;');
      // 热注入清洗：扫描旧有无索引数据填补至虚拟表
      await db.execute(
          'INSERT INTO questions_fts(id, content, options, explanation) SELECT id, content, options, explanation FROM questions WHERE id NOT IN (SELECT id FROM questions_fts)');
    } catch (e) {
      debugPrint('FTS5 引擎热启动挂载报警 (继续降级执行): $e');
    }

    if (keyword.trim().isEmpty) return getQuestionsByBank(bankName);

    // 2. FTS5 O(1) 极速模式（带特殊字符双重引号保护，防范特殊公式解析崩溃）
    try {
      final safeMatchStr = '"${keyword.replaceAll('"', '""')}"';
      return await db.rawQuery('''
        SELECT q.* FROM questions q
        JOIN questions_fts f ON q.id = f.id
        WHERE q.bank_name = ? AND questions_fts MATCH ?
        ORDER BY rank
      ''', [bankName, safeMatchStr]);
    } catch (e) {
      debugPrint('FTS5 O(1)解析受限，强行切换 O(N) 备用引擎: $e');
      // 3. 极限降级路由，保证 100% 高可用 (Fallback)
      return await db.rawQuery('''
        SELECT * FROM questions 
        WHERE bank_name = ? AND (content LIKE ? OR explanation LIKE ?)
        ORDER BY created_at DESC
      ''', [bankName, '%$keyword%', '%$keyword%']);
    }
  }

  // --- 多巴胺引擎：获取热力图聚合数据 ---
  Future<Map<DateTime, int>> getHeatmapData() async {
    final db = await database;
    // 将 INT64 的 Unix 秒级时间戳转换为本地日期的字符串进行聚合统计
    final List<Map<String, dynamic>> maps = await db.rawQuery('''
      SELECT date(review_time, 'unixepoch', 'localtime') as date_str, COUNT(id) as count
      FROM review_logs
      GROUP BY date_str
    ''');

    Map<DateTime, int> heatmap = {};
    for (var map in maps) {
      if (map['date_str'] != null) {
        final parts = map['date_str'].toString().split('-');
        if (parts.length == 3) {
          // 归一化为午夜零点的 DateTime 作为 Key
          final date = DateTime(
              int.parse(parts[0]), int.parse(parts[1]), int.parse(parts[2]));
          heatmap[date] = map['count'] as int;
        }
      }
    }
    return heatmap;
  }

  Future<void> updateQuestion(Map<String, dynamic> questionData) async {
    final db = await database;
    final questionId = questionData['id'];
    await db.transaction((txn) async {
      final sidecar = await txn.query(
        _questionV2SidecarTable,
        columns: ['question_id'],
        where: 'question_id = ?',
        whereArgs: [questionId],
        limit: 1,
      );
      if (sidecar.isNotEmpty) {
        throw const QuestionV2LegacyMutationBlockedException();
      }
      await txn.update(
        'questions',
        questionData,
        where: 'id = ?',
        whereArgs: [questionId],
      );
    });
  }

  // --- 全真模拟考场：极速随机抽题引擎 ---
  Future<List<Map<String, dynamic>>> generateMockExamPaper(
      String bankName, int singleCount, int subjectiveCount) async {
    final db = await database;

    // 1. 抽取单选题 (type = 0)
    final List<Map<String, dynamic>> singles = await db.rawQuery('''
      SELECT * FROM questions 
      WHERE bank_name = ? AND type = 0 
      ORDER BY RANDOM() 
      LIMIT ?
    ''', [bankName, singleCount]);

    // 2. 抽取主观题 (填空 type=2, 简答 type=3)
    final List<Map<String, dynamic>> subjectives = await db.rawQuery('''
      SELECT * FROM questions 
      WHERE bank_name = ? AND type IN (2, 3) 
      ORDER BY RANDOM() 
      LIMIT ?
    ''', [bankName, subjectiveCount]);

    // 3. 组合试卷
    return [...singles, ...subjectives];
  }

  // --- 模考中心：底层数据流 ---

  Future<void> _ensureExamTablesExist(dynamic db) async {
    try {
      // 核心热修复：为旧版题库追加解析字段，完美兼容 AI 生成的题目
      await db.execute(
          'ALTER TABLE questions ADD COLUMN explanation TEXT DEFAULT ""');
      await db.execute('ALTER TABLE questions ADD COLUMN raw_explanation TEXT');
    } catch (_) {}

    // --- 极速检索引擎：FTS5 虚拟表与触发器 ---
    await db.execute(
        'CREATE VIRTUAL TABLE IF NOT EXISTS questions_fts USING fts5(id UNINDEXED, content, options, explanation)');

    // 注入自动化监控挂钩 (增删改自动同步倒排索引)
    await db.execute(
        'CREATE TRIGGER IF NOT EXISTS q_ai AFTER INSERT ON questions BEGIN INSERT INTO questions_fts(id, content, options, explanation) VALUES (new.id, new.content, new.options, new.explanation); END;');
    await db.execute(
        'CREATE TRIGGER IF NOT EXISTS q_ad AFTER DELETE ON questions BEGIN DELETE FROM questions_fts WHERE id = old.id; END;');
    await db.execute(
        'CREATE TRIGGER IF NOT EXISTS q_au AFTER UPDATE ON questions BEGIN DELETE FROM questions_fts WHERE id = old.id; INSERT INTO questions_fts(id, content, options, explanation) VALUES (new.id, new.content, new.options, new.explanation); END;');

    // 热注入清洗：扫描旧有无索引数据填补至虚拟表
    await db.execute(
        'INSERT INTO questions_fts(id, content, options, explanation) SELECT id, content, options, explanation FROM questions WHERE id NOT IN (SELECT id FROM questions_fts)');

    await db.execute('''
      CREATE TABLE IF NOT EXISTS exam_papers (
        id TEXT PRIMARY KEY,
        title TEXT NOT NULL,
        source_type INTEGER NOT NULL, -- 0: 题库随机抽取, 1: AI 魔法生成
        status INTEGER NOT NULL DEFAULT 0, -- 0: 未开始, 1: 已交卷/批改中, 2: 已出分
        score REAL DEFAULT 0.0,
        total_score REAL DEFAULT 0.0,
        created_at INTEGER NOT NULL
      )
    ''');
    await db.execute('''
      CREATE TABLE IF NOT EXISTS paper_questions (
        paper_id TEXT NOT NULL,
        question_id TEXT NOT NULL,
        user_answer TEXT,
        is_correct INTEGER DEFAULT 0,
        order_index INTEGER NOT NULL,
        PRIMARY KEY (paper_id, question_id)
      )
    ''');
  }

  // 创建新试卷 (支持 AI 生成的新题或题库抽取的旧题)
  Future<String> createExamPaper(String title, int sourceType,
      List<Map<String, dynamic>> questions) async {
    final db = await database;
    await _ensureExamTablesExist(db);

    final paperId = 'paper_${DateTime.now().millisecondsSinceEpoch}';
    final nowUnix = DateTime.now().millisecondsSinceEpoch ~/ 1000;

    await db.transaction((txn) async {
      // 1. 创建试卷主记录
      await txn.insert('exam_papers', {
        'id': paperId,
        'title': title,
        'source_type': sourceType,
        'status': 0,
        'score': 0.0,
        'total_score': questions.length * 1.0, // 暂定每题 1 分
        'created_at': nowUnix,
      });

      // 2. 关联题目
      for (int i = 0; i < questions.length; i++) {
        final q = questions[i];
        String qId = q['id']?.toString() ?? '';

        // 如果是 AI 刚生成的题，没有 ID，需要先强制落盘到 questions 表
        if (qId.isEmpty) {
          qId = 'ai_q_${DateTime.now().millisecondsSinceEpoch}_$i';
          await txn.insert('questions', {
            'id': qId,
            'bank_name': '📦 模考专属题库', // 隐藏题库，不污染日常刷题
            'type': q['type'] ?? 0,
            'content': q['content'],
            'options': q['options'] != null ? jsonEncode(q['options']) : '[]',
            'standard_answer': q['standard_answer'],
            'explanation': q['explanation'] ?? '',
            'created_at': nowUnix,
          });
          // 模考题不强制加入 FSRS 调度，除非用户考完后手动收藏
        }

        await txn.insert('paper_questions', {
          'paper_id': paperId,
          'question_id': qId,
          'user_answer': '',
          'is_correct': 0,
          'order_index': i,
        });
      }
    });

    return paperId;
  }

  // 获取所有试卷列表
  Future<List<Map<String, dynamic>>> getAllExamPapers() async {
    final db = await database;
    await _ensureExamTablesExist(db);
    return await db.query('exam_papers', orderBy: 'created_at DESC');
  }

  // 获取某张试卷的所有题目详情
  Future<List<Map<String, dynamic>>> getPaperQuestionsDetail(
      String paperId) async {
    final db = await database;
    return await db.rawQuery('''
      SELECT q.*, pq.user_answer, pq.is_correct, pq.order_index 
      FROM paper_questions pq
      JOIN questions q ON pq.question_id = q.id
      WHERE pq.paper_id = ?
      ORDER BY pq.order_index ASC
    ''', [paperId]);
  }

  // 删除试卷
  Future<void> deleteExamPaper(String paperId) async {
    final db = await database;
    await db.transaction((txn) async {
      await txn.delete('paper_questions',
          where: 'paper_id = ?', whereArgs: [paperId]);
      await txn.delete('exam_papers', where: 'id = ?', whereArgs: [paperId]);
    });
  }

  // --- 阅卷引擎：提交试卷并批改客观题 ---
  Future<List<Map<String, dynamic>>> submitExamPaper(
      String paperId,
      Map<int, dynamic> userAnswers,
      List<Map<String, dynamic>> questions) async {
    final db = await database;
    double earnedScore = 0.0;
    bool hasSubjective = false;
    List<Map<String, dynamic>> subjectiveTasks = [];

    await db.transaction((txn) async {
      for (int i = 0; i < questions.length; i++) {
        final q = questions[i];
        final type = q['type'] as int? ?? 0;
        final uAns = userAnswers[i];
        String uAnsStr = '';
        int isCorrect = 0;

        if (type == 0) {
          // 客观题：极速比对 ABCD
          if (uAns != null && uAns is int) {
            List opts = [];
            try {
              opts = jsonDecode(q['options'].toString());
            } catch (_) {}
            if (uAns >= 0 && uAns < opts.length) {
              uAnsStr = opts[uAns].toString();
              String sAns =
                  q['standard_answer'].toString().trim().toUpperCase();
              String optionLetter =
                  String.fromCharCode(65 + uAns); // 0->A, 1->B
              // 容错比对：匹配字母或全文本
              if (sAns.startsWith(optionLetter) ||
                  uAnsStr == q['standard_answer'].toString().trim()) {
                isCorrect = 1;
                earnedScore += 1.0; // 暂定每题 1 分
              }
            }
          }
        } else {
          // 主观题：收集任务交由 AI 后台处理
          hasSubjective = true;
          uAnsStr = uAns?.toString() ?? '';
          if (uAnsStr.isNotEmpty) {
            subjectiveTasks.add({
              'qId': q['id'],
              'question': q['content'],
              'sAns': q['standard_answer'],
              'uAns': uAnsStr
            });
          }
        }

        await txn.update(
            'paper_questions',
            {
              'user_answer': uAnsStr,
              'is_correct': isCorrect,
            },
            where: 'paper_id = ? AND question_id = ?',
            whereArgs: [paperId, q['id']]);
      }

      // 更新试卷状态：如果有主观题则进入批改中(1)，否则直接出分(2)
      await txn.update(
          'exam_papers',
          {
            'status': hasSubjective ? 1 : 2,
            'score': earnedScore,
          },
          where: 'id = ?',
          whereArgs: [paperId]);
    });

    return subjectiveTasks;
  }

  // --- 阅卷引擎：AI 批改单题落盘 ---
  Future<void> updateExamAiScore(String paperId, String questionId,
      String feedback, double scoreRatio) async {
    final db = await database;
    await db.transaction((txn) async {
      final res = await txn.query('paper_questions',
          columns: ['user_answer'],
          where: 'paper_id = ? AND question_id = ?',
          whereArgs: [paperId, questionId]);
      String oldAns = res.isNotEmpty ? res.first['user_answer'] as String : '';

      // 将 AI 的评价追加到用户答案下方，供后续查阅
      String newAns = "【我的回答】\n$oldAns\n\n【AI 阅卷官】\n$feedback";

      await txn.update(
          'paper_questions',
          {
            'user_answer': newAns,
            'is_correct': scoreRatio >= 0.6 ? 1 : 0, // 及格即算对
          },
          where: 'paper_id = ? AND question_id = ?',
          whereArgs: [paperId, questionId]);

      // 累加试卷总分
      await txn.rawUpdate(
          'UPDATE exam_papers SET score = score + ? WHERE id = ?',
          [scoreRatio, paperId]);
    });
  }

  // --- 阅卷引擎：完卷封板 ---
  Future<void> finishExamGrading(String paperId) async {
    final db = await database;
    await db.update('exam_papers', {'status': 2},
        where: 'id = ?', whereArgs: [paperId]);
  }

  Future<List<Map<String, dynamic>>> searchQuestions(
      String bankName, String keyword) async {
    final db = await database;
    if (keyword.trim().isEmpty) return getQuestionsByBank(bankName);

    try {
      // FTS5 O(1) 匹配模式
      final safeMatchStr = '"${keyword.replaceAll('"', '""')}"';
      // 如果是虚空错题本，特殊处理
      if (bankName == '🔥 全局错题本') {
        return await db.rawQuery('''
          SELECT q.* FROM questions q
          JOIN review_states r ON q.id = r.question_id
          JOIN questions_fts f ON q.id = f.id
          WHERE r.lapses > 0 AND questions_fts MATCH ?
        ''', [safeMatchStr]);
      }
      return await db.rawQuery('''
        SELECT q.* FROM questions q
        JOIN questions_fts f ON q.id = f.id
        WHERE q.bank_name = ? AND questions_fts MATCH ?
      ''', [bankName, safeMatchStr]);
    } catch (e) {
      // 优雅降级：遇到无法解析的特殊符号，退回 O(N) 的 LIKE 兜底
      String likeQuery = '%$keyword%';
      if (bankName == '🔥 全局错题本') {
        return await db.rawQuery('''
          SELECT q.* FROM questions q
          JOIN review_states r ON q.id = r.question_id
          WHERE r.lapses > 0 AND (q.content LIKE ? OR q.explanation LIKE ?)
        ''', [likeQuery, likeQuery]);
      }
      return await db.rawQuery('''
        SELECT * FROM questions 
        WHERE bank_name = ? AND (content LIKE ? OR explanation LIKE ?)
      ''', [bankName, likeQuery, likeQuery]);
    }
  }

  // --- 解析任务持久化方法 ---
  Future<void> saveImportTask(Map<String, dynamic> taskData) async {
    final db = await database;
    await db.insert(
      'import_tasks',
      taskData,
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  Future<void> deleteImportTask(String taskId) async {
    final db = await database;
    await db.delete(
      'import_tasks',
      where: 'id = ?',
      whereArgs: [taskId],
    );
  }

  Future<void> clearCompletedImportTasks() async {
    final db = await database;
    await db.delete(
      'import_tasks',
      where: 'status = ? OR status = ?',
      whereArgs: [2, 3], // TaskStatus.completed=2, TaskStatus.error=3
    );
  }

  Future<void> deleteOldImportTasks(int olderThanTimestamp) async {
    final db = await database;
    await db.delete(
      'import_tasks',
      where: 'completed_at IS NOT NULL AND completed_at < ?',
      whereArgs: [olderThanTimestamp],
    );
  }

  Future<List<Map<String, dynamic>>> getAllImportTasks() async {
    final db = await database;
    return await db.query(
      'import_tasks',
      orderBy: 'created_at DESC',
    );
  }

  // --- 错题重练引擎：获取近期错题 ---
  Future<List<Map<String, dynamic>>> getRecentWrongQuestions(
      {int limit = 30}) async {
    final db = await database;
    return await db.rawQuery('''
      SELECT q.*, r.user_answer as last_wrong_answer 
      FROM questions q
      JOIN review_states r ON q.id = r.question_id
      WHERE r.lapses > 0
      ORDER BY r.last_lapse_time DESC
      LIMIT ?
    ''', [limit]);
  }
}
