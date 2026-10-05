import 'package:uuid/uuid.dart';

import '../../application/home_training_result.dart';
import '../../application/training/training_configuration_contracts.dart';
import '../../application/training/training_configuration_projection.dart';
import '../../application/training/training_contracts.dart';
import '../../application/training/today_training_contracts.dart';
import '../../core/database/database_helper.dart';
import '../../core/database/ordinary_training_bank_policy.dart';
import '../../core/database/sqflite_runtime.dart';
import '../../core/database/training_content_v29_schema.dart';
import '../../domain/training/category_key.dart';
import '../../domain/training/training_content.dart';
import '../../domain/training/training_content_member.dart';
import 'training_content_reader.dart';

/// Transaction owner for the frozen configuration ports. All admission and CAS
/// reads use the same executor as their writes. No bank lifecycle hooks or UI
/// wiring are activated here.
final class TrainingConfigurationRepository
    implements
        TrainingCatalogQuery,
        TrainingContentQuery,
        TrainingConfigurationQuery,
        TrainingContentOrderCommand,
        TrainingContentCommand {
  TrainingConfigurationRepository({
    DatabaseHelper? databaseHelper,
    Future<Database> Function()? database,
  }) : _database = database ??
            (() => (databaseHelper ?? DatabaseHelper.instance).database);

  final Future<Database> Function() _database;
  static const _codec = CategoryKeyCodec();

  Future<HomeTrainingResult<T>> _transaction<T>(
      Future<T> Function(Transaction txn) action) async {
    try {
      final db = await _database();
      return HomeTrainingSuccess(await db.transaction(action));
    } on _ConfigurationFailure catch (failure) {
      return HomeTrainingFailed(failure.code);
    } catch (_) {
      // Includes malformed persisted values and SQL/open failures. No cause,
      // path, query text or partial success leaves this boundary.
      return const HomeTrainingFailed(HomeTrainingFailure.unavailable);
    }
  }

  @override
  Future<HomeTrainingResult<TrainingCatalogSnapshot>> capture() =>
      _transaction(_catalog);

  @override
  Future<HomeTrainingResult<TrainingConfigurationSnapshot>>
      readConfiguration() => _transaction((txn) async {
            final catalog = await _catalog(txn);
            final keys = catalog.categories.toSet();
            for (final row in await txn
                .query(trainingContentsTable, columns: ['category_key'])) {
              keys.add(_category(row['category_key']));
            }
            final ordered = keys.toList()..sort(compareTrainingCategories);
            return TrainingConfigurationSnapshot(catalog: catalog, categories: [
              for (final key in ordered) await _list(txn, key, catalog),
            ]);
          });

  @override
  Future<HomeTrainingResult<HomeTrainingUnit>> moveContent(
          MoveTrainingContentRequest request) =>
      _transaction((txn) async {
        final rows = (await txn.query(trainingContentsTable,
                columns: ['content_id', 'revision', 'sort_order'],
                where: 'category_key = ?',
                whereArgs: [_codec.encodeString(request.categoryKey)],
                orderBy: 'sort_order ASC, content_id ASC'))
            .toList();
        if (rows.length != request.orderedTargets.length) {
          throw const _ConfigurationFailure(HomeTrainingFailure.stale);
        }
        for (var i = 0; i < rows.length; i++) {
          final target = request.orderedTargets[i];
          if (rows[i]['content_id'] != target.contentId ||
              rows[i]['revision'] != target.expectedRevision) {
            throw const _ConfigurationFailure(HomeTrainingFailure.stale);
          }
        }
        final from =
            rows.indexWhere((r) => r['content_id'] == request.contentId);
        final to =
            from + (request.direction == TrainingContentMove.up ? -1 : 1);
        if (to < 0 || to >= rows.length) {
          throw const _ConfigurationFailure(HomeTrainingFailure.invalidInput);
        }
        final moving = rows.removeAt(from);
        rows.insert(to, moving);
        // Dense ranks also handle equal or extreme existing sortOrder values.
        // Only changed rows receive a revision; members/preferences are untouched.
        for (var i = 0; i < rows.length; i++) {
          final row = rows[i];
          if (row['sort_order'] == i) continue;
          final revision = row['revision'] as int;
          final changed = await txn.update(trainingContentsTable,
              {'sort_order': i, 'revision': revision + 1},
              where: 'content_id = ? AND revision = ?',
              whereArgs: [row['content_id'], revision]);
          if (changed != 1) {
            throw const _ConfigurationFailure(HomeTrainingFailure.stale);
          }
        }
        return const HomeTrainingUnit();
      });

  Future<TrainingCatalogSnapshot> _catalog(DatabaseExecutor db) async {
    final mappings = {
      for (final row in await db.query('bank_folders'))
        row['bank_name'] as String:
            FolderCategoryKey(row['folder_name'] as String),
    };
    final categories = <CategoryKey>{};
    // Historical fresh DBs may not yet have used the custom-folder authority.
    // Discover absence without materializing a table during a query.
    final custom = await db.rawQuery(
        "SELECT 1 FROM sqlite_master WHERE type = 'table' AND name = 'custom_folders'");
    if (custom.isNotEmpty) {
      for (final row in await db.query('custom_folders')) {
        categories.add(FolderCategoryKey(row['name'] as String));
      }
    }
    final eligibility = DatabaseOrdinaryTrainingBankEligibility(db);
    final banks = <TrainingCatalogBank>[];
    for (final row in await db.rawQuery(
        'SELECT DISTINCT bank_name FROM questions ORDER BY bank_name')) {
      final name = row['bank_name'] as String;
      final key = mappings[name] ?? const UncategorizedCategoryKey();
      final result =
          await eligibility.evaluate(OrdinaryTrainingBankInput(name));
      final eligible = switch (result) {
        HomeTrainingSuccess(:final value) =>
          value == OrdinaryTrainingBankEligibilityStatus.eligible,
        HomeTrainingFailed() =>
          throw const _ConfigurationFailure(HomeTrainingFailure.unavailable),
      };
      categories.add(key);
      banks.add(TrainingCatalogBank(
          bankName: name,
          categoryKey: key,
          ordinaryTrainingEligible: eligible));
    }
    return TrainingCatalogSnapshot(
      categories: categories.toList()..sort(compareTrainingCategories),
      banks: banks,
    );
  }

  CategoryKey _category(Object? encoded) {
    final key = _codec.decodeString(encoded as String);
    if (_codec.encodeString(key) != encoded) {
      throw const _ConfigurationFailure(HomeTrainingFailure.unavailable);
    }
    return key;
  }

  Future<TrainingContent?> _content(DatabaseExecutor db, String id) =>
      readTrainingContent(db, id);

  Future<TrainingCategoryPreference> _preference(
      DatabaseExecutor db, CategoryKey key) async {
    final rows = await db.query(trainingCategoryPreferencesTable,
        where: 'category_key = ?', whereArgs: [_codec.encodeString(key)]);
    if (rows.isEmpty) {
      return TrainingCategoryPreference(categoryKey: key, revision: null);
    }
    final row = rows.single;
    final preference = TrainingCategoryPreference(
      categoryKey: key,
      revision: row['revision'] as int,
      currentContentId: row['current_content_id'] as String?,
      visualKey: row['visual_key'] == null
          ? null
          : CategoryVisualKey.values.byName(row['visual_key'] as String),
    );
    if (preference.currentContentId != null) {
      final content = await _content(db, preference.currentContentId!);
      if (content == null || content.categoryKey != key) {
        throw const _ConfigurationFailure(HomeTrainingFailure.unavailable);
      }
    }
    return preference;
  }

  Future<TrainingCategorySnapshot> _list(DatabaseExecutor db, CategoryKey key,
      TrainingCatalogSnapshot catalog) async {
    final rows = await db.query(trainingContentsTable,
        columns: ['content_id'],
        where: 'category_key = ?',
        whereArgs: [_codec.encodeString(key)],
        orderBy: 'sort_order ASC, content_id ASC');
    final contents = <TrainingContentView>[];
    for (final row in rows) {
      contents.add(projectTrainingContent(
          (await _content(db, row['content_id'] as String))!, catalog));
    }
    return TrainingCategorySnapshot(
        categoryKey: key,
        preference: await _preference(db, key),
        contents: contents);
  }

  @override
  Future<HomeTrainingResult<TrainingCategorySnapshot>> listByCategory(
          CategoryKey categoryKey) =>
      _transaction((txn) async => _list(txn, categoryKey, await _catalog(txn)));

  @override
  Future<HomeTrainingResult<TrainingContentView>> getById(String contentId) =>
      _transaction((txn) async {
        if (contentId.trim().isEmpty) {
          throw const _ConfigurationFailure(HomeTrainingFailure.invalidInput);
        }
        final content = await _content(txn, contentId);
        if (content == null) {
          throw const _ConfigurationFailure(HomeTrainingFailure.notFound);
        }
        return projectTrainingContent(content, await _catalog(txn));
      });

  @override
  Future<HomeTrainingResult<TrainingCurrentSelection>> current() =>
      _transaction(_current);

  Future<
      ({
        TrainingCatalogSnapshot catalog,
        List<TrainingCategorySnapshot> categories,
        TrainingCurrentSelection selection
      })> _context(DatabaseExecutor db) async {
    final catalog = await _catalog(db);
    final keys = catalog.categories.toSet();
    for (final row
        in await db.query(trainingContentsTable, columns: ['category_key'])) {
      keys.add(_category(row['category_key']));
    }
    for (final row in await db
        .query(trainingCategoryPreferencesTable, columns: ['category_key'])) {
      keys.add(_category(row['category_key']));
    }
    final categories = <TrainingCategorySnapshot>[];
    for (final key in keys) {
      categories.add(await _list(db, key, catalog));
    }
    final settings = await db.query('app_settings',
        columns: ['value'],
        where: 'key = ?',
        whereArgs: [currentTrainingCategorySetting]);
    final selection = resolveTrainingCurrent(
      persistedCategoryKey:
          settings.isEmpty ? null : _category(settings.single['value']),
      catalog: catalog,
      categories: categories,
    );
    return (catalog: catalog, categories: categories, selection: selection);
  }

  Future<TrainingCurrentSelection> _current(DatabaseExecutor db) async =>
      (await _context(db)).selection;

  /// Infrastructure-only projection entry: one short read transaction owns
  /// catalog admission, runtime fallback, selection and all training counts.
  Future<HomeTrainingResult<TodayTrainingSnapshot>> readTodayTraining({
    required DateTime capturedNow,
    required DateTime dayStartUtc,
    required DateTime dayEndUtc,
  }) =>
      _transaction((txn) async {
        final context = await _context(txn);
        final selection = context.selection;
        final visible = <CategoryKey>{
          for (final bank in context.catalog.banks)
            if (bank.ordinaryTrainingEligible) bank.categoryKey,
          for (final category in context.categories)
            if (category.contents.isNotEmpty) category.categoryKey,
        }.toList()
          ..sort(compareTrainingCategories);
        const missing = HomeTrainingFailure.unavailable;
        HomeTrainingResult<TrainingCount> newCount =
            const HomeTrainingFailed(missing);
        HomeTrainingResult<TrainingContentSummary> summary =
            const HomeTrainingFailed(missing);
        HomeTrainingResult<TrainingCount> review =
            const HomeTrainingFailed(missing);
        if (selection.categoryKey != null) {
          final banks = context.catalog.banks
              .where((b) =>
                  b.ordinaryTrainingEligible &&
                  b.categoryKey == selection.categoryKey)
              .map((b) => b.bankName)
              .toList();
          final count = banks.isEmpty
              ? 0
              : (await txn.rawQuery('''
        SELECT COUNT(DISTINCT q.id) AS n FROM questions q
        JOIN review_states rs ON rs.question_id = q.id
        WHERE q.bank_name IN (${List.filled(banks.length, '?').join(',')})
        AND rs.state > 0 AND rs.next_review_time <= ?
      ''', [...banks, capturedNow.millisecondsSinceEpoch ~/ 1000])).single['n']
                  as int;
          review = HomeTrainingSuccess(TrainingCount(count));
        }
        if (selection.state == TrainingCurrentContentState.usable) {
          final members = selection.currentContent!.content.members;
          final banks = members.map((m) => m.bankName).toList();
          final positive = members
              .where((m) => m.weightPercent > 0)
              .map((m) => m.bankName)
              .toList();
          final count = (await txn.rawQuery('''
        SELECT COUNT(DISTINCT q.id) AS n FROM questions q
        JOIN review_states rs ON rs.question_id = q.id
        WHERE q.bank_name IN (${List.filled(positive.length, '?').join(',')})
        AND rs.state = 0
      ''', positive)).single['n'] as int;
          newCount = HomeTrainingSuccess(TrainingCount(count));
          final row = (await txn.rawQuery('''
        SELECT COUNT(DISTINCT q.id) AS total,
          COUNT(DISTINCT CASE WHEN rs.state = 3 THEN q.id END) AS mastered,
          COUNT(DISTINCT CASE WHEN rl.review_time >= ? AND rl.review_time < ?
            THEN q.id END) AS practiced
        FROM questions q LEFT JOIN review_states rs ON rs.question_id = q.id
        LEFT JOIN review_logs rl ON rl.question_id = q.id
        WHERE q.bank_name IN (${List.filled(banks.length, '?').join(',')})
      ''', [
            dayStartUtc.millisecondsSinceEpoch ~/ 1000,
            dayEndUtc.millisecondsSinceEpoch ~/ 1000,
            ...banks
          ]))
              .single;
          summary = HomeTrainingSuccess(TrainingContentSummary(
              totalCount: row['total'] as int,
              masteredCount: row['mastered'] as int,
              todayPracticedCount: row['practiced'] as int));
        }
        return TodayTrainingSnapshot(
            selection: selection,
            categories: visible,
            newCount: newCount,
            categoryReviewCount: review,
            summary: summary);
      });

  void _admit(TrainingContent content, TrainingCatalogSnapshot catalog) {
    if (!projectTrainingContent(content, catalog).usable) {
      throw const _ConfigurationFailure(HomeTrainingFailure.invalidInput);
    }
  }

  TrainingContent _edited(
          String id, CategoryKey key, int revision, TrainingContentEdit edit) =>
      TrainingContent(
          contentId: id,
          categoryKey: key,
          name: edit.name,
          questionLimit: edit.questionLimit,
          sortOrder: edit.sortOrder,
          revision: revision,
          members: edit.members);

  Map<String, Object?> _parent(TrainingContent content) => {
        'content_id': content.contentId,
        'category_key': _codec.encodeString(content.categoryKey),
        'name': content.name,
        'question_limit': content.questionLimit,
        'sort_order': content.sortOrder,
        'revision': content.revision,
      };

  Future<void> _members(DatabaseExecutor db, TrainingContent content) async {
    for (final member in content.members) {
      await db.insert(trainingContentMembersTable, {
        'content_id': content.contentId,
        'bank_name': member.bankName,
        'weight_percent': member.weightPercent,
        'position': member.position,
        'binding_status': member.bindingStatus.name,
        'invalidation_reason': member.invalidationReason?.name,
      });
    }
  }

  @override
  Future<HomeTrainingResult<TrainingContent>> create(
          CreateTrainingContentRequest request) =>
      _transaction((txn) async {
        final content =
            _edited(const Uuid().v4(), request.categoryKey, 1, request.edit);
        _admit(content, await _catalog(txn));
        await txn.insert(trainingContentsTable, _parent(content));
        await _members(txn, content);
        return content;
      });

  Future<TrainingContent> _target(
      DatabaseExecutor db, TrainingContentTarget target) async {
    final content = await _content(db, target.contentId);
    if (content == null) {
      throw const _ConfigurationFailure(HomeTrainingFailure.notFound);
    }
    if (content.revision != target.expectedRevision) {
      throw const _ConfigurationFailure(HomeTrainingFailure.stale);
    }
    return content;
  }

  @override
  Future<HomeTrainingResult<TrainingContent>> update(
          UpdateTrainingContentRequest request) =>
      _transaction((txn) async {
        final old = await _target(txn, request.target);
        // Explicit recovery of an invalidated relation uses rebindMember only.
        if (old.members.any((member) =>
            member.bindingStatus == TrainingBindingStatus.invalidated &&
            request.edit.members.any((next) =>
                next.bankName == member.bankName &&
                next.bindingStatus == TrainingBindingStatus.valid))) {
          throw const _ConfigurationFailure(HomeTrainingFailure.conflict);
        }
        final content = _edited(
            old.contentId, old.categoryKey, old.revision + 1, request.edit);
        _admit(content, await _catalog(txn));
        final changed = await txn.update(
            trainingContentsTable, _parent(content),
            where: 'content_id = ? AND revision = ?',
            whereArgs: [old.contentId, request.target.expectedRevision]);
        if (changed != 1) {
          throw const _ConfigurationFailure(HomeTrainingFailure.stale);
        }
        await txn.delete(trainingContentMembersTable,
            where: 'content_id = ?', whereArgs: [old.contentId]);
        await _members(txn, content);
        return content;
      });

  @override
  Future<HomeTrainingResult<TrainingContent>> rebindMember(
          RebindTrainingContentMemberRequest request) =>
      _transaction((txn) async {
        final old = await _target(txn, request.target);
        final member = old.members
            .where((member) => member.bankName == request.bankName)
            .firstOrNull;
        if (member == null) {
          throw const _ConfigurationFailure(HomeTrainingFailure.notFound);
        }
        if (member.bindingStatus != TrainingBindingStatus.invalidated) {
          throw const _ConfigurationFailure(HomeTrainingFailure.conflict);
        }
        final catalog = await _catalog(txn);
        final bank = catalog.banks
            .where((bank) => bank.bankName == request.bankName)
            .firstOrNull;
        if (bank == null ||
            !bank.ordinaryTrainingEligible ||
            bank.categoryKey != old.categoryKey) {
          throw const _ConfigurationFailure(HomeTrainingFailure.invalidInput);
        }
        final content = TrainingContent(
          contentId: old.contentId,
          categoryKey: old.categoryKey,
          name: old.name,
          questionLimit: old.questionLimit,
          sortOrder: old.sortOrder,
          revision: old.revision + 1,
          members: [
            for (final binding in old.members)
              if (binding.bankName == request.bankName)
                TrainingContentMember(
                  bankName: binding.bankName,
                  weightPercent: binding.weightPercent,
                  position: binding.position,
                )
              else
                binding
          ],
        );
        final changed = await txn.update(
            trainingContentMembersTable,
            {
              'binding_status': 'valid',
              'invalidation_reason': null,
            },
            where:
                "content_id = ? AND bank_name = ? AND binding_status = 'invalidated'",
            whereArgs: [old.contentId, request.bankName]);
        if (changed != 1) {
          throw const _ConfigurationFailure(HomeTrainingFailure.conflict);
        }
        final revised = await txn.update(
            trainingContentsTable, {'revision': content.revision},
            where: 'content_id = ? AND revision = ?',
            whereArgs: [old.contentId, request.target.expectedRevision]);
        if (revised != 1) {
          throw const _ConfigurationFailure(HomeTrainingFailure.stale);
        }
        return content;
      });

  @override
  Future<HomeTrainingResult<HomeTrainingUnit>> delete(
          TrainingContentTarget target) =>
      _transaction((txn) async {
        final content = await _target(txn, target);
        final preference = await _preference(txn, content.categoryKey);
        final changed = await txn.delete(trainingContentsTable,
            where: 'content_id = ? AND revision = ?',
            whereArgs: [target.contentId, target.expectedRevision]);
        if (changed != 1) {
          throw const _ConfigurationFailure(HomeTrainingFailure.stale);
        }
        if (preference.currentContentId == content.contentId) {
          await _savePreference(txn, preference,
              currentContentId: null, visualKey: preference.visualKey);
        }
        return const HomeTrainingUnit();
      });

  Future<TrainingCategoryPreference> _preferenceTarget(
      DatabaseExecutor db, TrainingPreferenceTarget target) async {
    final preference = await _preference(db, target.categoryKey);
    if (preference.revision != target.expectedRevision) {
      throw const _ConfigurationFailure(HomeTrainingFailure.stale);
    }
    return preference;
  }

  Future<TrainingCategoryPreference> _savePreference(
      DatabaseExecutor db, TrainingCategoryPreference old,
      {required String? currentContentId,
      required CategoryVisualKey? visualKey}) async {
    final next = TrainingCategoryPreference(
        categoryKey: old.categoryKey,
        revision: (old.revision ?? 0) + 1,
        currentContentId: currentContentId,
        visualKey: visualKey);
    final values = <String, Object?>{
      'category_key': _codec.encodeString(next.categoryKey),
      'revision': next.revision,
      'current_content_id': next.currentContentId,
      'visual_key': next.visualKey?.name,
    };
    if (old.revision == null) {
      await db.insert(trainingCategoryPreferencesTable, values);
    } else {
      final changed = await db.update(trainingCategoryPreferencesTable, values,
          where: 'category_key = ? AND revision = ?',
          whereArgs: [values['category_key'], old.revision]);
      if (changed != 1) {
        throw const _ConfigurationFailure(HomeTrainingFailure.stale);
      }
    }
    return next;
  }

  @override
  Future<HomeTrainingResult<TrainingCurrentSelection>> selectCurrent(
          SelectTrainingContentRequest request) =>
      _transaction((txn) async {
        final preference = await _preferenceTarget(txn, request.target);
        if (request.contentId != null) {
          final content = await _content(txn, request.contentId!);
          if (content == null) {
            throw const _ConfigurationFailure(HomeTrainingFailure.notFound);
          }
          if (content.categoryKey != request.target.categoryKey) {
            throw const _ConfigurationFailure(HomeTrainingFailure.invalidInput);
          }
        }
        await _savePreference(txn, preference,
            currentContentId: request.contentId,
            visualKey: preference.visualKey);
        await txn.insert(
            'app_settings',
            {
              'key': currentTrainingCategorySetting,
              'value': _codec.encodeString(request.target.categoryKey),
            },
            conflictAlgorithm: ConflictAlgorithm.replace);
        // Build before commit, publish only after commit. Decode failures also
        // roll back both preference and global setting.
        return _current(txn);
      });

  @override
  Future<HomeTrainingResult<TrainingCategoryPreference>> updateCategoryVisual(
          UpdateCategoryVisualRequest request) =>
      _transaction((txn) async {
        final preference = await _preferenceTarget(txn, request.target);
        return _savePreference(txn, preference,
            currentContentId: preference.currentContentId,
            visualKey: request.visualKey);
      });
}

final class _ConfigurationFailure implements Exception {
  const _ConfigurationFailure(this.code);
  final HomeTrainingFailure code;
}
