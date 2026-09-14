import '../../application/ai_config/ai_config_ports.dart';
import '../../core/database/database_helper.dart';
import '../../core/database/sqflite_runtime.dart';
import '../../domain/ai_config/ai_config_contracts.dart';

/// SQLite implementation of the AI configuration persistence port.
final class SqliteAiConfigStore implements AiConfigStorePort {
  const SqliteAiConfigStore({required DatabaseHelper databaseHelper})
      : _databaseHelper = databaseHelper;

  final DatabaseHelper _databaseHelper;

  @override
  Future<List<AiProviderRecord>> listProviders() async {
    final db = await _databaseHelper.database;
    final rows =
        await db.query('ai_providers', orderBy: 'display_name, provider_id');
    return rows.map(_providerFromRow).toList(growable: false);
  }

  @override
  Future<AiProviderRecord?> readProvider(String providerId) async {
    final db = await _databaseHelper.database;
    final rows = await db.query(
      'ai_providers',
      where: 'provider_id = ?',
      whereArgs: <Object?>[providerId],
      limit: 1,
    );
    return rows.isEmpty ? null : _providerFromRow(rows.single);
  }

  @override
  Future<void> insertProvider(AiProviderRecord provider) async {
    if (provider.revision != 0) {
      throw const AiConfigException(AiConfigFailure.invalidInput);
    }
    final db = await _databaseHelper.database;
    try {
      await db.insert('ai_providers', _providerToRow(provider));
    } on DatabaseException catch (error) {
      throw AiConfigException(
        error.isUniqueConstraintError()
            ? AiConfigFailure.providerAlreadyExists
            : AiConfigFailure.temporarilyUnavailable,
      );
    }
  }

  @override
  Future<void> updateProvider(
    AiProviderRecord provider,
    int expectedRevision,
  ) async {
    if (provider.revision != expectedRevision + 1) {
      throw const AiConfigException(AiConfigFailure.invalidInput);
    }
    final db = await _databaseHelper.database;
    final changed = await db.update(
      'ai_providers',
      _providerToRow(provider)..remove('provider_id'),
      where: 'provider_id = ? AND revision = ?',
      whereArgs: <Object?>[provider.providerId, expectedRevision],
    );
    if (changed != 1) {
      throw const AiConfigException(AiConfigFailure.staleRevision);
    }
  }

  @override
  Future<void> deleteProvider(String providerId) async {
    final db = await _databaseHelper.database;
    final changed = await db.delete(
      'ai_providers',
      where: 'provider_id = ?',
      whereArgs: <Object?>[providerId],
    );
    if (changed != 1) {
      throw const AiConfigException(AiConfigFailure.providerNotFound);
    }
  }

  @override
  Future<List<AiModelRecord>> listModels({String? providerId}) async {
    final db = await _databaseHelper.database;
    final rows = await db.query(
      'ai_models',
      where: providerId == null ? null : 'provider_id = ?',
      whereArgs: providerId == null ? null : <Object?>[providerId],
      orderBy: 'display_name, model_ref',
    );
    return rows.map(_modelFromRow).toList(growable: false);
  }

  @override
  Future<AiModelRecord?> readModel(String modelRef) async {
    final db = await _databaseHelper.database;
    final rows = await db.query(
      'ai_models',
      where: 'model_ref = ?',
      whereArgs: <Object?>[modelRef],
      limit: 1,
    );
    return rows.isEmpty ? null : _modelFromRow(rows.single);
  }

  @override
  Future<void> saveModel(AiModelRecord model) async {
    final db = await _databaseHelper.database;
    await _upsertModel(db, model);
  }

  @override
  Future<void> deleteModel(String modelRef) async {
    final db = await _databaseHelper.database;
    final changed = await db.delete(
      'ai_models',
      where: 'model_ref = ?',
      whereArgs: <Object?>[modelRef],
    );
    if (changed != 1) {
      throw const AiConfigException(AiConfigFailure.modelNotFound);
    }
  }

  @override
  Future<List<AiCapabilityClaim>> listClaims(String modelRef) async {
    final db = await _databaseHelper.database;
    final rows = await db.query(
      'ai_model_capability_claims',
      where: 'model_ref = ?',
      whereArgs: <Object?>[modelRef],
    );
    return rows.map(_claimFromRow).toList(growable: false);
  }

