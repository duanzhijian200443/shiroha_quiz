import 'dart:convert';
import 'package:sqflite/sqflite.dart';
import 'package:path/path.dart';
import 'dart:io';
import 'package:flutter/foundation.dart';
import '../../data/repositories/ai_engine_repository.dart';

enum DatabaseRuntimeProfile {
  production,
  isolatedSmokeInMemory,
}

class DatabaseHelper {
  DatabaseHelper._();

  static const String _dbName = 'shiroha_core_v1.db';
  static const int _dbVersion = 14;

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

  static DatabaseHelper get instance {
    AiEngineRepository.defaultDatabaseHelperProvider ??=
        () => DatabaseHelper.instance;
    if (_instance == null) {
      final helper = DatabaseHelper._();
      _instance = helper;
      AiEngineRepository.instance = AiEngineRepository(databaseHelper: helper);
    }
    return _instance!;
  }

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
  }

  Future<void> _onUpgrade(Database db, int oldVersion, int newVersion) async {
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

  Future<List<Map<String, dynamic>>> getAiEngines(String type) async {
    final db = await database;
    // 打通文本与视觉的模型列表，共享所有已配置引擎
    return await db.query('ai_engines', orderBy: 'name ASC');
  }

  Future<Map<String, dynamic>?> getActiveAiEngine(String type) async {
    final db = await database;
    // 优先从设置表独立获取该类型激活的引擎 ID
    final activeId = await getSetting('active_${type}_engine_id');
    if (activeId != null) {
      final res = await db.query('ai_engines',
          where: 'id = ?', whereArgs: [activeId], limit: 1);
      if (res.isNotEmpty) return res.first;
    }
    // 兼容老版本逻辑
    final res = await db.query('ai_engines',
        where: 'engine_type = ? AND is_active = 1',
        whereArgs: [type],
        limit: 1);
    if (res.isNotEmpty) return res.first;

    // 如果都没有，尝试找全局任意一个 is_active = 1 的
    final resGlobal =
        await db.query('ai_engines', where: 'is_active = 1', limit: 1);
    return resGlobal.isNotEmpty ? resGlobal.first : null;
  }

  Future<void> saveAiEngine(Map<String, dynamic> engine) async {
    final db = await database;
    await db.insert('ai_engines', engine,
        conflictAlgorithm: ConflictAlgorithm.replace);
  }

  Future<void> setActiveAiEngine(String id, String type) async {
    // 使用设置表独立保存各自激活的引擎，不再互相干扰
    await saveSetting('active_${type}_engine_id', id);

    // 为了向前兼容，依然更新一下 is_active
    final db = await database;
    await db.transaction((txn) async {
      await txn.update('ai_engines', {'is_active': 0},
          where: 'engine_type = ?', whereArgs: [type]);
      await txn.update('ai_engines', {'is_active': 1},
          where: 'id = ?', whereArgs: [id]);
    });
  }

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
    await db.update(
      'questions',
      questionData,
      where: 'id = ?',
      whereArgs: [questionData['id']],
    );
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

    final paperId = 'paper_' + DateTime.now().millisecondsSinceEpoch.toString();
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
          qId = 'ai_q_' +
              DateTime.now().millisecondsSinceEpoch.toString() +
              '_' +
              i.toString();
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
