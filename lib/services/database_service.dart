import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

class DatabaseService {
  DatabaseService._();

  static final DatabaseService instance = DatabaseService._();

  Database? _database;

  // 1回のタグ処理をSQLiteの1Transactionとしてまとめるための
  // ambient executor。runInTransaction()中は全DBメソッドが
  // 同じTransactionを使用する。
  DatabaseExecutor? _transactionExecutor;

  Future<DatabaseExecutor> get _executor async {
    return _transactionExecutor ?? await database;
  }

  Future<T> runInTransaction<T>(Future<T> Function() action) async {
    if (_transactionExecutor != null) {
      // すでにTransaction内なら、そのまま同じTransactionを使う。
      return action();
    }

    final db = await database;
    return db.transaction((txn) async {
      _transactionExecutor = txn;
      try {
        return await action();
      } finally {
        _transactionExecutor = null;
      }
    });
  }

  Future<T> _runNestedSafe<T>(
    Future<T> Function(DatabaseExecutor executor) action,
  ) async {
    final executor = await _executor;
    if (executor is Transaction) {
      return action(executor);
    }
    return (executor as Database).transaction(action);
  }

  // 新要件では旧DBを上書きせず、新しいDBへ保存する。
  static const String _databaseFileName = 'flower_signage_v2.db';
  static const int _databaseVersion = 1;

  static const List<String> supportedFlowerIds = <String>[
    'tulip',
    'sunflower',
    'rose',
    'kernation',
    'suzuran',
    'ajisai',
    'cosmos',
  ];

  Future<Database> get database async {
    if (_database != null) {
      return _database!;
    }
    _database = await _openDatabase();
    return _database!;
  }

  Future<Database> _openDatabase() async {
    sqfliteFfiInit();
    final factory = databaseFactoryFfi;
    final databaseFolder = await factory.getDatabasesPath();
    final databasePath = p.join(databaseFolder, _databaseFileName);

    debugPrint('DATABASE PATH: $databasePath');

    return factory.openDatabase(
      databasePath,
      options: OpenDatabaseOptions(
        version: _databaseVersion,
        onConfigure: (db) async {
          await db.execute('PRAGMA foreign_keys = ON');
        },
        onCreate: _onCreate,
      ),
    );
  }

  Future<String> getDatabasePath() async {
    sqfliteFfiInit();
    final factory = databaseFactoryFfi;
    final databaseFolder = await factory.getDatabasesPath();
    return p.join(databaseFolder, _databaseFileName);
  }

  Future<void> _onCreate(Database db, int version) async {
    await db.execute('''
      CREATE TABLE users (
        user_id TEXT PRIMARY KEY,
        tag_mac TEXT NOT NULL UNIQUE,
        created_at TEXT NOT NULL,
        updated_at TEXT NOT NULL
      )
      ''');

    await db.execute('''
      CREATE TABLE seed_inventory (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        user_id TEXT NOT NULL,
        flower_id TEXT NOT NULL,
        source_type TEXT NOT NULL,
        source_id TEXT NOT NULL,
        acquired_at TEXT NOT NULL,
        used INTEGER NOT NULL DEFAULT 0,
        used_at TEXT,
        UNIQUE(user_id, flower_id, source_type, source_id),
        FOREIGN KEY(user_id)
          REFERENCES users(user_id)
          ON DELETE CASCADE
      )
      ''');

    await db.execute('''
      CREATE TABLE user_flowers (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        user_id TEXT NOT NULL,
        seed_id INTEGER,
        flower_id TEXT NOT NULL,
        growth_value INTEGER NOT NULL DEFAULT 0,
        stage INTEGER NOT NULL DEFAULT 0,
        is_active INTEGER NOT NULL DEFAULT 0,
        is_bloomed INTEGER NOT NULL DEFAULT 0,
        acquired_at TEXT NOT NULL,
        bloomed_at TEXT,
        updated_at TEXT NOT NULL,
        UNIQUE(seed_id),
        FOREIGN KEY(user_id)
          REFERENCES users(user_id)
          ON DELETE CASCADE,
        FOREIGN KEY(seed_id)
          REFERENCES seed_inventory(id)
          ON DELETE SET NULL
      )
      ''');

    await db.execute('''
      CREATE TABLE import_history (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        user_id TEXT NOT NULL,
        import_hash TEXT NOT NULL UNIQUE,
        imported_at TEXT NOT NULL,
        growth_metric TEXT NOT NULL,
        growth_value INTEGER NOT NULL,
        record_count INTEGER NOT NULL,
        unique_address_count INTEGER NOT NULL,
        status TEXT NOT NULL,
        FOREIGN KEY(user_id)
          REFERENCES users(user_id)
          ON DELETE CASCADE
      )
      ''');

    await db.execute('''
      CREATE TABLE import_batches (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        user_id TEXT NOT NULL,
        batch_hash TEXT NOT NULL UNIQUE,
        growth_metric TEXT NOT NULL,
        growth_value INTEGER NOT NULL DEFAULT 0,
        record_count INTEGER NOT NULL DEFAULT 0,
        unique_address_count INTEGER NOT NULL DEFAULT 0,
        checkpoint_count INTEGER NOT NULL DEFAULT 0,
        interaction_count INTEGER NOT NULL DEFAULT 0,
        status TEXT NOT NULL DEFAULT 'processing',
        created_at TEXT NOT NULL,
        completed_at TEXT,
        FOREIGN KEY(user_id)
          REFERENCES users(user_id)
          ON DELETE CASCADE
      )
      ''');

    await db.execute('''
      CREATE TABLE log_archive (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        user_id TEXT NOT NULL,
        batch_id INTEGER,
        file_name TEXT NOT NULL,
        file_hash TEXT NOT NULL,
        raw_content TEXT,
        record_count INTEGER NOT NULL DEFAULT 0,
        processed INTEGER NOT NULL DEFAULT 0,
        processed_at TEXT,
        deleted_from_tag INTEGER NOT NULL DEFAULT 0,
        deleted_at TEXT,
        created_at TEXT NOT NULL,
        FOREIGN KEY(user_id)
          REFERENCES users(user_id)
          ON DELETE CASCADE,
        FOREIGN KEY(batch_id)
          REFERENCES import_batches(id)
          ON DELETE SET NULL,
        UNIQUE(user_id, file_hash)
      )
      ''');

    await db.execute('''
      CREATE TABLE result_events (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        user_id TEXT NOT NULL,
        batch_id INTEGER,
        event_type TEXT NOT NULL,
        flower_id TEXT,
        growth_value INTEGER,
        stage_before INTEGER,
        stage_after INTEGER,
        message TEXT NOT NULL,
        displayed INTEGER NOT NULL DEFAULT 0,
        created_at TEXT NOT NULL,
        displayed_at TEXT,
        FOREIGN KEY(user_id)
          REFERENCES users(user_id)
          ON DELETE CASCADE,
        FOREIGN KEY(batch_id)
          REFERENCES import_batches(id)
          ON DELETE SET NULL
      )
      ''');

    await _createIndexes(db);
  }