  @override
  Future<void> replaceModelSnapshot({
    required String providerId,
    required int expectedProviderRevision,
    required List<AiModelRecord> models,
    required List<AiCapabilityClaim> officialClaims,
    required int syncedAt,
  }) async {
    final db = await _databaseHelper.database;
    await db.transaction((txn) async {
      final modelRefs = models.map((model) => model.modelRef).toSet();
      if (modelRefs.length != models.length) {
        throw const AiConfigException(AiConfigFailure.dataCorrupt);
      }
      final claimKeys = <(String, AiModelCapability)>{};
      for (final claim in officialClaims) {
        if (claim.source != AiCapabilityClaimSource.providerOfficial ||
            !modelRefs.contains(claim.modelRef) ||
            !claimKeys.add((claim.modelRef, claim.capability))) {
          throw const AiConfigException(AiConfigFailure.dataCorrupt);
        }
      }
      final changed = await txn.update(
        'ai_providers',
        <String, Object?>{
          'revision': expectedProviderRevision + 1,
          'updated_at': syncedAt,
          'last_sync_status': 'succeeded',
          'last_sync_at': syncedAt,
        },
        where: 'provider_id = ? AND revision = ?',
        whereArgs: <Object?>[providerId, expectedProviderRevision],
      );
      if (changed != 1) {
        throw const AiConfigException(AiConfigFailure.staleRevision);
      }
      await txn.update(
        'ai_models',
        <String, Object?>{'availability': 'unavailable'},
        where: 'provider_id = ?',
        whereArgs: <Object?>[providerId],
      );
      for (final model in models) {
        if (model.providerId != providerId) {
          throw const AiConfigException(AiConfigFailure.invalidInput);
        }
        final existing = await txn.query(
          'ai_models',
          columns: const <String>['first_seen_at'],
          where: 'provider_id = ? AND canonical_model_id = ?',
          whereArgs: <Object?>[providerId, model.canonicalModelId],
          limit: 1,
        );
        await _upsertModel(
          txn,
          AiModelRecord(
            modelRef: model.modelRef,
            providerId: model.providerId,
            canonicalModelId: model.canonicalModelId,
            displayName: model.displayName,
            availability: AiModelAvailability.available,
            firstSeenAt: existing.isEmpty
                ? model.firstSeenAt
                : existing.single['first_seen_at']! as int,
            lastSeenAt: syncedAt,
          ),
        );
        await txn.delete(
          'ai_model_capability_claims',
          where: 'model_ref = ? AND source = ?',
          whereArgs: <Object?>[
            model.modelRef,
            AiCapabilityClaimSource.providerOfficial.storageValue,
          ],
        );
      }
      for (final claim in officialClaims) {
        await txn.insert('ai_model_capability_claims', _claimToRow(claim));
      }
    });
  }

  @override
  Future<void> saveClaims(
    String modelRef,
    AiCapabilityClaimSource source,
    List<AiCapabilityClaim> claims,
  ) async {
    final db = await _databaseHelper.database;
    await db.transaction((txn) async {
      await txn.delete(
        'ai_model_capability_claims',
        where: 'model_ref = ? AND source = ?',
        whereArgs: <Object?>[modelRef, source.storageValue],
      );
      final seen = <AiModelCapability>{};
      for (final claim in claims) {
        if (claim.modelRef != modelRef ||
            claim.source != source ||
            claim.support == AiCapabilitySupport.unknown ||
            !seen.add(claim.capability)) {
          throw const AiConfigException(AiConfigFailure.dataCorrupt);
        }
        await txn.insert('ai_model_capability_claims', _claimToRow(claim));
      }
    });
  }

  @override
  Future<AiCapabilityBinding?> readBinding(AiCapabilitySlot slot) async {
    final db = await _databaseHelper.database;
    final rows = await db.query(
      'ai_capability_bindings',
      where: 'slot = ?',
      whereArgs: <Object?>[slot.storageValue],
      limit: 1,
    );
    return rows.isEmpty ? null : _bindingFromRow(rows.single);
  }

  @override
  Future<List<AiCapabilityBinding>> listBindings() async {
    final db = await _databaseHelper.database;
    final rows = await db.query('ai_capability_bindings', orderBy: 'slot');
    return rows.map(_bindingFromRow).toList(growable: false);
  }

