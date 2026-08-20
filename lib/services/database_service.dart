import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

class DatabaseService {
  DatabaseService._();

  static final DatabaseService instance =
      DatabaseService._();

  Database? _database;

  // ============================================================
  // Database getter
  // ============================================================

  Future<Database> get database async {
    if (_database != null) {
      return _database!;
    }

    _database = await _openDatabase();

    return _database!;
  }

  // ============================================================
  // Database open
  // ============================================================

  Future<Database> _openDatabase() async {
    sqfliteFfiInit();

    final factory = databaseFactoryFfi;

    final databaseFolder =
        await factory.getDatabasesPath();

    final databasePath = p.join(
      databaseFolder,
      'flower_signage.db',
    );

    debugPrint(
      'DATABASE PATH: $databasePath',
    );

    return factory.openDatabase(
      databasePath,
      options: OpenDatabaseOptions(
        version: 3,

        onConfigure: (db) async {
          await db.execute(
            'PRAGMA foreign_keys = ON',
          );
        },

        onCreate: _onCreate,

        onUpgrade: _onUpgrade,
      ),
    );
  }

  // ============================================================
  // CREATE
  // ============================================================

  Future<void> _onCreate(
    Database db,
    int version,
  ) async {
    // ----------------------------------------------------------
    // users
    // ----------------------------------------------------------

    await db.execute(
      '''
      CREATE TABLE users (
        user_id TEXT PRIMARY KEY,
        tag_mac TEXT NOT NULL UNIQUE,
        created_at TEXT NOT NULL,
        updated_at TEXT NOT NULL
      )
      ''',
    );

    // ----------------------------------------------------------
    // seed_inventory
    // ----------------------------------------------------------

    await db.execute(
      '''
      CREATE TABLE seed_inventory (
        id INTEGER PRIMARY KEY AUTOINCREMENT,

        user_id TEXT NOT NULL,

        flower_id TEXT NOT NULL,

        source_type TEXT NOT NULL,

        source_id TEXT NOT NULL,

        acquired_at TEXT NOT NULL,

        used INTEGER NOT NULL DEFAULT 0,

        used_at TEXT,

        UNIQUE(
          user_id,
          flower_id,
          source_type,
          source_id
        ),

        FOREIGN KEY(user_id)
          REFERENCES users(user_id)
          ON DELETE CASCADE
      )
      ''',
    );

    // ----------------------------------------------------------
    // user_flowers
    //
    // v3: 1つのseed_inventoryレコードに対して
    //     1つの育成花を対応させる。
    //     同じflower_idを何度でも育成可能。
    // ----------------------------------------------------------

    await db.execute(
      '''
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
      ''',
    );

    // ----------------------------------------------------------
    // import_history
    // ----------------------------------------------------------

    await db.execute(
      '''
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
      ''',
    );

    await _createIndexes(db);
  }

  // ============================================================
  // MIGRATION
  // ============================================================