  Future<void> _createIndexes(Database db) async {
    await db.execute(
      'CREATE INDEX IF NOT EXISTS idx_seed_user ON seed_inventory(user_id)',
    );
    await db.execute(
      'CREATE INDEX IF NOT EXISTS idx_seed_user_flower_used '
      'ON seed_inventory(user_id, flower_id, used)',
    );
    await db.execute(
      'CREATE INDEX IF NOT EXISTS idx_import_user ON import_history(user_id)',
    );
    await db.execute(
      'CREATE INDEX IF NOT EXISTS idx_flower_user ON user_flowers(user_id)',
    );
    await db.execute(
      'CREATE INDEX IF NOT EXISTS idx_flower_user_type_active '
      'ON user_flowers(user_id, flower_id, is_active, is_bloomed)',
    );
    await db.execute(
      'CREATE INDEX IF NOT EXISTS idx_batch_user ON import_batches(user_id)',
    );
    await db.execute(
      'CREATE INDEX IF NOT EXISTS idx_batch_status ON import_batches(status)',
    );
    await db.execute(
      'CREATE INDEX IF NOT EXISTS idx_log_user ON log_archive(user_id)',
    );
    await db.execute(
      'CREATE INDEX IF NOT EXISTS idx_log_batch ON log_archive(batch_id)',
    );
    await db.execute(
      'CREATE INDEX IF NOT EXISTS idx_log_processed ON log_archive(processed)',
    );
    await db.execute(
      'CREATE INDEX IF NOT EXISTS idx_result_user ON result_events(user_id)',
    );
    await db.execute(
      'CREATE INDEX IF NOT EXISTS idx_result_displayed '
      'ON result_events(user_id, displayed)',
    );
  }

  void _validateFlowerId(String flowerId) {
    if (!supportedFlowerIds.contains(flowerId)) {
      throw ArgumentError(
        '未対応のflower_idです: $flowerId\n'
        '使用可能: ${supportedFlowerIds.join(', ')}',
      );
    }
  }

  void _validateStage(int stage) {
    if (stage < 0 || stage > 6) {
      throw ArgumentError('stageは0〜6である必要があります。現在値: $stage');
    }
  }

  void _validateGrowthValue(int growthValue) {
    if (growthValue < 0) {
      throw ArgumentError('growthValueは0以上である必要があります。現在値: $growthValue');
    }
  }

  Future<bool> testConnection() async {
    try {
      final db = await _executor;
      await db.rawQuery('SELECT 1');
      return true;
    } catch (_) {
      return false;
    }
  }

