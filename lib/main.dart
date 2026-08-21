import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';

import 'services/checkpoint_service.dart';
import 'services/config_service.dart';
import 'services/database_service.dart';
import 'services/growth_service.dart';
import 'services/import_service.dart';
import 'services/interaction_service.dart';
import 'services/tag_folder_service.dart';
import 'services/usb_monitor_service.dart';
import 'services/safe_eject_service.dart';
import 'services/log_parser.dart';

void main() {
  runApp(
    const FlowerSignageApp(),
  );
}

class FlowerSignageApp extends StatelessWidget {
  const FlowerSignageApp({
    super.key,
  });

  @override
  Widget build(BuildContext context) {
    return const MaterialApp(
      debugShowCheckedModeBanner: false,
      title: 'Flower Signage',
      home: TagFolderScreen(),
    );
  }
}

class TagFolderScreen extends StatefulWidget {
  const TagFolderScreen({
    super.key,
  });

  @override
  State<TagFolderScreen> createState() =>
      _TagFolderScreenState();
}

class _TagFolderScreenState
    extends State<TagFolderScreen> {
  // ============================================================
  // CONFIG
  // ============================================================

  AppConfig? config;

  // ============================================================
  // TAG DATA
  // ============================================================

  TagFolderResult? tagResult;

  List<Checkpoint> checkpoints = [];
  List<CheckpointHit> checkpointHits = [];

  List<RegisteredUser> registeredUsers = [];
  List<InteractionHit> interactionHits = [];

  // ============================================================
  // SEEDS / FLOWER
  // ============================================================

  List<Map<String, Object?>> seedInventory = [];

  Map<String, Object?>? activeFlower;

  String? bloomedFlowerId;

  final List<String> newlyAddedSeeds = [];
  final List<String> alreadyOwnedSeeds = [];

  // ============================================================
  // STATE
  // ============================================================

  String? selectedFolder;
  String? errorMessage;
  String? currentImportHash;

  bool isLoading = false;
  bool alreadyImported = false;

  String processStatus = '待機中';

  int deletedLogCount = 0;

  // ============================================================
  // USB
  // ============================================================

  UsbMonitorService? usbMonitor;

  String usbStatus =
      'BLEタグを接続してください';

  bool isAutoProcessing = false;
  bool isSafeEjecting = false;

  // ============================================================
  // INIT
  // ============================================================

  @override
  void initState() {
    super.initState();

    _initialize();
  }

  Future<void> _initialize() async {
    try {
      debugPrint(
        '=== INITIALIZE START ===',
      );

      // ----------------------------------------------------------
      // SQLite
      // ----------------------------------------------------------

      debugPrint(
        '[INIT 1] SQLite...',
      );

      final dbOk =
          await DatabaseService.instance
              .testConnection();

      if (!dbOk) {
        throw Exception(
          'SQLiteデータベースを初期化できませんでした。',
        );
      }

      debugPrint(
        '[INIT 1] SQLite OK',
      );

      // ----------------------------------------------------------
      // Config
      // ----------------------------------------------------------

      final loadedConfig =
          await ConfigService.loadConfig();

      if (loadedConfig.debugLogging) {
        debugPrint(
          '[INIT 2] Config OK',
        );

        debugPrint(
          loadedConfig.toString(),
        );
      }

      // ----------------------------------------------------------
      // Checkpoints
      // ----------------------------------------------------------

      final loadedCheckpoints =
          await CheckpointService
              .loadCheckpoints();

      if (loadedConfig.debugLogging) {
        debugPrint(
          '[INIT 3] '
          '${loadedCheckpoints.length} checkpoints',
        );
      }

      // ----------------------------------------------------------
      // Users
      // ----------------------------------------------------------

      final loadedUsers =
          await InteractionService
              .loadUsers();

      if (loadedConfig.debugLogging) {
        debugPrint(
          '[INIT 4] '
          '${loadedUsers.length} users',
        );
      }

      if (!mounted) {
        return;
      }

      setState(() {
        config = loadedConfig;

        checkpoints =
            loadedCheckpoints;

        registeredUsers =
            loadedUsers;
      });

      _startUsbMonitor();

      if (loadedConfig.debugLogging) {
        debugPrint(
          '=== INITIALIZE COMPLETE ===',
        );
      }
    } catch (e, stackTrace) {
      debugPrint(
        'INITIALIZE ERROR: $e',
      );

      debugPrint(
        '$stackTrace',
      );

      if (!mounted) {
        return;
      }

      setState(() {
        errorMessage =
            '初期化に失敗しました。\n\n$e';

        processStatus =
            '初期化エラー';
      });
    }
  }

  // ============================================================
  // USB
  // ============================================================

  void _startUsbMonitor() {
    usbMonitor?.stop();

    if (config == null) {
      throw Exception(
        'USB監視開始時にConfigが'
        '読み込まれていません。',
      );
    }

    usbMonitor =
        UsbMonitorService(
      interval: Duration(
        seconds:
            config!.usbPollSeconds,
      ),

      disconnectMissThreshold:
          config!
              .disconnectMissThreshold,

      onTagConnected:
          (folderPath) async {
        if (config!.debugLogging) {
          debugPrint(
            'USB CONNECTED: '
            '$folderPath',
          );
        }

        if (isAutoProcessing) {
          return;
        }

        isAutoProcessing = true;

        try {
          if (!mounted) {
            return;
          }

          setState(() {
            usbStatus =
                'BLEタグを検出しました\n'
                'データを処理しています...';

            processStatus =
                'USBタグ検出';

            errorMessage =
                null;

            deletedLogCount =
                0;
          });

          await _processTagFolder(
            folderPath,
          );

          if (!mounted) {
            return;
          }

          // ==========================================================
          // 全処理成功後に安全な取り外し
          // ==========================================================

          setState(() {
            usbStatus =
                '処理が完了しました\n'
                'タグを安全に取り外しています...';

            processStatus =
                'USB安全取り外し中';
          });

          isSafeEjecting = true;

          try {
            await SafeEjectService.eject(
              folderPath,
            );

            if (!mounted) {
              return;
            }

            setState(() {
              usbStatus =
                  '処理が完了しました\n'
                  'タグを抜いてください';

              processStatus =
                  '安全に取り外しました';
            });
          } catch (_) {
            isSafeEjecting = false;

            rethrow;
          }
        } catch (e, stackTrace) {
          if (config!.debugLogging) {
            debugPrint(
              'USB PROCESS ERROR: $e',
            );

            debugPrint(
              '$stackTrace',
            );
          }

          if (!mounted) {
            return;
          }

          setState(() {
            usbStatus =
                '処理に失敗しました';

            errorMessage =
                '$e';

            processStatus =
                'エラー';

            isLoading =
                false;
          });
        } finally {
          isAutoProcessing = false;
        }
      },

      onTagDisconnected: () {
        if (config!.debugLogging) {
          debugPrint(
            'USB DISCONNECTED',
          );
        }

        if (!mounted) {
          return;
        }

        // ========================================================
        // 正常Ejectによる切断
        // ========================================================

        if (isSafeEjecting) {
          isSafeEjecting = false;

          setState(() {
            usbStatus =
                '処理が完了しました\n'
                'タグを抜いてください';

            processStatus =
                '安全に取り外しました';
          });

          return;
        }

        // ========================================================
        // ユーザーが物理的に抜いた / 異常切断
        // ========================================================

        setState(() {
          usbStatus =
              'BLEタグを接続してください';

          processStatus =
              '待機中';
        });
      },
    );

    usbMonitor!.start();
  }

  @override
  void dispose() {
    usbMonitor?.stop();

    super.dispose();
  }

  // ============================================================
  // MANUAL FOLDER
  // ============================================================

  Future<void>
      selectTagFolder() async {
    try {
      final folderPath =
          await FilePicker
              .getDirectoryPath();

      if (folderPath == null) {
        return;
      }

      await _processTagFolder(
        folderPath,
      );
    } catch (e, stackTrace) {
      if (config?.debugLogging ??
          true) {
        debugPrint(
          'MANUAL ERROR: $e',
        );

        debugPrint(
          '$stackTrace',
        );
      }

      if (!mounted) {
        return;
      }

      setState(() {
        errorMessage =
            '$e';

        processStatus =
            '手動読込エラー';

        isLoading =
            false;
      });
    }
  }

  // ============================================================
  // MAIN PROCESS
  // ============================================================

  Future<void> _processTagFolder(
    String folderPath,
  ) async {
    if (config == null) {
      throw Exception(
        '設定ファイルが'
        '読み込まれていません。',
      );
    }

    final cfg = config!;

    if (mounted) {
      setState(() {
        isLoading = true;

        errorMessage = null;

        tagResult = null;

        checkpointHits = [];
        interactionHits = [];

        seedInventory = [];

        activeFlower = null;
        bloomedFlowerId = null;

        newlyAddedSeeds.clear();
        alreadyOwnedSeeds.clear();

        alreadyImported = false;

        currentImportHash = null;

        deletedLogCount = 0;

        selectedFolder =
            folderPath;

        processStatus =
            '[1] LOG読込中';
      });
    }

    // ==========================================================
    // 1. LOG
    // ==========================================================

    if (cfg.debugLogging) {
      debugPrint(
        '================================',
      );

      debugPrint(
        '[1] Reading tag folder...',
      );
    }

    final result =
        await TagFolderService
            .loadFolder(
      folderPath,
    );

    // final growthValue =
    //     result.uniqueAddresses.length;
    
    // ==========================================================
    // USER + INITIAL SEEDS
    //
    // 二重処理判定より前に行う。
    // 処理済みLOGでも初期種を保証する。
    // ==========================================================

    await DatabaseService.instance
        .upsertUser(
      userId:
          result.userInfo.userId,

      tagMac:
          result.userInfo.macAddress,
    );

    await DatabaseService.instance
        .ensureInitialSeeds(
      userId:
          result.userInfo.userId,

      initialSeeds:
          cfg.initialSeeds,
    );

    if (cfg.debugLogging) {
      debugPrint(
        '[1] LOG count = '
        '${result.logFiles.length}',
      );

      debugPrint(
        '[1] Record count = '
        '${result.totalRecordCount}',
      );

      debugPrint(
        '[1] Unique addresses = '
        '${result.uniqueAddresses.length}',
      );
    }

    // ==========================================================
    // LOG 0件
    //
    // エラーではなく正常終了。
    // User登録・初期種付与までは実施する。
    // 成長・Checkpoint・交流・ImportHistoryは実施しない。
    // ==========================================================

    if (result.logFiles.isEmpty) {
      // 現在育成中の花を確認
      var currentFlower =
          await DatabaseService.instance
              .getActiveFlower(
        result.userInfo.userId,
      );

      // 初回ユーザーなど、
      // まだ育成中の花がなければ
      // 最初の初期種をStage 0で育成開始
      currentFlower ??=
          await DatabaseService.instance
              .activateNextSeed(
        result.userInfo.userId,
      );

      final seeds =
          await DatabaseService.instance
              .getSeeds(
        result.userInfo.userId,
      );

      if (!mounted) {
        return;
      }

      setState(() {
        tagResult =
            result;

        seedInventory =
            seeds;

        activeFlower =
            currentFlower;

        checkpointHits =
            [];

        interactionHits =
            [];

        bloomedFlowerId =
            null;

        alreadyImported =
            false;

        deletedLogCount =
            0;

        processStatus =
            '新しいLOGはありません';

        isLoading =
            false;
      });

      if (cfg.debugLogging) {
        debugPrint(
          '================================',
        );

        debugPrint(
          '=== NO LOG FILES ===',
        );

        debugPrint(
          'User = '
          '${result.userInfo.userId}',
        );

        debugPrint(
          'LOG count = 0',
        );

        debugPrint(
          'Growth update = SKIPPED',
        );

        debugPrint(
          'Active flower = '
          '${currentFlower?['flower_id']}',
        );

        debugPrint(
          '================================',
        );
      }

      return;
    }

    // ==========================================================
    // v5 TEST: LOGごとのSHA-256 + 新規LOG判定
    // ==========================================================

    final newLogFiles = <File>[];
    final knownLogFiles = <File>[];

    for (final logFile in result.logFiles) {
      final fileHash =
          await TagFolderService.calculateLogHash(
        logFile,
      );

      final exists =
          await DatabaseService.instance.hasLogHash(
        userId: result.userInfo.userId,
        fileHash: fileHash,
      );

      if (exists) {
        knownLogFiles.add(logFile);
      } else {
        newLogFiles.add(logFile);
      }
    }

    debugPrint(
      '================================',
    );

    debugPrint(
      '=== LOG HASH CHECK ===',
    );

    debugPrint(
      'Total LOG = ${result.logFiles.length}',
    );

    debugPrint(
      'Already known = ${knownLogFiles.length}',
    );

    debugPrint(
      'New LOG = ${newLogFiles.length}',
    );

    debugPrint(
      '================================',
    );
        
    // ==========================================================
    // 今回の新規LOGだけを処理対象にする
    // ==========================================================

    final newLogPaths =
        newLogFiles
            .map((file) => file.path)
            .toSet();

    final newLogResults =
        <LogParseResult>[];

    for (int i = 0;
        i < result.logFiles.length;
        i++) {
      final file =
          result.logFiles[i];

      if (newLogPaths.contains(
        file.path,
      )) {
        newLogResults.add(
          result.logResults[i],
        );
      }
    }

    // 今回の新規LOGだけの全レコード
    final newRecords =
        newLogResults
            .expand(
              (logResult) =>
                  logResult.records,
            )
            .toList();

    // 今回の新規LOGだけのユニークMAC
    final newUniqueAddresses =
        newRecords
            .map(
              (record) =>
                  record.address,
            )
            .toSet();

    final newRecordCount =
        newRecords.length;

    final growthValue =
        cfg.growthMetric ==
                'detection_count'
            ? newRecordCount
            : newUniqueAddresses.length;

    if (cfg.debugLogging) {
      debugPrint(
        '================================',
      );

      debugPrint(
        '=== NEW LOG DATA ===',
      );

      debugPrint(
        'New records = '
        '$newRecordCount',
      );

      debugPrint(
        'New unique addresses = '
        '${newUniqueAddresses.length}',
      );

      debugPrint(
        'Growth value = '
        '$growthValue',
      );

      debugPrint(
        '================================',
      );
    }

    if (newLogFiles.isEmpty) {
      final seeds =
          await DatabaseService.instance
              .getSeeds(
        result.userInfo.userId,
      );

      final currentFlower =
          await DatabaseService.instance
              .getActiveFlower(
        result.userInfo.userId,
      );

      if (!mounted) {
        return;
      }

      setState(() {
        tagResult =
            result;

        seedInventory =
            seeds;

        activeFlower =
            currentFlower;

        checkpointHits =
            [];

        interactionHits =
            [];

        bloomedFlowerId =
            null;

        alreadyImported =
            true;

        deletedLogCount =
            0;

        processStatus =
            '新しいLOGはありません';

        isLoading =
            false;
      });

      if (cfg.debugLogging) {
        debugPrint(
          '================================',
        );

        debugPrint(
          '=== NO NEW LOG ===',
        );

        debugPrint(
          'Growth update = SKIPPED',
        );

        debugPrint(
          'Checkpoint = SKIPPED',
        );

        debugPrint(
          'Interaction = SKIPPED',
        );

        debugPrint(
          '================================',
        );
      }

      return;
    }

    // ==========================================================
    // 2. HASH
    // ==========================================================

    if (mounted) {
      setState(() {
        processStatus =
            '[2] LOG識別情報作成中';
      });
    }

    final importHash =
        await ImportService
            .createImportHash(
      result.logFiles,
    );

    currentImportHash =
        importHash;

    // ==========================================================
    // 3. DUPLICATE
    // ==========================================================

    if (mounted) {
      setState(() {
        processStatus =
            '[3] 二重処理確認中';
      });
    }

    final processed =
        await DatabaseService.instance
            .isImportProcessed(
      importHash,
    );

    if (cfg.debugLogging) {
      debugPrint(
        '[3] processed = $processed',
      );
    }

    // ==========================================================
    // ALREADY PROCESSED
    // ==========================================================

    if (processed) {
      final verified =
          await DatabaseService.instance
              .isImportProcessed(
        importHash,
      );

      if (!verified) {
        throw Exception(
          '処理済みデータの'
          'DB確認に失敗しました。\n'
          'LOGは削除していません。',
        );
      }

      final seeds =
          await DatabaseService.instance
              .getSeeds(
        result.userInfo.userId,
      );

      final currentFlower =
          await DatabaseService.instance
              .getActiveFlower(
        result.userInfo.userId,
      );

      int deleted = 0;

      if (cfg.deleteLogsAfterSuccess &&
          cfg.deleteProcessedLogs) {
        if (mounted) {
          setState(() {
            processStatus =
                '[10] 処理済みLOG削除中';
          });
        }

        deleted =
            await TagFolderService
                .deleteLogFiles(
          result.logFiles,
        );
      }

      if (!mounted) {
        return;
      }

      setState(() {
        tagResult =
            result;

        seedInventory =
            seeds;

        activeFlower =
            currentFlower;

        alreadyImported =
            true;

        deletedLogCount =
            deleted;

        processStatus =
            (cfg.deleteLogsAfterSuccess &&
                    cfg.deleteProcessedLogs)
                ? '処理済みLOG削除完了'
                : '処理済みデータ';

        isLoading =
            false;
      });

      return;
    }

    // ==========================================================
    // 4. RECORDS
    // ==========================================================

    final allRecords = newRecords;

    // ==========================================================
    // 5. CHECKPOINT
    // ==========================================================

    if (mounted) {
      setState(() {
        processStatus =
            '[5] チェックポイント判定中';
      });
    }

    final rawCheckpointHits =
        CheckpointService.detect(
      records:
          allRecords,

      checkpoints:
          checkpoints,

      scanGroupSeconds:
          cfg.scanGroupSeconds,
    );

    // ----------------------------------------------------------
    // 1接続につき各Checkpoint 1回
    // ----------------------------------------------------------

    final uniqueCheckpointHits =
        <CheckpointHit>[];

    final seenCheckpointIds =
        <String>{};

    for (final hit
        in rawCheckpointHits) {
      final id =
          hit.checkpoint.id;

      if (seenCheckpointIds.add(id)) {
        uniqueCheckpointHits.add(
          hit,
        );
      }
    }

    // ==========================================================
    // 6. INTERACTION
    // ==========================================================

    if (mounted) {
      setState(() {
        processStatus =
            '[6] 交流判定中';
      });
    }

    final rawInteractions =
        InteractionService.detect(
      detectedAddresses:
          newUniqueAddresses,

      users:
          registeredUsers,

      ownTagMac:
          result.userInfo
              .macAddress,
    );

    // ----------------------------------------------------------
    // 1接続につき各ユーザー 1回
    // ----------------------------------------------------------

    final uniqueInteractions =
        <InteractionHit>[];

    final seenUserIds =
        <String>{};

    for (final hit
        in rawInteractions) {
      final id =
          hit.user.userId;

      if (seenUserIds.add(id)) {
        uniqueInteractions.add(
          hit,
        );
      }
    }

    // ==========================================================
    // 7. USER + SEEDS
    //
    // Checkpointを先に登録
    // その後Interaction
    // ==========================================================

    if (mounted) {
      setState(() {
        processStatus =
            '[7] 種・ユーザー保存中';
      });
    }

    await _saveUserAndSeeds(
      result:
          result,

      importHash:
          importHash,

      checkpointHits:
          uniqueCheckpointHits,

      interactionHits:
          uniqueInteractions,
    );

    // ==========================================================
    // 8. FLOWER GROWTH
    // ==========================================================

    if (mounted) {
      setState(() {
        processStatus =
            '[8] 花の成長判定中';
      });
    }

    final flowerResult =
        await _processFlowerGrowth(
      userId:
          result.userInfo.userId,

      growthValue:
          growthValue,
    );

    // ==========================================================
    // 9. IMPORT HISTORY
    // ==========================================================

    if (mounted) {
      setState(() {
        processStatus =
            '[9] 読込履歴保存中';
      });
    }

    await DatabaseService.instance
        .addImportHistory(
      userId:
          result.userInfo.userId,

      importHash:
          importHash,

      growthMetric:
          cfg.growthMetric,

      growthValue:
          growthValue,

      recordCount:
          newRecordCount,

      uniqueAddressCount:
          newUniqueAddresses.length,

      status:
          'completed',
    );

    // ==========================================================
    // 10. VERIFY
    // ==========================================================

    final dbUser =
        await DatabaseService.instance
            .getUser(
      result.userInfo.userId,
    );

    if (dbUser == null) {
      throw Exception(
        'SQLite保存確認失敗。\n'
        'ユーザー情報がありません。\n'
        'LOGは削除しません。',
      );
    }

    final importVerified =
        await DatabaseService.instance
            .isImportProcessed(
      importHash,
    );

    if (!importVerified) {
      throw Exception(
        'ImportHistoryの'
        '保存確認に失敗しました。\n'
        'LOGは削除しません。',
      );
    }

    final seeds =
        await DatabaseService.instance
            .getSeeds(
      result.userInfo.userId,
    );

    // ==========================================================
    // v5: 新規LOGをarchiveへ保存
    //
    // 既存の全処理とDB保存確認が成功した後に行う。
    // ここまで到達したLOGだけを「処理済みLOG」として保存する。
    // ==========================================================

    int? archiveBatchId;

    if (newLogFiles.isNotEmpty) {
      archiveBatchId =
          await DatabaseService.instance
              .createImportBatch(
        userId:
            result.userInfo.userId,
        batchHash:
            importHash,
        growthMetric:
            cfg.growthMetric,
      );

      for (final logFile
          in newLogFiles) {
        final fileHash =
            await TagFolderService
                .calculateLogHash(
          logFile,
        );

        final rawContent =
            await logFile.readAsString();

        // result.logFiles と result.logResults は
        // 同じ順番で作成されているので対応付ける
        final index =
            result.logFiles.indexWhere(
          (file) =>
              file.path == logFile.path,
        );

        if (index < 0 ||
            index >= result.logResults.length) {
          throw Exception(
            'LOG解析結果との対応付けに'
            '失敗しました。\n'
            '${logFile.path}',
          );
        }

        final recordCount =
            result
                .logResults[index]
                .records
                .length;

        await DatabaseService.instance
            .archiveLog(
          userId:
              result.userInfo.userId,
          batchId:
              archiveBatchId,
          fileName:
              logFile.uri.pathSegments.last,
          fileHash:
              fileHash,
          rawContent:
              rawContent,
          recordCount:
              recordCount,
        );
      }

      // -----------------------------------------------
      // このBatch内のLOGを処理済みにする
      // -----------------------------------------------

      await DatabaseService.instance
          .markBatchLogsProcessed(
        archiveBatchId,
      );

      // -----------------------------------------------
      // Batch自体もcompletedにする
      // -----------------------------------------------

      await DatabaseService.instance
          .completeImportBatch(
        batchId:
            archiveBatchId,
        growthValue:
            growthValue,
        recordCount:
            newRecordCount,

        uniqueAddressCount:
            newUniqueAddresses.length,
        checkpointCount:
            uniqueCheckpointHits.length,
        interactionCount:
            uniqueInteractions.length,
      );

      if (cfg.debugLogging) {
        debugPrint(
          '================================',
        );

        debugPrint(
          '=== LOG ARCHIVE SUCCESS ===',
        );

        debugPrint(
          'Batch ID = $archiveBatchId',
        );

        debugPrint(
          'Archived LOG = '
          '${newLogFiles.length}',
        );

        debugPrint(
          '================================',
        );
      }
    }

    // ==========================================================
    // 11. LOG DELETE
    // ==========================================================

    int deleted = 0;

    if (cfg.deleteLogsAfterSuccess) {
      if (mounted) {
        setState(() {
          processStatus =
              '[11] LOG削除中';
        });
      }

      deleted =
          await TagFolderService
              .deleteLogFiles(
        result.logFiles,
      );
    }

    if (!mounted) {
      return;
    }

    setState(() {
      tagResult =
          result;

      checkpointHits =
          uniqueCheckpointHits;

      interactionHits =
          uniqueInteractions;

      seedInventory =
          seeds;

      activeFlower =
          flowerResult.activeFlower;

      bloomedFlowerId =
          flowerResult.bloomedFlowerId;

      alreadyImported =
          false;

      deletedLogCount =
          deleted;

      processStatus =
          cfg.deleteLogsAfterSuccess
              ? '保存・LOG削除完了'
              : '保存完了';

      isLoading =
          false;
    });

    if (cfg.debugLogging) {
      debugPrint(
        '================================',
      );

      debugPrint(
        '=== ALL PROCESS SUCCESS ===',
      );

      debugPrint(
        'Growth value = $growthValue',
      );

      debugPrint(
        'Bloomed flower = '
        '$bloomedFlowerId',
      );

      debugPrint(
        'Active flower = '
        '${activeFlower?['flower_id']}',
      );

      debugPrint(
        'Deleted LOG = $deleted',
      );

      debugPrint(
        '================================',
      );
    }
  }

  // ============================================================
  // USER + SEEDS
  // ============================================================

  Future<void> _saveUserAndSeeds({
    required TagFolderResult result,
    required String importHash,
    required List<CheckpointHit>
        checkpointHits,
    required List<InteractionHit>
        interactionHits,
  }) async {
    final userId =
        result.userInfo.userId;



    // ==========================================================
    // CHECKPOINT FIRST
    // ==========================================================

    for (final hit
        in checkpointHits) {
      final flower =
          hit.checkpoint.flower;

      /*
       * importHashをsourceIdへ含めることで、
       *
       * 同じCheckpoint
       * + 同じ接続
       * → 1回だけ
       *
       * 同じCheckpoint
       * + 別の接続
       * → 再び1個取得可能
       */

      final sourceId =
          '${hit.checkpoint.id}:'
          '$importHash';

      final added =
          await DatabaseService.instance
              .addSeed(
        userId:
            userId,

        flowerId:
            flower,

        sourceType:
            'checkpoint',

        sourceId:
            sourceId,
      );

      if (added) {
        newlyAddedSeeds.add(
          '$flower'
          '（${hit.checkpoint.name}）',
        );
      }
    }

    // ==========================================================
    // INTERACTION SECOND
    // ==========================================================

    for (final hit
        in interactionHits) {
      final flower =
          hit.user.flower;

      final sourceId =
          '${hit.user.userId}:'
          '$importHash';

      final added =
          await DatabaseService.instance
              .addSeed(
        userId:
            userId,

        flowerId:
            flower,

        sourceType:
            'interaction',

        sourceId:
            sourceId,
      );

      if (added) {
        newlyAddedSeeds.add(
          '$flower'
          '（${hit.user.name}との交流）',
        );
      }
    }
  }

  // ============================================================
  // FLOWER PROCESS
  // ============================================================

  Future<FlowerProcessResult>
      _processFlowerGrowth({
    required String userId,
    required int growthValue,
  }) async {
    if (config == null) {
      throw Exception(
        'Configがありません。',
      );
    }

    

    // ==========================================================
    // 今回のデータが何段階分の成長に相当するか
    //
    // 例:
    //   0〜298   -> 0段階
    //   299〜599 -> 1段階
    //   600〜999 -> 2段階
    //   1000〜   -> 3段階
    // ==========================================================

    int remainingStages =
        GrowthService.calculateStage(
      value:
          growthValue,
      config:
          config!,
    );

    if (config!.debugLogging) {
      debugPrint(
        '================================',
      );

      debugPrint(
        '=== FLOWER STAGE GROWTH ===',
      );

      debugPrint(
        'Growth value = $growthValue',
      );

      debugPrint(
        'Stage delta = $remainingStages',
      );

      debugPrint(
        '================================',
      );
    }

    // ==========================================================
    // 現在育成中の花
    // ==========================================================

    var current =
        await DatabaseService.instance
            .getActiveFlower(
      userId,
    );

    // 現在の花がなければ、
    // 一番古い未使用種を開始
    current ??=
        await DatabaseService.instance
            .activateNextSeed(
      userId,
    );

    // 種自体がない
    if (current == null) {
      return const FlowerProcessResult(
        activeFlower:
            null,
        bloomedFlowerId:
            null,
      );
    }

    // 今回Stage 0相当なら
    // 現在の状態を変更しない
    if (remainingStages <= 0) {
      return FlowerProcessResult(
        activeFlower:
            current,
        bloomedFlowerId:
            null,
      );
    }

    String? bloomedFlowerId;

    // ==========================================================
    // 段階数を順番に消費する
    // ==========================================================

    while (remainingStages > 0 &&
        current != null) {
      final userFlowerId =
          (current['id'] as num)
              .toInt();

      final flowerId =
          current['flower_id']
              .toString();

      final currentStage =
          (current['stage'] as num?)
                  ?.toInt() ??
              0;

      // 開花まであと何段階必要か
      final stagesToBloom =
          3 - currentStage;

      if (config!.debugLogging) {
        debugPrint(
          'Flower = $flowerId',
        );

        debugPrint(
          'Current stage = '
          '$currentStage',
        );

        debugPrint(
          'Remaining stages = '
          '$remainingStages',
        );

        debugPrint(
          'Stages to bloom = '
          '$stagesToBloom',
        );
      }

      // ========================================================
      // 今回の残り段階だけでは開花しない
      // ========================================================

      if (remainingStages <
          stagesToBloom) {
        final newStage =
            currentStage +
                remainingStages;

        await DatabaseService.instance
            .updateFlowerGrowth(
          userFlowerId:
              userFlowerId,

          growthValue:
              _growthValueForStage(
            newStage,
          ),

          stage:
              newStage,
        );

        remainingStages = 0;

        current =
            await DatabaseService.instance
                .getFlowerById(
          userFlowerId,
        );

        if (config!.debugLogging) {
          debugPrint(
            'Flower stage updated: '
            '$currentStage -> $newStage',
          );
        }

        break;
      }

      // ========================================================
      // 現在の花が開花する
      // ========================================================

      remainingStages -=
          stagesToBloom;

      await DatabaseService.instance
          .markFlowerBloomed(
        userFlowerId:
            userFlowerId,

        growthValue:
            _growthValueForStage(
          3,
        ),
      );

      bloomedFlowerId =
          flowerId;

      if (config!.debugLogging) {
        debugPrint(
          'Flower bloomed: '
          '$flowerId',
        );

        debugPrint(
          'Remaining stages after bloom = '
          '$remainingStages',
        );
      }

      // ========================================================
      // 次の種を育成開始
      // ========================================================

      current =
          await DatabaseService.instance
              .activateNextSeed(
        userId,
      );

      // 次の種がなければ、
      // 余った段階はここで終了
      if (current == null) {
        if (config!.debugLogging) {
          debugPrint(
            'No next seed.',
          );

          debugPrint(
            'Unused stages = '
            '$remainingStages',
          );
        }

        remainingStages = 0;

        break;
      }
    }

    return FlowerProcessResult(
      activeFlower:
          current,

      bloomedFlowerId:
          bloomedFlowerId,
    );
  }

  // ★ この位置に置く
  int _growthValueForStage(
    int stage,
  ) {
    if (config == null) {
      return 0;
    }

    switch (stage) {
      case 0:
        return 0;

      case 1:
        return config!.stage1Threshold;

      case 2:
        return config!.stage2Threshold;

      case 3:
        return config!.stage3Threshold;

      default:
        return 0;
    }
  }
  
  // ============================================================
  // CURRENT VALUES
  // ============================================================

  int get growthValue {
    if (tagResult == null) {
      return 0;
    }

    return tagResult!
        .uniqueAddresses
        .length;
  }

  int get currentStage {
    if (activeFlower == null) {
      return 0;
    }

    return (activeFlower!['stage']
                as num?)
            ?.toInt() ??
        0;
  }

  String get currentFlowerId {
    if (activeFlower == null) {
      return 'なし';
    }

    return activeFlower![
            'flower_id']
        .toString();
  }

  // ============================================================
  // SIMPLE DEBUG UI
  // ============================================================

  String get flowerEmoji {
    switch (currentStage) {
      case 0:
        return '🫘';

      case 1:
        return '🌱';

      case 2:
        return '🌿';

      case 3:
        return '🌻';

      default:
        return '🫘';
    }
  }

  String get stageMessage {
    if (activeFlower == null) {
      return '育てる種がありません';
    }

    switch (currentStage) {
      case 0:
        return 'まだ芽は出ていません';

      case 1:
        return '芽が出ました';

      case 2:
        return '成長しています';

      case 3:
        return '花が咲きました';

      default:
        return '';
    }
  }

  // ============================================================
  // UI
  // ============================================================

  @override
  Widget build(
    BuildContext context,
  ) {
    if (config == null &&
        errorMessage == null) {
      return const Scaffold(
        body: Center(
          child:
              CircularProgressIndicator(),
        ),
      );
    }

    return Scaffold(
      body: SafeArea(
        child: SingleChildScrollView(
          padding:
              const EdgeInsets.all(
            32,
          ),
          child: Center(
            child: ConstrainedBox(
              constraints:
                  const BoxConstraints(
                maxWidth:
                    850,
              ),
              child: Column(
                children: [
                  const SizedBox(
                    height:
                        20,
                  ),

                  const Text(
                    'BLEタグ 花育成システム',
                    style:
                        TextStyle(
                      fontSize:
                          38,
                      fontWeight:
                          FontWeight.bold,
                    ),
                  ),

                  const SizedBox(
                    height:
                        25,
                  ),

                  Text(
                    usbStatus,
                    textAlign:
                        TextAlign.center,
                    style:
                        const TextStyle(
                      fontSize:
                          24,
                      fontWeight:
                          FontWeight.bold,
                    ),
                  ),

                  const SizedBox(
                    height:
                        15,
                  ),

                  Text(
                    '処理状態：'
                    '$processStatus',
                  ),

                  const SizedBox(
                    height:
                        20,
                  ),

                  ElevatedButton(
                    onPressed:
                        isLoading
                            ? null
                            : selectTagFolder,
                    child:
                        const Text(
                      'タグフォルダを手動選択',
                    ),
                  ),

                  if (isLoading) ...[
                    const SizedBox(
                      height:
                          20,
                    ),
                    const CircularProgressIndicator(),
                  ],

                  if (errorMessage !=
                      null) ...[
                    const SizedBox(
                      height:
                          20,
                    ),

                    Text(
                      errorMessage!,
                      textAlign:
                          TextAlign.center,
                    ),
                  ],

                  if (tagResult !=
                      null) ...[
                    const SizedBox(
                      height:
                          30,
                    ),

                    Text(
                      'User ID：'
                      '${tagResult!.userInfo.userId}',
                    ),

                    Text(
                      'ユニークアドレス数：'
                      '${tagResult!.uniqueAddresses.length}',
                    ),

                    const SizedBox(
                      height:
                          25,
                    ),

                    Text(
                      flowerEmoji,
                      style:
                          const TextStyle(
                        fontSize:
                            140,
                      ),
                    ),

                    Text(
                      '現在の花：'
                      '$currentFlowerId',
                      style:
                          const TextStyle(
                        fontSize:
                            24,
                        fontWeight:
                            FontWeight.bold,
                      ),
                    ),

                    Text(
                      'Stage '
                      '$currentStage',
                      style:
                          const TextStyle(
                        fontSize:
                            26,
                      ),
                    ),

                    Text(
                      stageMessage,
                    ),

                    if (bloomedFlowerId !=
                        null) ...[
                      const SizedBox(
                        height:
                            15,
                      ),

                      Text(
                        '🌸 '
                        '$bloomedFlowerId '
                        'が開花しました！',
                        style:
                            const TextStyle(
                          fontSize:
                              22,
                          fontWeight:
                              FontWeight.bold,
                        ),
                      ),
                    ],

                    const SizedBox(
                      height:
                          25,
                    ),

                    Text(
                      'Checkpoint：'
                      '${checkpointHits.length}',
                    ),

                    Text(
                      '交流：'
                      '${interactionHits.length}',
                    ),

                    Text(
                      '所持種：'
                      '${seedInventory.length}',
                    ),

                    Text(
                      '削除LOG：'
                      '$deletedLogCount',
                    ),

                    const SizedBox(
                      height:
                          40,
                    ),
                  ],
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

// ================================================================
// Flower process result
// ================================================================

class FlowerProcessResult {
  final Map<String, Object?>?
      activeFlower;

  final String?
      bloomedFlowerId;

  const FlowerProcessResult({
    required this.activeFlower,
    required this.bloomedFlowerId,
  });
}