  @override
  Future<void> saveBinding(
    AiCapabilityBinding binding, {
    required int? expectedRevision,
  }) async {
    final db = await _databaseHelper.database;
    if (binding.revision != (expectedRevision ?? -1) + 1) {
      throw const AiConfigException(AiConfigFailure.invalidInput);
    }
    if (expectedRevision == null) {
      try {
        await db.insert('ai_capability_bindings', _bindingToRow(binding));
      } catch (_) {
        throw const AiConfigException(AiConfigFailure.staleRevision);
      }
      return;
    }
    final changed = await db.update(
      'ai_capability_bindings',
      _bindingToRow(binding)..remove('slot'),
      where: 'slot = ? AND revision = ?',
      whereArgs: <Object?>[binding.slot.storageValue, expectedRevision],
    );
    if (changed != 1) {
      throw const AiConfigException(AiConfigFailure.staleRevision);
    }
  }

  @override
  Future<void> deleteBinding(
    AiCapabilitySlot slot, {
    required int expectedRevision,
  }) async {
    final db = await _databaseHelper.database;
    final changed = await db.delete(
      'ai_capability_bindings',
      where: 'slot = ? AND revision = ?',
      whereArgs: <Object?>[slot.storageValue, expectedRevision],
    );
    if (changed != 1) {
      throw const AiConfigException(AiConfigFailure.staleRevision);
    }
  }

  @override
  Future<void> saveLegacyProjection({
    required AiProviderRecord provider,
    required AiModelRecord model,
    required AiCapabilityBinding binding,
    required int? expectedProviderRevision,
    required int? expectedBindingRevision,
  }) async {
    final db = await _databaseHelper.database;
    await db.transaction((txn) async {
      if (expectedProviderRevision == null) {
        if (provider.revision != 0) {
          throw const AiConfigException(AiConfigFailure.invalidInput);
        }
        await txn.insert('ai_providers', _providerToRow(provider));
      } else {
        if (provider.revision != expectedProviderRevision + 1) {
          throw const AiConfigException(AiConfigFailure.invalidInput);
        }
        final changed = await txn.update(
          'ai_providers',
          _providerToRow(provider)..remove('provider_id'),
          where: 'provider_id = ? AND revision = ?',
          whereArgs: <Object?>[provider.providerId, expectedProviderRevision],
        );
        if (changed != 1) {
          throw const AiConfigException(AiConfigFailure.staleRevision);
        }
      }
      if (binding.revision != (expectedBindingRevision ?? -1) + 1) {
        throw const AiConfigException(AiConfigFailure.invalidInput);
      }
      await _upsertModel(txn, model);
      if (expectedBindingRevision == null) {
        try {
          await txn.insert('ai_capability_bindings', _bindingToRow(binding));
        } catch (_) {
          throw const AiConfigException(AiConfigFailure.staleRevision);
        }
      } else {
        final changed = await txn.update(
          'ai_capability_bindings',
          _bindingToRow(binding)..remove('slot'),
          where: 'slot = ? AND revision = ?',
          whereArgs: <Object?>[
            binding.slot.storageValue,
            expectedBindingRevision,
          ],
        );
        if (changed != 1) {
          throw const AiConfigException(AiConfigFailure.staleRevision);
        }
      }
    });
  }

  @override
  Future<void> deleteLegacyProjection(String providerId) async {
    final db = await _databaseHelper.database;
    await db.transaction((txn) async {
      final changed = await txn.delete(
        'ai_providers',
        where: 'provider_id = ?',
        whereArgs: <Object?>[providerId],
      );
      if (changed != 1) {
        throw const AiConfigException(AiConfigFailure.providerNotFound);
      }
    });
  }
}

Future<void> _upsertModel(
  DatabaseExecutor db,
  AiModelRecord model,
) async {
  try {
    final existing = await db.query(
      'ai_models',
      columns: const <String>['model_ref'],
      where: 'model_ref = ?',
      whereArgs: <Object?>[model.modelRef],
      limit: 1,
    );
    if (existing.isEmpty) {
      await db.insert('ai_models', _modelToRow(model));
      return;
    }
    await db.update(
      'ai_models',
      _modelToRow(model)..remove('model_ref'),
      where: 'model_ref = ?',
      whereArgs: <Object?>[model.modelRef],
    );
  } on AiConfigException {
    rethrow;
  } on DatabaseException {
    throw const AiConfigException(AiConfigFailure.dataCorrupt);
  }
}