  Future<void> upsertUser({
    required String userId,
    required String tagMac,
  }) async {
    final db = await _executor;
    final now = DateTime.now().toIso8601String();
    final normalizedMac = tagMac.trim().toUpperCase();

    final existing = await db.query(
      'users',
      where: 'user_id = ?',
      whereArgs: [userId],
      limit: 1,
    );

    if (existing.isEmpty) {
      await db.insert('users', {
        'user_id': userId,
        'tag_mac': normalizedMac,
        'created_at': now,
        'updated_at': now,
      });
      return;
    }

    await db.update(
      'users',
      {'tag_mac': normalizedMac, 'updated_at': now},
      where: 'user_id = ?',
      whereArgs: [userId],
    );
  }

  Future<List<Map<String, Object?>>> getUsers() async {
    final db = await _executor;
    return db.query('users', orderBy: 'user_id ASC');
  }

  Future<Map<String, Object?>?> getUser(String userId) async {
    final db = await _executor;
    final result = await db.query(
      'users',
      where: 'user_id = ?',
      whereArgs: [userId],
      limit: 1,
    );
    if (result.isEmpty) return null;
    return result.first;
  }

  Future<void> ensureInitialSeeds({
    required String userId,
    required List<String> initialSeeds,
  }) async {
    final db = await _executor;

    await _runNestedSafe((txn) async {
      final users = await txn.query(
        'users',
        columns: ['created_at'],
        where: 'user_id = ?',
        whereArgs: [userId],
        limit: 1,
      );

      if (users.isEmpty) {
        throw Exception('初期種追加時にユーザーが見つかりません。\nuser_id: $userId');
      }

      final acquiredAt = users.first['created_at']?.toString();
      if (acquiredAt == null || acquiredAt.isEmpty) {
        throw Exception('ユーザー作成日時を取得できませんでした。\nuser_id: $userId');
      }

      for (var i = 0; i < initialSeeds.length; i++) {
        final flowerId = initialSeeds[i].trim();
        if (flowerId.isEmpty) continue;

        _validateFlowerId(flowerId);

        // 同じ種類の初期種を複数持てるようindexを含める。
        final sourceId = 'initial:$flowerId:$i';

        final existing = await txn.query(
          'seed_inventory',
          columns: ['id'],
          where: '''
            user_id = ?
            AND flower_id = ?
            AND source_type = ?
            AND source_id = ?
          ''',
          whereArgs: [userId, flowerId, 'initial', sourceId],
          limit: 1,
        );

        if (existing.isNotEmpty) continue;

        await txn.insert('seed_inventory', {
          'user_id': userId,
          'flower_id': flowerId,
          'source_type': 'initial',
          'source_id': sourceId,
          'acquired_at': acquiredAt,
          'used': 0,
          'used_at': null,
        });
      }
    });
  }

  Future<bool> addSeed({
    required String userId,
    required String flowerId,
    required String sourceType,
    required String sourceId,
  }) async {
    _validateFlowerId(flowerId);

    final db = await _executor;
    final now = DateTime.now().toIso8601String();

    final id = await db.insert('seed_inventory', {
      'user_id': userId,
      'flower_id': flowerId,
      'source_type': sourceType,
      'source_id': sourceId,
      'acquired_at': now,
      'used': 0,
      'used_at': null,
    }, conflictAlgorithm: ConflictAlgorithm.ignore);

    return id != 0;
  }

  Future<List<Map<String, Object?>>> getSeeds(String userId) async {
    final db = await _executor;
    return db.query(
      'seed_inventory',
      where: 'user_id = ?',
      whereArgs: [userId],
      orderBy: 'acquired_at ASC, id ASC',
    );
  }

  Future<Map<String, Object?>?> getNextUnusedSeed(String userId) async {
    final db = await _executor;
    final result = await db.query(
      'seed_inventory',
      where: 'user_id = ? AND used = 0',
      whereArgs: [userId],
      orderBy: 'acquired_at ASC, id ASC',
      limit: 1,
    );
    if (result.isEmpty) return null;
    return result.first;
  }

  Future<Map<String, Object?>?> getNextUnusedSeedForFlower({
    required String userId,
    required String flowerId,
  }) async {
    _validateFlowerId(flowerId);

    final db = await _executor;
    final result = await db.query(
      'seed_inventory',
      where: 'user_id = ? AND flower_id = ? AND used = 0',
      whereArgs: [userId, flowerId],
      orderBy: 'acquired_at ASC, id ASC',
      limit: 1,
    );
    if (result.isEmpty) return null;
    return result.first;
  }

  Future<void> markSeedUsed(int seedId) async {
    final db = await _executor;
    final now = DateTime.now().toIso8601String();

    final count = await db.update(
      'seed_inventory',
      {'used': 1, 'used_at': now},
      where: 'id = ? AND used = 0',
      whereArgs: [seedId],
    );

    if (count != 1) {
      throw Exception('種の使用済み更新に失敗しました。\nseed_id: $seedId');
    }
  }