  Future<void> _onUpgrade(
    Database db,
    int oldVersion,
    int newVersion,
  ) async {
    if (oldVersion < 2) {
      // --------------------------------------------------------
      // user_flowers
      // --------------------------------------------------------

      await db.execute(
        '''
        ALTER TABLE user_flowers
        ADD COLUMN is_bloomed
        INTEGER NOT NULL DEFAULT 0
        ''',
      );

      await db.execute(
        '''
        ALTER TABLE user_flowers
        ADD COLUMN bloomed_at TEXT
        ''',
      );

      // 旧コードでは未成長の花がStage 1だったため、
      // growth_value == 0 の花をStage 0へ補正
      await db.update(
        'user_flowers',
        {
          'stage': 0,
        },
        where:
            'growth_value = 0 AND stage = 1',
      );

      // --------------------------------------------------------
      // seed_inventory
      // --------------------------------------------------------

      await db.execute(
        '''
        ALTER TABLE seed_inventory
        ADD COLUMN used
        INTEGER NOT NULL DEFAULT 0
        ''',
      );

      await db.execute(
        '''
        ALTER TABLE seed_inventory
        ADD COLUMN used_at TEXT
        ''',
      );
    }

    if (oldVersion < 3) {
      // ==========================================================
      // user_flowers v3
      // ==========================================================

      await db.execute(
        '''
        CREATE TABLE user_flowers_v3 (
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
        ''',
      );

      await db.execute(
        '''
        INSERT INTO user_flowers_v3 (
          id,
          user_id,
          seed_id,
          flower_id,
          growth_value,
          stage,
          is_active,
          is_bloomed,
          acquired_at,
          bloomed_at,
          updated_at
        )
        SELECT
          id,
          user_id,
          NULL,
          flower_id,
          growth_value,
          stage,
          is_active,
          is_bloomed,
          acquired_at,
          bloomed_at,
          updated_at
        FROM user_flowers
        ''',
      );

      await db.execute(
        '''
        DROP TABLE user_flowers
        ''',
      );

      await db.execute(
        '''
        ALTER TABLE user_flowers_v3
        RENAME TO user_flowers
        ''',
      );

      await db.execute(
        '''
        CREATE INDEX IF NOT EXISTS idx_flower_user
        ON user_flowers(user_id)
        ''',
      );
    }
  }

  // ============================================================
  // INDEX
  // ============================================================

  Future<void> _createIndexes(
    Database db,
  ) async {
    await db.execute(
      '''
      CREATE INDEX IF NOT EXISTS idx_seed_user
      ON seed_inventory(user_id)
      ''',
    );

    await db.execute(
      '''
      CREATE INDEX IF NOT EXISTS idx_import_user
      ON import_history(user_id)
      ''',
    );

    await db.execute(
      '''
      CREATE INDEX IF NOT EXISTS idx_flower_user
      ON user_flowers(user_id)
      ''',
    );
  }

  // ============================================================
  // DB TEST
  // ============================================================

  Future<bool> testConnection() async {
    try {
      final db = await database;

      await db.rawQuery(
        'SELECT 1',
      );

      return true;
    } catch (_) {
      return false;
    }
  }

  // ============================================================
  // USER
  // ============================================================

  Future<void> upsertUser({
    required String userId,
    required String tagMac,
  }) async {
    final db = await database;

    final now =
        DateTime.now().toIso8601String();

    final normalizedMac =
        tagMac.trim().toUpperCase();

    final existing = await db.query(
      'users',
      where: 'user_id = ?',
      whereArgs: [userId],
      limit: 1,
    );

    if (existing.isEmpty) {
      await db.insert(
        'users',
        {
          'user_id': userId,
          'tag_mac': normalizedMac,
          'created_at': now,
          'updated_at': now,
        },
      );

      return;
    }

    await db.update(
      'users',
      {
        'tag_mac': normalizedMac,
        'updated_at': now,
      },
      where: 'user_id = ?',
      whereArgs: [userId],
    );
  }

  Future<List<Map<String, Object?>>>
      getUsers() async {
    final db = await database;

    return db.query(
      'users',
      orderBy: 'user_id ASC',
    );
  }

  Future<Map<String, Object?>?> getUser(
    String userId,
  ) async {
    final db = await database;

    final result = await db.query(
      'users',
      where: 'user_id = ?',
      whereArgs: [userId],
      limit: 1,
    );

    if (result.isEmpty) {
      return null;
    }

    return result.first;
  }

  // ============================================================
  // SEED
  // ============================================================

  Future<bool> addSeed({
    required String userId,
    required String flowerId,
    required String sourceType,
    required String sourceId,
  }) async {
    final db = await database;

    final now =
        DateTime.now().toIso8601String();

    final id = await db.insert(
      'seed_inventory',
      {
        'user_id': userId,
        'flower_id': flowerId,
        'source_type': sourceType,
        'source_id': sourceId,
        'acquired_at': now,
        'used': 0,
      },
      conflictAlgorithm:
          ConflictAlgorithm.ignore,
    );

    return id != 0;
  }