AiProviderRecord _providerFromRow(Map<String, Object?> row) => AiProviderRecord(
      providerId: row['provider_id']! as String,
      kind: AiProviderKind.parse(row['provider_kind']),
      displayName: row['display_name']! as String,
      baseUrl: row['base_url']! as String,
      state: AiProviderState.parse(row['state']),
      revision: row['revision']! as int,
      createdAt: row['created_at']! as int,
      updatedAt: row['updated_at']! as int,
      lastConnectionStatus:
          AiOperationStatus.parse(row['last_connection_status']),
      lastConnectionAt: row['last_connection_at'] as int?,
      lastSyncStatus: AiOperationStatus.parse(row['last_sync_status']),
      lastSyncAt: row['last_sync_at'] as int?,
    );

Map<String, Object?> _providerToRow(AiProviderRecord value) =>
    <String, Object?>{
      'provider_id': value.providerId,
      'provider_kind': value.kind.storageValue,
      'display_name': value.displayName,
      'base_url': value.baseUrl,
      'state': value.state.storageValue,
      'revision': value.revision,
      'created_at': value.createdAt,
      'updated_at': value.updatedAt,
      'last_connection_status': value.lastConnectionStatus.storageValue,
      'last_connection_at': value.lastConnectionAt,
      'last_sync_status': value.lastSyncStatus.storageValue,
      'last_sync_at': value.lastSyncAt,
    };

AiModelRecord _modelFromRow(Map<String, Object?> row) => AiModelRecord(
      modelRef: row['model_ref']! as String,
      providerId: row['provider_id']! as String,
      canonicalModelId: row['canonical_model_id']! as String,
      displayName: row['display_name']! as String,
      availability: AiModelAvailability.parse(row['availability']),
      firstSeenAt: row['first_seen_at']! as int,
      lastSeenAt: row['last_seen_at']! as int,
    );

Map<String, Object?> _modelToRow(AiModelRecord value) => <String, Object?>{
      'model_ref': value.modelRef,
      'provider_id': value.providerId,
      'canonical_model_id': value.canonicalModelId,
      'display_name': value.displayName,
      'availability': value.availability.storageValue,
      'first_seen_at': value.firstSeenAt,
      'last_seen_at': value.lastSeenAt,
    };

AiCapabilityClaim _claimFromRow(Map<String, Object?> row) => AiCapabilityClaim(
      modelRef: row['model_ref']! as String,
      capability: AiModelCapability.parse(row['capability']),
      source: AiCapabilityClaimSource.parse(row['source']),
      support: switch (row['support']) {
        'supported' => AiCapabilitySupport.supported,
        'unsupported' => AiCapabilitySupport.unsupported,
        _ => throw const AiConfigException(AiConfigFailure.dataCorrupt),
      },
      assertedAt: row['asserted_at']! as int,
    );

Map<String, Object?> _claimToRow(AiCapabilityClaim value) => <String, Object?>{
      'model_ref': value.modelRef,
      'capability': value.capability.storageValue,
      'source': value.source.storageValue,
      'support': value.support.storageValue,
      'asserted_at': value.assertedAt,
    };

AiCapabilityBinding _bindingFromRow(Map<String, Object?> row) =>
    AiCapabilityBinding(
      slot: AiCapabilitySlot.parse(row['slot']),
      modelRef: row['model_ref']! as String,
      temperature: (row['temperature']! as num).toDouble(),
      reasoningEffort: row['reasoning_effort']! as String,
      validationMode: AiBindingValidationMode.parse(row['validation_mode']),
      revision: row['revision']! as int,
      updatedAt: row['updated_at']! as int,
    );

Map<String, Object?> _bindingToRow(AiCapabilityBinding value) =>
    <String, Object?>{
      'slot': value.slot.storageValue,
      'model_ref': value.modelRef,
      'temperature': value.temperature,
      'reasoning_effort': value.reasoningEffort,
      'validation_mode': value.validationMode.storageValue,
      'revision': value.revision,
      'updated_at': value.updatedAt,
    };