  Future<bool> hasSeed({
    required String userId,
    required String flowerId,
    required String sourceType,
    required String sourceId,
  }) async {
    _validateFlowerId(flowerId);

    final db = await _executor;
    final result = await db.query(
      'seed_inventory',
      columns: ['id'],
      where: '''
        user_id = ?
        AND flower_id = ?
        AND source_type = ?
        AND source_id = ?
      ''',
      whereArgs: [userId, flowerId, sourceType, sourceId],
      limit: 1,
    );
    return result.isNotEmpty;
  }

  Future<Map<String, int>> getUnusedSeedCounts(String userId) async {
    final db = await _executor;
    final rows = await db.rawQuery(
      '''
      SELECT flower_id, COUNT(*) AS count
      FROM seed_inventory
      WHERE user_id = ? AND used = 0
      GROUP BY flower_id
      ''',
      [userId],
    );

    final result = <String, int>{
      for (final flowerId in supportedFlowerIds) flowerId: 0,
    };

    for (final row in rows) {
      final flowerId = row['flower_id']?.toString();
      if (flowerId == null) continue;
      result[flowerId] = (row['count'] as num?)?.toInt() ?? 0;
    }

    return result;
  }

  Future<bool> isImportProcessed(String importHash) async {
    final db = await _executor;
    final result = await db.query(
      'import_history',
      columns: ['id', 'status'],
      where: 'import_hash = ?',
      whereArgs: [importHash],
      limit: 1,
    );
    if (result.isEmpty) return false;
    return result.first['status']?.toString() == 'completed';
  }

  Future<void> addImportHistory({
    required String userId,
    required String importHash,
    required String growthMetric,
    required int growthValue,
    required int recordCount,
    required int uniqueAddressCount,
    required String status,
  }) async {
    final db = await _executor;
    final now = DateTime.now().toIso8601String();

    await db.insert('import_history', {
      'user_id': userId,
      'import_hash': importHash,
      'imported_at': now,
      'growth_metric': growthMetric,
      'growth_value': growthValue,
      'record_count': recordCount,
      'unique_address_count': uniqueAddressCount,
      'status': status,
    }, conflictAlgorithm: ConflictAlgorithm.ignore);
  }

  Future<List<Map<String, Object?>>> getImportHistory(String userId) async {
    final db = await _executor;
    return db.query(
      'import_history',
      where: 'user_id = ?',
      whereArgs: [userId],
      orderBy: 'imported_at DESC',
    );
  }

  Future<int> getImportCount(String userId) async {
    final db = await _executor;
    final result = await db.rawQuery(
      '''
      SELECT COUNT(*) AS count
      FROM import_history
      WHERE user_id = ?
      AND status = 'completed'
      ''',
      [userId],
    );
    return (result.first['count'] as num?)?.toInt() ?? 0;
  }

  Future<void> createFlowerIfNeeded({
    required String userId,
    required String flowerId,
    bool active = false,
  }) async {
    _validateFlowerId(flowerId);

    final db = await _executor;
    final existing = await db.query(
      'user_flowers',
      columns: ['id'],
      where: 'user_id = ? AND flower_id = ? AND is_bloomed = 0',
      whereArgs: [userId, flowerId],
      orderBy: 'id ASC',
      limit: 1,
    );

    if (existing.isNotEmpty) {
      if (active) {
        await setActiveFlower(userId: userId, flowerId: flowerId);
      }
      return;
    }

    final now = DateTime.now().toIso8601String();

    await db.insert('user_flowers', {
      'user_id': userId,
      'seed_id': null,
      'flower_id': flowerId,
      'growth_value': 0,
      'stage': 0,
      'is_active': active ? 1 : 0,
      'is_bloomed': 0,
      'acquired_at': now,
      'bloomed_at': null,
      'updated_at': now,
    });
  }

  Future<Map<String, Object?>?> getFlower({
    required String userId,
    required String flowerId,
  }) async {
    _validateFlowerId(flowerId);

    final db = await _executor;
    final result = await db.query(
      'user_flowers',
      where: 'user_id = ? AND flower_id = ?',
      whereArgs: [userId, flowerId],
      orderBy: 'id DESC',
      limit: 1,
    );
    if (result.isEmpty) return null;
    return result.first;
  }

  Future<Map<String, Object?>?> getFlowerById(int userFlowerId) async {
    final db = await _executor;
    final result = await db.query(
      'user_flowers',
      where: 'id = ?',
      whereArgs: [userFlowerId],
      limit: 1,
    );
    if (result.isEmpty) return null;
    return result.first;
  }

  Future<List<Map<String, Object?>>> getFlowers(String userId) async {
    final db = await _executor;
    return db.query(
      'user_flowers',
      where: 'user_id = ?',
      whereArgs: [userId],
      orderBy: 'acquired_at ASC, id ASC',
    );
  }

  Future<Map<String, Object?>?> getActiveFlower(String userId) async {
    final db = await _executor;
    final result = await db.query(
      'user_flowers',
      where: 'user_id = ? AND is_active = 1 AND is_bloomed = 0',
      whereArgs: [userId],
      orderBy: 'id ASC',
      limit: 1,
    );
    if (result.isEmpty) return null;
    return result.first;
  }