  // ============================================================
  // SEED LIST
  //
  // id ASCも追加して、同時刻でも取得順を保証
  // ============================================================

  Future<List<Map<String, Object?>>> getSeeds(
    String userId,
  ) async {
    final db = await database;

    return db.query(
      'seed_inventory',
      where: 'user_id = ?',
      whereArgs: [userId],
      orderBy: 'acquired_at ASC, id ASC',
    );
  }

  // ============================================================
  // 未使用の次の種
  // ============================================================

  Future<Map<String, Object?>?> getNextUnusedSeed(
    String userId,
  ) async {
    final db = await database;

    final result = await db.query(
      'seed_inventory',
      where:
          'user_id = ? AND used = 0',
      whereArgs: [
        userId,
      ],
      orderBy:
          'acquired_at ASC, id ASC',
      limit: 1,
    );

    if (result.isEmpty) {
      return null;
    }

    return result.first;
  }

  // ============================================================
  // SEED USED
  // ============================================================

  Future<void> markSeedUsed(
    int seedId,
  ) async {
    final db = await database;

    final now =
        DateTime.now().toIso8601String();

    final count = await db.update(
      'seed_inventory',
      {
        'used': 1,
        'used_at': now,
      },
      where:
          'id = ? AND used = 0',
      whereArgs: [
        seedId,
      ],
    );

    if (count != 1) {
      throw Exception(
        '種の使用済み更新に失敗しました。\n'
        'seed_id: $seedId',
      );
    }
  }

  // ============================================================
  // SEED CHECK
  // ============================================================

  Future<bool> hasSeed({
    required String userId,
    required String flowerId,
    required String sourceType,
    required String sourceId,
  }) async {
    final db = await database;

    final result = await db.query(
      'seed_inventory',
      columns: [
        'id',
      ],
      where:
          '''
          user_id = ?
          AND flower_id = ?
          AND source_type = ?
          AND source_id = ?
          ''',
      whereArgs: [
        userId,
        flowerId,
        sourceType,
        sourceId,
      ],
      limit: 1,
    );

    return result.isNotEmpty;
  }

  // ============================================================
  // IMPORT
  // ============================================================

  Future<bool> isImportProcessed(
    String importHash,
  ) async {
    final db = await database;

    final result = await db.query(
      'import_history',
      columns: [
        'id',
        'status',
      ],
      where:
          'import_hash = ?',
      whereArgs: [
        importHash,
      ],
      limit: 1,
    );

    if (result.isEmpty) {
      return false;
    }

    return result.first['status']
            ?.toString() ==
        'completed';
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
    final db = await database;

    final now =
        DateTime.now().toIso8601String();

    await db.insert(
      'import_history',
      {
        'user_id': userId,
        'import_hash': importHash,
        'imported_at': now,
        'growth_metric':
            growthMetric,
        'growth_value':
            growthValue,
        'record_count':
            recordCount,
        'unique_address_count':
            uniqueAddressCount,
        'status':
            status,
      },
      conflictAlgorithm:
          ConflictAlgorithm.ignore,
    );
  }

  Future<List<Map<String, Object?>>>
      getImportHistory(
    String userId,
  ) async {
    final db = await database;

    return db.query(
      'import_history',
      where: 'user_id = ?',
      whereArgs: [
        userId,
      ],
      orderBy:
          'imported_at DESC',
    );
  }

  Future<int> getImportCount(
    String userId,
  ) async {
    final db = await database;

    final result =
        await db.rawQuery(
      '''
      SELECT COUNT(*) AS count
      FROM import_history
      WHERE user_id = ?
      AND status = 'completed'
      ''',
      [
        userId,
      ],
    );

    return (result.first['count']
                as num?)
            ?.toInt() ??
        0;
  }

  // ============================================================
  // FLOWER CREATE
  // ============================================================

