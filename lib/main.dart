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

enum SignageViewState {
  waiting,
  processing,
  growth,
  bloom,
  complete,
}

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
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      title: 'Flower Signage',
      theme: ThemeData(
        useMaterial3: true,
        fontFamily: 'sans-serif',
      ),
      home: const TagFolderScreen(),
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
  // SIGNAGE UI
  // ============================================================

  SignageViewState signageViewState =
      SignageViewState.waiting;

  String? uiFlowerId;
  int uiStage = 0;

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

        signageViewState =
            SignageViewState.waiting;
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

            signageViewState =
                SignageViewState.processing;
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

            signageViewState =
                SignageViewState.processing;
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

              signageViewState =
                  SignageViewState.complete;
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

            signageViewState =
                SignageViewState.complete;
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

          signageViewState =
              SignageViewState.waiting;
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

        signageViewState =
            SignageViewState.processing;
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

      uiFlowerId =
          flowerResult.activeFlower?['flower_id']
              ?.toString();

      uiStage =
          (flowerResult.activeFlower?['stage'] as num?)
                  ?.toInt() ??
              0;
    });

    await _playResultPresentation(
      flowerResult,
    );

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
  // SIGNAGE UI HELPERS
  // ============================================================

  String _flowerAsset(
    String flowerId,
    String suffix,
  ) {
    return 'assets/images/'
        '${flowerId}_$suffix.png';
  }

  Widget _buildFlowerStage({
    required String flowerId,
    required int stage,
    double height = 320,
  }) {
    if (flowerId.isEmpty ||
        flowerId == 'なし') {
      return SizedBox(
        height: height,
        child: const Center(
          child: Icon(
            Icons.local_florist_outlined,
            size: 110,
          ),
        ),
      );
    }

    switch (stage) {
      case 0:
        return SizedBox(
          height: height,
          child: Center(
            child: Image.asset(
              _flowerAsset(
                flowerId,
                'seed',
              ),
              height: height * 0.42,
              fit: BoxFit.contain,
            ),
          ),
        );

      case 1:
        return SizedBox(
          height: height,
          child: Center(
            child: Image.asset(
              _flowerAsset(
                flowerId,
                'mini',
              ),
              height: height * 0.68,
              fit: BoxFit.contain,
            ),
          ),
        );

      case 2:
        return SizedBox(
          height: height,
          width: height * 0.9,
          child: Stack(
            alignment: Alignment.center,
            children: [
              Positioned(
                bottom: 0,
                child: Image.asset(
                  _flowerAsset(
                    flowerId,
                    'big',
                  ),
                  height: height * 0.82,
                  fit: BoxFit.contain,
                ),
              ),
              Positioned(
                top: height * 0.01,
                child: Image.asset(
                  _flowerAsset(
                    flowerId,
                    'befoflo',
                  ),
                  height: height * 0.36,
                  fit: BoxFit.contain,
                ),
              ),
            ],
          ),
        );

      case 3:
        return SizedBox(
          height: height,
          width: height * 0.9,
          child: Stack(
            alignment: Alignment.center,
            children: [
              Positioned(
                bottom: 0,
                child: Image.asset(
                  _flowerAsset(
                    flowerId,
                    'big',
                  ),
                  height: height * 0.82,
                  fit: BoxFit.contain,
                ),
              ),
              Positioned(
                top: 0,
                child: Image.asset(
                  'assets/images/'
                  '$flowerId.png',
                  height: height * 0.40,
                  fit: BoxFit.contain,
                ),
              ),
            ],
          ),
        );

      default:
        return const SizedBox();
    }
  }

  Future<void> _playResultPresentation(
    FlowerProcessResult flowerResult,
  ) async {
    if (!mounted) {
      return;
    }

    final bloomedId =
        flowerResult.bloomedFlowerId;

    if (bloomedId != null) {
      setState(() {
        signageViewState =
            SignageViewState.bloom;

        uiFlowerId =
            bloomedId;

        uiStage =
            3;
      });

      await Future<void>.delayed(
        const Duration(
          milliseconds: 1800,
        ),
      );

      if (!mounted) {
        return;
      }
    }

    final nextFlower =
        flowerResult.activeFlower;

    if (nextFlower != null) {
      final nextStage =
          (nextFlower['stage'] as num?)
                  ?.toInt() ??
              0;

      if (bloomedId == null ||
          nextStage > 0) {
        setState(() {
          signageViewState =
              SignageViewState.growth;

          uiFlowerId =
              nextFlower['flower_id']
                  ?.toString();

          uiStage =
              nextStage;
        });

        await Future<void>.delayed(
          const Duration(
            milliseconds: 1400,
          ),
        );
      }
    }
  }

  Widget _buildMainSignageContent(
    double availableHeight,
  ) {
    final mainImageHeight =
        (availableHeight * 0.40)
            .clamp(
              180.0,
              390.0,
            )
            .toDouble();

    switch (signageViewState) {
      case SignageViewState.waiting:
        return _statusPanel(
          image: Image.asset(
            'assets/images/take.png',
            height: mainImageHeight * 0.72,
            fit: BoxFit.contain,
          ),
          title:
              'タグを接続してください',
          subtitle:
              'ケーブルにタグを挿すと、自動で読み込みを開始します',
        );

      case SignageViewState.processing:
        return _statusPanel(
          image: Image.asset(
            'assets/images/no_take.png',
            height: mainImageHeight * 0.72,
            fit: BoxFit.contain,
          ),
          title:
              'タグを抜かないでください',
          subtitle:
              '活動データを読み込んでいます…',
          loading:
              true,
        );

      case SignageViewState.growth:
        final flowerId =
            uiFlowerId ??
                currentFlowerId;

        final stage =
            uiFlowerId != null
                ? uiStage
                : currentStage;

        return _statusPanel(
          image: AnimatedSwitcher(
            duration:
                const Duration(
              milliseconds: 650,
            ),
            transitionBuilder:
                (
              child,
              animation,
            ) {
              return FadeTransition(
                opacity:
                    animation,
                child:
                    ScaleTransition(
                  scale:
                      Tween<double>(
                    begin:
                        0.82,
                    end:
                        1.0,
                  ).animate(
                    CurvedAnimation(
                      parent:
                          animation,
                      curve:
                          Curves.easeOutBack,
                    ),
                  ),
                  child:
                      child,
                ),
              );
            },
            child: KeyedSubtree(
              key: ValueKey(
                '$flowerId-$stage',
              ),
              child:
                  _buildFlowerStage(
                flowerId:
                    flowerId,
                stage:
                    stage,
                height:
                    mainImageHeight,
              ),
            ),
          ),
          title:
              '花が成長しました！',
          subtitle:
              'Stage $stage / 3',
        );

      case SignageViewState.bloom:
        final flowerId =
            uiFlowerId ??
                bloomedFlowerId ??
                currentFlowerId;

        return _statusPanel(
          image:
              TweenAnimationBuilder<double>(
            tween:
                Tween<double>(
              begin:
                  0.55,
              end:
                  1.0,
            ),
            duration:
                const Duration(
              milliseconds:
                  900,
            ),
            curve:
                Curves.elasticOut,
            builder:
                (
              context,
              scale,
              child,
            ) {
              return Transform.scale(
                scale:
                    scale,
                child:
                    child,
              );
            },
            child:
                _buildFlowerStage(
              flowerId:
                  flowerId,
              stage:
                  3,
              height:
                  mainImageHeight * 1.04,
            ),
          ),
          title:
              '花が咲きました！',
          subtitle:
              'おめでとうございます',
          celebration:
              true,
        );

      case SignageViewState.complete:
        return _statusPanel(
          image: Image.asset(
            'assets/images/take.png',
            height: mainImageHeight * 0.72,
            fit: BoxFit.contain,
          ),
          title:
              'タグを抜いてください',
          subtitle:
              '処理は完了しました。安全に取り外せます',
        );
    }
  }

  Widget _statusPanel({
    required Widget image,
    required String title,
    required String subtitle,
    bool loading = false,
    bool celebration = false,
  }) {
    return Column(
      mainAxisSize:
          MainAxisSize.min,
      children: [
        image,

        const SizedBox(
          height:
              14,
        ),

        if (celebration)
          const Text(
            '✨  ✨  ✨',
            style:
                TextStyle(
              fontSize:
                  30,
            ),
          ),

        Text(
          title,
          textAlign:
              TextAlign.center,
          style:
              const TextStyle(
            fontSize:
                38,
            fontWeight:
                FontWeight.w800,
            color:
                Color(
              0xFF27462E,
            ),
          ),
        ),

        const SizedBox(
          height:
              8,
        ),

        Text(
          subtitle,
          textAlign:
              TextAlign.center,
          style:
              const TextStyle(
            fontSize:
                20,
            fontWeight:
                FontWeight.w500,
            color:
                Color(
              0xFF56705C,
            ),
          ),
        ),

        if (loading) ...[
          const SizedBox(
            height:
                24,
          ),
          const SizedBox(
            width:
                42,
            height:
                42,
            child:
                CircularProgressIndicator(
              strokeWidth:
                  5,
            ),
          ),
        ],
      ],
    );
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
        backgroundColor:
            Color(
          0xFFF4F7E8,
        ),
        body:
            Center(
          child:
              CircularProgressIndicator(),
        ),
      );
    }

    return Scaffold(
      backgroundColor:
          const Color(
        0xFFF4F7E8,
      ),
      body: SafeArea(
        child: LayoutBuilder(
          builder:
              (
            context,
            constraints,
          ) {
            final sunSize =
                (constraints.maxWidth *
                        0.10)
                    .clamp(
                      82.0,
                      150.0,
                    )
                    .toDouble();

            final flowerBedHeight =
                (constraints.maxHeight *
                        0.25)
                    .clamp(
                      150.0,
                      270.0,
                    )
                    .toDouble();

            return Stack(
              children: [
                // ------------------------------------------------
                // SUN
                // ------------------------------------------------

                Positioned(
                  top:
                      24,
                  right:
                      34,
                  child:
                      Image.asset(
                    'assets/images/sun.png',
                    width:
                        sunSize,
                    height:
                        sunSize,
                    fit:
                        BoxFit.contain,
                  ),
                ),

                // ------------------------------------------------
                // MAIN CONTENT
                // ------------------------------------------------

                Positioned.fill(
                  bottom:
                      flowerBedHeight * 0.72,
                  child:
                      Center(
                    child:
                        Padding(
                      padding:
                          const EdgeInsets.symmetric(
                        horizontal:
                            40,
                        vertical:
                            24,
                      ),
                      child:
                          AnimatedSwitcher(
                        duration:
                            const Duration(
                          milliseconds:
                              450,
                        ),
                        child:
                            KeyedSubtree(
                          key:
                              ValueKey(
                            signageViewState,
                          ),
                          child:
                              _buildMainSignageContent(
                            constraints.maxHeight,
                          ),
                        ),
                      ),
                    ),
                  ),
                ),

                // ------------------------------------------------
                // FLOWER BED
                // ------------------------------------------------

                Positioned(
                  left:
                      0,
                  right:
                      0,
                  bottom:
                      0,
                  height:
                      flowerBedHeight,
                  child:
                      IgnorePointer(
                    child:
                        Image.asset(
                      'assets/images/flower.png',
                      fit:
                          BoxFit.fitWidth,
                      alignment:
                          Alignment.bottomCenter,
                    ),
                  ),
                ),

                // ------------------------------------------------
                // MANUAL DEBUG BUTTON
                // ------------------------------------------------

                Positioned(
                  top:
                      18,
                  left:
                      18,
                  child:
                      Opacity(
                    opacity:
                        0.35,
                    child:
                        IconButton(
                      tooltip:
                          'タグフォルダを手動選択',
                      onPressed:
                          isLoading
                              ? null
                              : selectTagFolder,
                      icon:
                          const Icon(
                        Icons.folder_open,
                      ),
                    ),
                  ),
                ),

                // ------------------------------------------------
                // ERROR
                // ------------------------------------------------

                if (errorMessage !=
                    null)
                  Positioned(
                    left:
                        30,
                    right:
                        30,
                    bottom:
                        flowerBedHeight + 12,
                    child:
                        Container(
                      padding:
                          const EdgeInsets.all(
                        16,
                      ),
                      decoration:
                          BoxDecoration(
                        color:
                            const Color(
                          0xFFFFF1F0,
                        ),
                        borderRadius:
                            BorderRadius.circular(
                          18,
                        ),
                        border:
                            Border.all(
                          color:
                              const Color(
                            0xFFC95A50,
                          ),
                        ),
                      ),
                      child:
                          Text(
                        errorMessage!,
                        textAlign:
                            TextAlign.center,
                        style:
                            const TextStyle(
                          fontSize:
                              16,
                          fontWeight:
                              FontWeight.w600,
                          color:
                              Color(
                            0xFF7D2922,
                          ),
                        ),
                      ),
                    ),
                  ),
              ],
            );
          },
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