  Future<Map<String, Object?>?> getActiveFlowerByType({
    required String userId,
    required String flowerId,
  }) async {
    _validateFlowerId(flowerId);

    final db = await _executor;
    final rows = await db.query(
      'user_flowers',
      where: '''
        user_id = ?
        AND flower_id = ?
        AND is_active = 1
        AND is_bloomed = 0
      ''',
      whereArgs: [userId, flowerId],
      orderBy: 'id ASC',
      limit: 1,
    );
    if (rows.isEmpty) return null;
    return rows.first;
  }

  Future<Map<String, Map<String, Object?>>> getActiveFlowersByType(
    String userId,
  ) async {
    final db = await _executor;
    final rows = await db.query(
      'user_flowers',
      where: 'user_id = ? AND is_active = 1 AND is_bloomed = 0',
      whereArgs: [userId],
      orderBy: 'id ASC',
    );

    final result = <String, Map<String, Object?>>{};
    for (final row in rows) {
      final flowerId = row['flower_id'].toString();
      result.putIfAbsent(flowerId, () => row);
    }
    return result;
  }

  Future<void> updateFlowerGrowth({
    required int userFlowerId,
    required int growthValue,
    required int stage,
  }) async {
    _validateGrowthValue(growthValue);
    _validateStage(stage);

    final db = await _executor;
    final now = DateTime.now().toIso8601String();

    final count = await db.update(
      'user_flowers',
      {'growth_value': growthValue, 'stage': stage, 'updated_at': now},
      where: 'id = ? AND is_bloomed = 0',
      whereArgs: [userFlowerId],
    );

    if (count != 1) {
      throw Exception('花の成長状態更新に失敗しました。\nuser_flower_id: $userFlowerId');
    }
  }

  Future<Map<String, Object?>> addFlowerGrowth({
    required int userFlowerId,
    required int growthValueDelta,
    required int stageAfter,
  }) async {
    _validateGrowthValue(growthValueDelta);
    _validateStage(stageAfter);

    final db = await _executor;

    return _runNestedSafe((txn) async {
      final rows = await txn.query(
        'user_flowers',
        where: 'id = ?',
        whereArgs: [userFlowerId],
        limit: 1,
      );

      if (rows.isEmpty) {
        throw Exception('成長対象の花が見つかりません。\nuser_flower_id: $userFlowerId');
      }

      final row = rows.first;
      if ((row['is_bloomed'] as num?)?.toInt() == 1) {
        throw Exception(
          '開花済みの花へ成長量を追加できません。\n'
          'user_flower_id: $userFlowerId',
        );
      }

      final currentGrowth = (row['growth_value'] as num?)?.toInt() ?? 0;
      final newGrowth = currentGrowth + growthValueDelta;
      final now = DateTime.now().toIso8601String();

      final count = await txn.update(
        'user_flowers',
        {'growth_value': newGrowth, 'stage': stageAfter, 'updated_at': now},
        where: 'id = ?',
        whereArgs: [userFlowerId],
      );

      if (count != 1) {
        throw Exception('花の成長量加算に失敗しました。\nuser_flower_id: $userFlowerId');
      }

      final updated = await txn.query(
        'user_flowers',
        where: 'id = ?',
        whereArgs: [userFlowerId],
        limit: 1,
      );
      return updated.first;
    });
  }

  // 他種類のactive状態を壊さず、同じflower_id内だけ切り替える。
  Future<void> setActiveFlower({
    required String userId,
    required String flowerId,
  }) async {
    _validateFlowerId(flowerId);

    final db = await _executor;

    await _runNestedSafe((txn) async {
      final candidates = await txn.query(
        'user_flowers',
        columns: ['id'],
        where: 'user_id = ? AND flower_id = ? AND is_bloomed = 0',
        whereArgs: [userId, flowerId],
        orderBy: 'id ASC',
        limit: 1,
      );

      if (candidates.isEmpty) {
        throw Exception('育成する花が見つかりません。\nflower: $flowerId');
      }

      final targetId = (candidates.first['id'] as num).toInt();

      await txn.update(
        'user_flowers',
        {'is_active': 0, 'updated_at': DateTime.now().toIso8601String()},
        where: 'user_id = ? AND flower_id = ? AND is_bloomed = 0',
        whereArgs: [userId, flowerId],
      );

      final count = await txn.update(
        'user_flowers',
        {'is_active': 1, 'updated_at': DateTime.now().toIso8601String()},
        where: 'id = ? AND is_bloomed = 0',
        whereArgs: [targetId],
      );

      if (count != 1) {
        throw Exception('育成する花の変更に失敗しました。\nuser_flower_id: $targetId');
      }
    });
  }