  Future<void> createFlowerIfNeeded({
    required String userId,
    required String flowerId,
    bool active = false,
  }) async {
    final db = await database;

    final now =
        DateTime.now().toIso8601String();

    await db.insert(
      'user_flowers',
      {
        'user_id':
            userId,
        'flower_id':
            flowerId,
        'growth_value':
            0,

        // Stage 0から開始
        'stage':
            0,

        'is_active':
            active ? 1 : 0,

        'is_bloomed':
            0,

        'acquired_at':
            now,

        'updated_at':
            now,
      },
      conflictAlgorithm:
          ConflictAlgorithm.ignore,
    );
  }

  // ============================================================
  // FLOWER
  // ============================================================

  Future<Map<String, Object?>?> getFlower({
    required String userId,
    required String flowerId,
  }) async {
    final db = await database;

    final result = await db.query(
      'user_flowers',
      where:
          '''
          user_id = ?
          AND flower_id = ?
          ''',
      whereArgs: [
        userId,
        flowerId,
      ],
      limit: 1,
    );

    if (result.isEmpty) {
      return null;
    }

    return result.first;
  }

  // ============================================================
  // ACTIVE FLOWER
  // ============================================================

  Future<Map<String, Object?>?> getActiveFlower(
    String userId,
  ) async {
    final db = await database;

    final result = await db.query(
      'user_flowers',
      where:
          '''
          user_id = ?
          AND is_active = 1
          ''',
      whereArgs: [
        userId,
      ],
      orderBy:
          'id ASC',
      limit: 1,
    );

    if (result.isEmpty) {
      return null;
    }

    return result.first;
  }

  Future<List<Map<String, Object?>>> getFlowers(
    String userId,
  ) async {
    final db = await database;

    return db.query(
      'user_flowers',
      where: 'user_id = ?',
      whereArgs: [
        userId,
      ],
      orderBy:
          'acquired_at ASC, id ASC',
    );
  }

  // ============================================================
  // FLOWER UPDATE
  // ============================================================

  Future<void> updateFlowerGrowth({
    required int userFlowerId,
    required int growthValue,
    required int stage,
  }) async {
    if (growthValue < 0) {
      throw ArgumentError(
        'growthValueは0以上で'
        'ある必要があります。',
      );
    }

    if (stage < 0 || stage > 3) {
      throw ArgumentError(
        'stageは0〜3で'
        'ある必要があります。',
      );
    }

    final db = await database;
    final now = DateTime.now().toIso8601String();

    final count = await db.update(
      'user_flowers',
      {
        'growth_value': growthValue,
        'stage': stage,
        'updated_at': now,
      },
      where: 'id = ?',
      whereArgs: [userFlowerId],
    );

    if (count != 1) {
      throw Exception(
        '花の成長状態更新に失敗しました。\n'
        'user_flower_id: $userFlowerId',
      );
    }
  }

  // ============================================================
  // ACTIVE FLOWER SET
  // ============================================================

  Future<void> setActiveFlower({
    required String userId,
    required String flowerId,
  }) async {
    final db = await database;

    await db.transaction(
      (txn) async {
        final candidates = await txn.query(
          'user_flowers',
          columns: ['id'],
          where: '''
              user_id = ?
              AND flower_id = ?
              AND is_bloomed = 0
              ''',
          whereArgs: [userId, flowerId],
          orderBy: 'id ASC',
          limit: 1,
        );

        if (candidates.isEmpty) {
          throw Exception(
            '育成する花が見つかりません。\n'
            'flower: $flowerId',
          );
        }

        final targetId =
            (candidates.first['id'] as num).toInt();

        await txn.update(
          'user_flowers',
          {'is_active': 0},
          where: 'user_id = ?',
          whereArgs: [userId],
        );

        final count = await txn.update(
          'user_flowers',
          {
            'is_active': 1,
            'updated_at': DateTime.now().toIso8601String(),
          },
          where: '''
              id = ?
              AND is_bloomed = 0
              ''',
          whereArgs: [targetId],
        );

        if (count != 1) {
          throw Exception(
            '育成する花の変更に失敗しました。\n'
            'user_flower_id: $targetId',
          );
        }
      },
    );
  }