  Future<void> markFlowerBloomed({
    required int userFlowerId,
    required int growthValue,
    required int maxStage,
  }) async {
    _validateGrowthValue(growthValue);
    _validateStage(maxStage);

    final db = await _executor;
    final now = DateTime.now().toIso8601String();

    final count = await db.update(
      'user_flowers',
      {
        'growth_value': growthValue,
        'stage': maxStage,
        'is_bloomed': 1,
        'is_active': 0,
        'bloomed_at': now,
        'updated_at': now,
      },
      where: 'id = ? AND is_bloomed = 0',
      whereArgs: [userFlowerId],
    );

    if (count != 1) {
      throw Exception('開花状態の保存に失敗しました。\nuser_flower_id: $userFlowerId');
    }
  }

  Future<Map<String, Object?>> addGrowthAndBloomFlower({
    required int userFlowerId,
    required int growthValueDelta,
    required int maxStage,
  }) async {
    _validateGrowthValue(growthValueDelta);
    _validateStage(maxStage);

    final db = await _executor;

    return _runNestedSafe((txn) async {
      final rows = await txn.query(
        'user_flowers',
        where: 'id = ?',
        whereArgs: [userFlowerId],
        limit: 1,
      );

      if (rows.isEmpty) {
        throw Exception('開花対象の花が見つかりません。\nuser_flower_id: $userFlowerId');
      }

      final row = rows.first;
      if ((row['is_bloomed'] as num?)?.toInt() == 1) {
        throw Exception('すでに開花済みです。\nuser_flower_id: $userFlowerId');
      }

      final currentGrowth = (row['growth_value'] as num?)?.toInt() ?? 0;
      final newGrowth = currentGrowth + growthValueDelta;
      final now = DateTime.now().toIso8601String();

      final count = await txn.update(
        'user_flowers',
        {
          'growth_value': newGrowth,
          'stage': maxStage,
          'is_bloomed': 1,
          'is_active': 0,
          'bloomed_at': now,
          'updated_at': now,
        },
        where: 'id = ?',
        whereArgs: [userFlowerId],
      );

      if (count != 1) {
        throw Exception('開花状態の保存に失敗しました。\nuser_flower_id: $userFlowerId');
      }

      final updated = await txn.query(
        'user_flowers',
        where: 'id = ?',
        whereArgs: [userFlowerId],
        limit: 1,
      );
      return updated.first;
    });
  }

  Future<Map<String, Object?>?> activateNextSeed(String userId) async {
    final db = await _executor;

    return _runNestedSafe((txn) async {
      final seeds = await txn.query(
        'seed_inventory',
        where: 'user_id = ? AND used = 0',
        whereArgs: [userId],
        orderBy: 'acquired_at ASC, id ASC',
        limit: 1,
      );

      if (seeds.isEmpty) return null;

      final flowerId = seeds.first['flower_id'].toString();

      final existingActive = await txn.query(
        'user_flowers',
        where: '''
          user_id = ?
          AND flower_id = ?
          AND is_active = 1
          AND is_bloomed = 0
        ''',
        whereArgs: [userId, flowerId],
        orderBy: 'id ASC',
        limit: 1,
      );

      if (existingActive.isNotEmpty) {
        return existingActive.first;
      }

      return _activateSeedForFlowerInTransaction(
        txn: txn,
        userId: userId,
        flowerId: flowerId,
        initialStage: 0,
        initialGrowthValue: 0,
      );
    });
  }

  Future<Map<String, Object?>?> activateNextSeedForFlower({
    required String userId,
    required String flowerId,
    int initialStage = 0,
    int initialGrowthValue = 0,
  }) async {
    _validateFlowerId(flowerId);
    _validateStage(initialStage);
    _validateGrowthValue(initialGrowthValue);

    final db = await _executor;

    return _runNestedSafe((txn) async {
      final active = await txn.query(
        'user_flowers',
        where: '''
          user_id = ?
          AND flower_id = ?
          AND is_active = 1
          AND is_bloomed = 0
        ''',
        whereArgs: [userId, flowerId],
        orderBy: 'id ASC',
        limit: 1,
      );

      if (active.isNotEmpty) {
        return active.first;
      }

      return _activateSeedForFlowerInTransaction(
        txn: txn,
        userId: userId,
        flowerId: flowerId,
        initialStage: initialStage,
        initialGrowthValue: initialGrowthValue,
      );
    });
  }

  Future<Map<String, Object?>?> _activateSeedForFlowerInTransaction({
    required DatabaseExecutor txn,
    required String userId,
    required String flowerId,
    required int initialStage,
    required int initialGrowthValue,
  }) async {
    final seeds = await txn.query(
      'seed_inventory',
      where: 'user_id = ? AND flower_id = ? AND used = 0',
      whereArgs: [userId, flowerId],
      orderBy: 'acquired_at ASC, id ASC',
      limit: 1,
    );

    if (seeds.isEmpty) return null;

    final seedId = (seeds.first['id'] as num).toInt();
    final now = DateTime.now().toIso8601String();

    final flowerRowId = await txn.insert('user_flowers', {
      'user_id': userId,
      'seed_id': seedId,
      'flower_id': flowerId,
      'growth_value': initialGrowthValue,
      'stage': initialStage,
      'is_active': 1,
      'is_bloomed': 0,
      'acquired_at': now,
      'bloomed_at': null,
      'updated_at': now,
    });

    final usedCount = await txn.update(
      'seed_inventory',
      {'used': 1, 'used_at': now},
      where: 'id = ? AND used = 0',
      whereArgs: [seedId],
    );

    if (usedCount != 1) {
      throw Exception('種の使用状態更新に失敗しました。\nseed_id: $seedId');
    }

    final result = await txn.query(
      'user_flowers',
      where: 'id = ?',
      whereArgs: [flowerRowId],
      limit: 1,
    );

    if (result.isEmpty) {
      throw Exception('次の花の作成に失敗しました。\nseed_id: $seedId');
    }

    return result.first;
  }

  Future<Map<String, int>> getBloomCounts(String userId) async {
    final db = await _executor;
    final rows = await db.rawQuery(
      '''
      SELECT flower_id, COUNT(*) AS count
      FROM user_flowers
      WHERE user_id = ? AND is_bloomed = 1
      GROUP BY flower_id
      ''',
      [userId],
    );

    final result = <String, int>{
      for (final flowerId in supportedFlowerIds) flowerId: 0,
    };

    for (final row in rows) {
      final flowerId = row['flower_id']?.toString();
      if (flowerId == null) continue;
      result[flowerId] = (row['count'] as num?)?.toInt() ?? 0;
    }

    return result;
  }

  Future<int> createImportBatch({
    required String userId,
    required String batchHash,
    required String growthMetric,
  }) async {
    final db = await _executor;
    final now = DateTime.now().toIso8601String();

    return db.insert('import_batches', {
      'user_id': userId,
      'batch_hash': batchHash,
      'growth_metric': growthMetric,
      'growth_value': 0,
      'record_count': 0,
      'unique_address_count': 0,
      'checkpoint_count': 0,
      'interaction_count': 0,
      'status': 'processing',
      'created_at': now,
      'completed_at': null,
    }, conflictAlgorithm: ConflictAlgorithm.abort);
  }

  Future<Map<String, Object?>?> getImportBatchByHash(String batchHash) async {
    final db = await _executor;
    final rows = await db.query(
      'import_batches',
      where: 'batch_hash = ?',
      whereArgs: [batchHash],
      limit: 1,
    );
    if (rows.isEmpty) return null;
    return rows.first;
  }

  Future<Map<String, Object?>?> getImportBatchById(int batchId) async {
    final db = await _executor;
    final rows = await db.query(
      'import_batches',
      where: 'id = ?',
      whereArgs: [batchId],
      limit: 1,
    );
    if (rows.isEmpty) return null;
    return rows.first;
  }

  Future<void> completeImportBatch({
    required int batchId,
    required int growthValue,
    required int recordCount,
    required int uniqueAddressCount,
    required int checkpointCount,
    required int interactionCount,
  }) async {
    final db = await _executor;
    final now = DateTime.now().toIso8601String();

    final count = await db.update(
      'import_batches',
      {
        'growth_value': growthValue,
        'record_count': recordCount,
        'unique_address_count': uniqueAddressCount,
        'checkpoint_count': checkpointCount,
        'interaction_count': interactionCount,
        'status': 'completed',
        'completed_at': now,
      },
      where: 'id = ?',
      whereArgs: [batchId],
    );

    if (count != 1) {
      throw Exception('Import Batchの完了更新に失敗しました。\nbatch_id: $batchId');
    }
  }

  Future<void> failImportBatch({required int batchId}) async {
    final db = await _executor;
    final count = await db.update(
      'import_batches',
      {'status': 'failed', 'completed_at': DateTime.now().toIso8601String()},
      where: 'id = ?',
      whereArgs: [batchId],
    );

    if (count != 1) {
      throw Exception('Import Batchの失敗更新に失敗しました。\nbatch_id: $batchId');
    }
  }

  Future<List<Map<String, Object?>>> getImportBatches(String userId) async {
    final db = await _executor;
    return db.query(
      'import_batches',
      where: 'user_id = ?',
      whereArgs: [userId],
      orderBy: 'created_at DESC, id DESC',
    );
  }

  Future<bool> hasLogHash({
    required String userId,
    required String fileHash,
  }) async {
    final db = await _executor;
    final rows = await db.query(
      'log_archive',
      columns: ['id'],
      where: 'user_id = ? AND file_hash = ?',
      whereArgs: [userId, fileHash],
      limit: 1,
    );
    return rows.isNotEmpty;
  }