  // ============================================================
  // BLOOM
  // ============================================================

  Future<void> markFlowerBloomed({
    required int userFlowerId,
    required int growthValue,
  }) async {
    final db = await database;
    final now = DateTime.now().toIso8601String();

    final count = await db.update(
      'user_flowers',
      {
        'growth_value': growthValue,
        'stage': 3,
        'is_bloomed': 1,
        'is_active': 0,
        'bloomed_at': now,
        'updated_at': now,
      },
      where: 'id = ?',
      whereArgs: [userFlowerId],
    );

    if (count != 1) {
      throw Exception(
        '開花状態の保存に失敗しました。\n'
        'user_flower_id: $userFlowerId',
      );
    }
  }

  // ============================================================
  // 次の種を育成開始
  //
  // 種の取得順で選択
  // ============================================================

  Future<Map<String, Object?>?>
      activateNextSeed(
    String userId,
  ) async {
    final db = await database;

    return db.transaction(
      (txn) async {
        final active = await txn.query(
          'user_flowers',
          where: '''
              user_id = ?
              AND is_active = 1
              ''',
          whereArgs: [userId],
          orderBy: 'id ASC',
          limit: 1,
        );

        if (active.isNotEmpty) {
          return active.first;
        }

        final seeds = await txn.query(
          'seed_inventory',
          where: '''
              user_id = ?
              AND used = 0
              ''',
          whereArgs: [userId],
          orderBy: 'acquired_at ASC, id ASC',
          limit: 1,
        );

        if (seeds.isEmpty) {
          return null;
        }

        final seed = seeds.first;
        final seedId = (seed['id'] as num).toInt();
        final flowerId = seed['flower_id'].toString();
        final now = DateTime.now().toIso8601String();

        final flowerRowId = await txn.insert(
          'user_flowers',
          {
            'user_id': userId,
            'seed_id': seedId,
            'flower_id': flowerId,
            'growth_value': 0,
            'stage': 0,
            'is_active': 1,
            'is_bloomed': 0,
            'acquired_at': now,
            'updated_at': now,
          },
        );

        final usedCount = await txn.update(
          'seed_inventory',
          {
            'used': 1,
            'used_at': now,
          },
          where: '''
              id = ?
              AND used = 0
              ''',
          whereArgs: [seedId],
        );

        if (usedCount != 1) {
          throw Exception(
            '種の使用状態更新に失敗しました。\n'
            'seed_id: $seedId',
          );
        }

        final result = await txn.query(
          'user_flowers',
          where: 'id = ?',
          whereArgs: [flowerRowId],
          limit: 1,
        );

        if (result.isEmpty) {
          throw Exception(
            '次の花の作成に失敗しました。\n'
            'seed_id: $seedId',
          );
        }

        return result.first;
      },
    );
  }

  // ============================================================
  // FLOWER BY ID
  // ============================================================

  Future<Map<String, Object?>?> getFlowerById(
    int userFlowerId,
  ) async {
    final db = await database;

    final result = await db.query(
      'user_flowers',
      where: 'id = ?',
      whereArgs: [userFlowerId],
      limit: 1,
    );

    if (result.isEmpty) {
      return null;
    }

    return result.first;
  }

  // ============================================================
  // DEBUG
  // ============================================================

  Future<Map<String, int>>
      getDebugCounts() async {
    final db = await database;

    Future<int> count(
      String table,
    ) async {
      final result =
          await db.rawQuery(
        'SELECT COUNT(*) AS count '
        'FROM $table',
      );

      return (result.first['count']
                  as num?)
              ?.toInt() ??
          0;
    }

    return {
      'users':
          await count('users'),
      'flowers':
          await count(
        'user_flowers',
      ),
      'seeds':
          await count(
        'seed_inventory',
      ),
      'imports':
          await count(
        'import_history',
      ),
    };
  }

  // ============================================================
  // CLOSE
  // ============================================================

  Future<void> close() async {
    if (_database == null) {
      return;
    }

    await _database!.close();

    _database = null;
  }
}