  Future<int> archiveLog({
    required String userId,
    required int? batchId,
    required String fileName,
    required String fileHash,
    required String? rawContent,
    required int recordCount,
  }) async {
    final db = await _executor;
    final now = DateTime.now().toIso8601String();

    final existing = await db.query(
      'log_archive',
      columns: ['id'],
      where: 'user_id = ? AND file_hash = ?',
      whereArgs: [userId, fileHash],
      limit: 1,
    );

    if (existing.isNotEmpty) {
      return (existing.first['id'] as num).toInt();
    }

    return db.insert('log_archive', {
      'user_id': userId,
      'batch_id': batchId,
      'file_name': fileName,
      'file_hash': fileHash,
      'raw_content': rawContent,
      'record_count': recordCount,
      'processed': 0,
      'processed_at': null,
      'deleted_from_tag': 0,
      'deleted_at': null,
      'created_at': now,
    }, conflictAlgorithm: ConflictAlgorithm.abort);
  }

  Future<void> markLogProcessed({required int logArchiveId}) async {
    final db = await _executor;
    final now = DateTime.now().toIso8601String();

    final count = await db.update(
      'log_archive',
      {'processed': 1, 'processed_at': now},
      where: 'id = ?',
      whereArgs: [logArchiveId],
    );

    if (count != 1) {
      throw Exception(
        'LOGのprocessed更新に失敗しました。\n'
        'log_archive_id: $logArchiveId',
      );
    }
  }

  Future<void> markBatchLogsProcessed(int batchId) async {
    final db = await _executor;
    final now = DateTime.now().toIso8601String();

    await db.update(
      'log_archive',
      {'processed': 1, 'processed_at': now},
      where: 'batch_id = ? AND processed = 0',
      whereArgs: [batchId],
    );
  }

  Future<void> markLogDeletedFromTag({required int logArchiveId}) async {
    final db = await _executor;
    final now = DateTime.now().toIso8601String();

    final count = await db.update(
      'log_archive',
      {'deleted_from_tag': 1, 'deleted_at': now},
      where: 'id = ?',
      whereArgs: [logArchiveId],
    );

    if (count != 1) {
      throw Exception(
        'LOGの削除状態更新に失敗しました。\n'
        'log_archive_id: $logArchiveId',
      );
    }
  }

  Future<void> markLogDeletedByHash({
    required String userId,
    required String fileHash,
  }) async {
    final db = await _executor;
    final now = DateTime.now().toIso8601String();

    await db.update(
      'log_archive',
      {'deleted_from_tag': 1, 'deleted_at': now},
      where: 'user_id = ? AND file_hash = ?',
      whereArgs: [userId, fileHash],
    );
  }

  Future<List<Map<String, Object?>>> getLogArchive(String userId) async {
    final db = await _executor;
    return db.query(
      'log_archive',
      where: 'user_id = ?',
      whereArgs: [userId],
      orderBy: 'created_at DESC, id DESC',
    );
  }

  Future<int> addResultEvent({
    required String userId,
    required int? batchId,
    required String eventType,
    String? flowerId,
    int? growthValue,
    int? stageBefore,
    int? stageAfter,
    required String message,
  }) async {
    if (flowerId != null) {
      _validateFlowerId(flowerId);
    }

    final db = await _executor;
    final now = DateTime.now().toIso8601String();

    return db.insert('result_events', {
      'user_id': userId,
      'batch_id': batchId,
      'event_type': eventType,
      'flower_id': flowerId,
      'growth_value': growthValue,
      'stage_before': stageBefore,
      'stage_after': stageAfter,
      'message': message,
      'displayed': 0,
      'created_at': now,
      'displayed_at': null,
    });
  }

  Future<List<Map<String, Object?>>> getPendingResultEvents(
    String userId,
  ) async {
    final db = await _executor;
    return db.query(
      'result_events',
      where: 'user_id = ? AND displayed = 0',
      whereArgs: [userId],
      orderBy: 'created_at ASC, id ASC',
    );
  }

  Future<void> markResultEventDisplayed(int eventId) async {
    final db = await _executor;
    final now = DateTime.now().toIso8601String();

    final count = await db.update(
      'result_events',
      {'displayed': 1, 'displayed_at': now},
      where: 'id = ?',
      whereArgs: [eventId],
    );

    if (count != 1) {
      throw Exception('結果イベントの表示済み更新に失敗しました。\nevent_id: $eventId');
    }
  }

  Future<void> markBatchResultEventsDisplayed(int batchId) async {
    final db = await _executor;
    final now = DateTime.now().toIso8601String();

    await db.update(
      'result_events',
      {'displayed': 1, 'displayed_at': now},
      where: 'batch_id = ? AND displayed = 0',
      whereArgs: [batchId],
    );
  }

  Future<Map<String, int>> getDebugCounts() async {
    final db = await _executor;

    Future<int> count(String table) async {
      final result = await db.rawQuery('SELECT COUNT(*) AS count FROM $table');
      return (result.first['count'] as num?)?.toInt() ?? 0;
    }

    return {
      'users': await count('users'),
      'flowers': await count('user_flowers'),
      'seeds': await count('seed_inventory'),
      'imports': await count('import_history'),
      'batches': await count('import_batches'),
      'logs': await count('log_archive'),
      'results': await count('result_events'),
    };
  }

  Future<void> close() async {
    if (_database == null) return;
    await _database!.close();
    _database = null;
  }
}
