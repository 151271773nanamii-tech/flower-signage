import 'dart:async';
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

  // 7種類の表示順。DB/asset/configのflower_idもこの表記で統一する。
  static const List<String> flowerIds = [
    'tulip',
    'sunflower',
    'rose',
    'kernation',
    'suzuran',
    'ajisai',
    'cosmos',
  ];

  // 花ごとの開花Stage。
  static const Map<String, int> flowerMaxStages = {
    'tulip': 6,
    'sunflower': 6,
    'rose': 6,
    'kernation': 6,
    'suzuran': 6,
    'ajisai': 5,
    'cosmos': 4,
  };

  // DB上の現在育成中の花。
  Map<String, Map<String, Object?>> activeFlowersByType = {};

  // 結果画面に表示するStage。
  // 開花して次の花へStageが繰り越された場合も、今回の画面では開花Stageを保持する。
  Map<String, int> resultDisplayStages = {};

  // 今回その花に加算したStage数。
  Map<String, int> resultStageDeltas = {};

  // 花ごとの累計開花数。
  Map<String, int> bloomCounts = {};

  // 花ごとの未使用種数。
  Map<String, int> unusedSeedCounts = {};

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

  SignageViewState signageViewState =
      SignageViewState.waiting;

  int lastStageDelta = 0;

  Timer? _resultDisplayTimer;
  Timer? _returnToWaitingTimer;

  // ============================================================
  // USB
  // ============================================================

  UsbMonitorService? usbMonitor;

  String usbStatus =
      'BLEタグを接続してください';

  bool isAutoProcessing = false;

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

          _resultDisplayTimer?.cancel();
          _returnToWaitingTimer?.cancel();

          setState(() {
            signageViewState =
                SignageViewState.processing;

            usbStatus =
                'タグを抜かないでください';

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

          await SafeEjectService.eject(
            folderPath,
          );

          // 物理抜線は待たない。
          // 現在タグの監視状態を解除し、次に検出されたタグを
          // 新しい処理対象として受け付ける。
          usbMonitor?.completeSafeEject();

          if (!mounted) {
            return;
          }

          // Eject完了後に結果を表示する。
          // 結果表示中でも新しいタグを検出したら、
          // onTagConnected側でタイマーを止めてPROCESSINGへ移る。
          _showResultAfterSafeEject();
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
            'USB PHYSICALLY DISCONNECTED',
          );
        }

        if (!mounted) {
          return;
        }

        // ========================================================
        // Eject前に予期せずStorageが切断された場合の復帰処理。
        // 正常Eject後は物理抜線を追跡しない。
        // ========================================================

        _resultDisplayTimer?.cancel();
        _returnToWaitingTimer?.cancel();

        setState(() {
          signageViewState =
              SignageViewState.waiting;

          usbStatus =
              'タグを接続してください';

          processStatus =
              '待機中';

          errorMessage =
              null;

          tagResult =
              null;

          checkpointHits =
              [];

          interactionHits =
              [];

          seedInventory =
              [];

          activeFlowersByType = {};
          resultDisplayStages = {};
          resultStageDeltas = {};
          bloomCounts = {};
          unusedSeedCounts = {};

          newlyAddedSeeds.clear();
          alreadyOwnedSeeds.clear();

          alreadyImported =
              false;

          currentImportHash =
              null;

          deletedLogCount =
              0;

          lastStageDelta =
              0;

          isLoading =
              false;

        });
      },
    );

    usbMonitor!.start();
  }

  @override
  void dispose() {
    usbMonitor?.stop();
    _resultDisplayTimer?.cancel();
    _returnToWaitingTimer?.cancel();

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

      if (mounted) {
        _resultDisplayTimer?.cancel();
        _returnToWaitingTimer?.cancel();

        setState(() {
          signageViewState =
              SignageViewState.processing;

          usbStatus =
              'タグを抜かないでください';
        });
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

        activeFlowersByType = {};
        resultDisplayStages = {};
        resultStageDeltas = {};
        bloomCounts = {};
        unusedSeedCounts = {};

        newlyAddedSeeds.clear();
        alreadyOwnedSeeds.clear();

        alreadyImported = false;

        currentImportHash = null;

        deletedLogCount = 0;

        lastStageDelta = 0;

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

    // await DatabaseService.instance
    //     .ensureInitialSeeds(
    //   userId:
    //       result.userInfo.userId,

    //   initialSeeds:
    //       cfg.initialSeeds,
    // );

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
      final currentFlowers =
          await DatabaseService.instance.getActiveFlowersByType(
        result.userInfo.userId,
      );
      final currentBloomCounts =
          await DatabaseService.instance.getBloomCounts(
        result.userInfo.userId,
      );
      final currentUnusedSeedCounts =
          await DatabaseService.instance.getUnusedSeedCounts(
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

        activeFlowersByType = currentFlowers;
        resultDisplayStages = {
          for (final entry in currentFlowers.entries)
            entry.key: (entry.value['stage'] as num?)?.toInt() ?? 0,
        };
        resultStageDeltas = {};
        bloomCounts = currentBloomCounts;
        unusedSeedCounts = currentUnusedSeedCounts;

        checkpointHits = [];
        interactionHits = [];

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
          'Active flowers = $currentFlowers',
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

      final currentFlowers =
          await DatabaseService.instance.getActiveFlowersByType(
        result.userInfo.userId,
      );
      final currentBloomCounts =
          await DatabaseService.instance.getBloomCounts(
        result.userInfo.userId,
      );
      final currentUnusedSeedCounts =
          await DatabaseService.instance.getUnusedSeedCounts(
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

        activeFlowersByType = currentFlowers;
        resultDisplayStages = {
          for (final entry in currentFlowers.entries)
            entry.key: (entry.value['stage'] as num?)?.toInt() ?? 0,
        };
        resultStageDeltas = {};
        bloomCounts = currentBloomCounts;
        unusedSeedCounts = currentUnusedSeedCounts;

        checkpointHits = [];
        interactionHits = [];

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
      newLogFiles,
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

      final currentFlowers =
          await DatabaseService.instance.getActiveFlowersByType(
        result.userInfo.userId,
      );
      final currentBloomCounts =
          await DatabaseService.instance.getBloomCounts(
        result.userInfo.userId,
      );
      final currentUnusedSeedCounts =
          await DatabaseService.instance.getUnusedSeedCounts(
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

        activeFlowersByType = currentFlowers;
        resultDisplayStages = {
          for (final entry in currentFlowers.entries)
            entry.key: (entry.value['stage'] as num?)?.toInt() ?? 0,
        };
        resultStageDeltas = {};
        bloomCounts = currentBloomCounts;
        unusedSeedCounts = currentUnusedSeedCounts;

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

    lastStageDelta =
        GrowthService.calculateStage(
      value:
          growthValue,
      config:
          cfg,
    );

    final flowerResult =
        await _processFlowerGrowth(
      userId: result.userInfo.userId,
      growthValue: growthValue,
      importHash: importHash,
      checkpointHits: uniqueCheckpointHits,
      interactionHits: uniqueInteractions,
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

      activeFlowersByType = flowerResult.activeFlowers;
      resultDisplayStages = flowerResult.displayStages;
      resultStageDeltas = flowerResult.stageDeltas;
      bloomCounts = flowerResult.bloomCounts;
      unusedSeedCounts = flowerResult.unusedSeedCounts;

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

      debugPrint('Result display stages = $resultDisplayStages');
      debugPrint('Stage deltas = $resultStageDeltas');
      debugPrint('Bloom counts = $bloomCounts');
      debugPrint('Unused seed counts = $unusedSeedCounts');

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
  //
  // ・1回の接続で対象になった花をすべて独立して成長させる。
  // ・Checkpoint/交流が1件以上ある場合は、その結果に対応する花が対象。
  // ・Checkpoint/交流が0件の場合はcosmosが対象。
  // ・同じ接続で同じflower_idが複数回出ても成長加算は1回だけ。
  // ・開花してStageが余った場合は同種の次の種へ繰り越す。
  // ・結果画面は今回開花した画像を保持し、次の花は次回から表示する。
  // ============================================================

  Future<FlowerProcessResult> _processFlowerGrowth({
    required String userId,
    required int growthValue,
    required String importHash,
    required List<CheckpointHit> checkpointHits,
    required List<InteractionHit> interactionHits,
  }) async {
    if (config == null) {
      throw Exception('Configがありません。');
    }

    final stageDelta =
        GrowthService.calculateStage(
      value: growthValue,
      config: config!,
    );

    final targetFlowerIds =
        <String>{};

    for (final hit in checkpointHits) {
      final flowerId =
          hit.checkpoint.flower.trim();

      if (flowerMaxStages.containsKey(
        flowerId,
      )) {
        targetFlowerIds.add(
          flowerId,
        );
      }
    }

    for (final hit in interactionHits) {
      final flowerId =
          hit.user.flower.trim();

      if (flowerMaxStages.containsKey(
        flowerId,
      )) {
        targetFlowerIds.add(
          flowerId,
        );
      }
    }

    if (targetFlowerIds.isEmpty) {
      targetFlowerIds.add(
        'cosmos',
      );

      await DatabaseService.instance
          .addSeed(
        userId: userId,
        flowerId: 'cosmos',
        sourceType: 'activity',
        sourceId: 'cosmos:$importHash',
      );
    }

    final displayStages =
        <String, int>{};

    final stageDeltas =
        <String, int>{};

    final beforeActive =
        await DatabaseService.instance
            .getActiveFlowersByType(
      userId,
    );

    for (final entry
        in beforeActive.entries) {
      displayStages[entry.key] =
          (entry.value['stage']
                      as num?)
                  ?.toInt() ??
              0;
    }

    for (final flowerId
        in targetFlowerIds) {
      final maxStage =
          flowerMaxStages[flowerId]!;

      stageDeltas[flowerId] =
          stageDelta;

      var remainingStages =
          stageDelta;

      var remainingGrowthValue =
          growthValue;

      var current =
          await DatabaseService.instance
              .getActiveFlowerByType(
        userId: userId,
        flowerId: flowerId,
      );

      if (remainingStages <= 0) {
        displayStages[flowerId] =
            (current?['stage']
                        as num?)
                    ?.toInt() ??
                0;
        continue;
      }

      current ??=
          await DatabaseService.instance
              .activateNextSeedForFlower(
        userId: userId,
        flowerId: flowerId,
        initialStage: 0,
        initialGrowthValue: 0,
      );

      if (current == null) {
        displayStages.putIfAbsent(
          flowerId,
          () => 0,
        );
        continue;
      }

      bool bloomedThisConnection =
          false;

      final totalStageDelta =
          stageDelta;

      while (remainingStages > 0 &&
          current != null) {
        final userFlowerId =
            (current['id'] as num)
                .toInt();

        final currentStage =
            (current['stage']
                        as num?)
                    ?.toInt() ??
                0;

        final currentGrowthValue =
            (current['growth_value']
                        as num?)
                    ?.toInt() ??
                0;

        final stagesToBloom =
            maxStage -
                currentStage;

        if (stagesToBloom <= 0) {
          await DatabaseService.instance
              .markFlowerBloomed(
            userFlowerId:
                userFlowerId,
            growthValue:
                currentGrowthValue,
            maxStage:
                maxStage,
          );

          bloomedThisConnection =
              true;

          displayStages[flowerId] =
              maxStage;

          current =
              await DatabaseService.instance
                  .activateNextSeedForFlower(
            userId:
                userId,
            flowerId:
                flowerId,
            initialStage:
                0,
            initialGrowthValue:
                0,
          );

          if (current == null) {
            remainingStages = 0;
            remainingGrowthValue = 0;
          }

          continue;
        }

        final stagesAppliedToCurrent =
            remainingStages <
                    stagesToBloom
                ? remainingStages
                : stagesToBloom;

        final int growthAppliedToCurrent;

        if (stagesAppliedToCurrent ==
                remainingStages ||
            totalStageDelta <= 0) {
          growthAppliedToCurrent =
              remainingGrowthValue;
        } else {
          final proportional =
              (growthValue *
                      stagesAppliedToCurrent /
                      totalStageDelta)
                  .round();

          growthAppliedToCurrent =
              proportional
                  .clamp(
                    0,
                    remainingGrowthValue,
                  )
                  .toInt();
        }

        final newGrowthValue =
            currentGrowthValue +
                growthAppliedToCurrent;

        final newStage =
            currentStage +
                stagesAppliedToCurrent;

        remainingStages -=
            stagesAppliedToCurrent;

        remainingGrowthValue -=
            growthAppliedToCurrent;

        if (newStage < maxStage) {
          await DatabaseService.instance
              .updateFlowerGrowth(
            userFlowerId:
                userFlowerId,
            growthValue:
                newGrowthValue,
            stage:
                newStage,
          );

          if (!bloomedThisConnection) {
            displayStages[flowerId] =
                newStage;
          }

          if (remainingStages > 0) {
            current =
                await DatabaseService.instance
                    .getFlowerById(
              userFlowerId,
            );
          } else {
            current = null;
          }

          continue;
        }

        await DatabaseService.instance
            .markFlowerBloomed(
          userFlowerId:
              userFlowerId,
          growthValue:
              newGrowthValue,
          maxStage:
              maxStage,
        );

        bloomedThisConnection =
            true;

        displayStages[flowerId] =
            maxStage;

        if (remainingStages > 0) {
          current =
              await DatabaseService.instance
                  .activateNextSeedForFlower(
            userId:
                userId,
            flowerId:
                flowerId,
            initialStage:
                0,
            initialGrowthValue:
                0,
          );

          if (current == null) {
            remainingStages = 0;
            remainingGrowthValue = 0;
          }
        } else {
          current = null;
        }
      }
    }

    final activeFlowers =
        await DatabaseService.instance
            .getActiveFlowersByType(
      userId,
    );

    final currentBloomCounts =
        await DatabaseService.instance
            .getBloomCounts(
      userId,
    );

    final currentUnusedSeedCounts =
        await DatabaseService.instance
            .getUnusedSeedCounts(
      userId,
    );

    for (final entry
        in activeFlowers.entries) {
      displayStages.putIfAbsent(
        entry.key,
        () =>
            (entry.value['stage']
                        as num?)
                    ?.toInt() ??
                0,
      );
    }

    if (config!.debugLogging) {
      debugPrint(
        '================================',
      );
      debugPrint(
        '=== MULTI FLOWER GROWTH ===',
      );
      debugPrint(
        'Growth value = $growthValue',
      );
      debugPrint(
        'Stage delta = $stageDelta',
      );
      debugPrint(
        'Targets = $targetFlowerIds',
      );
      debugPrint(
        'Display stages = $displayStages',
      );
      debugPrint(
        'Active flowers = ${activeFlowers.keys.toList()}',
      );
      debugPrint(
        'Bloom counts = $currentBloomCounts',
      );
      debugPrint(
        'Unused seeds = $currentUnusedSeedCounts',
      );
      debugPrint(
        '================================',
      );
    }

    return FlowerProcessResult(
      activeFlowers:
          activeFlowers,
      displayStages:
          displayStages,
      stageDeltas:
          stageDeltas,
      bloomCounts:
          currentBloomCounts,
      unusedSeedCounts:
          currentUnusedSeedCounts,
    );
  }

  // ============================================================
  // SIGNAGE RESULT CONTROL
  // ============================================================

  void _showResultAfterSafeEject() {
    _resultDisplayTimer?.cancel();
    _returnToWaitingTimer?.cancel();

    if (!mounted) {
      return;
    }

    setState(() {
      usbStatus = '結果表示中';
      processStatus = '結果表示中';
      signageViewState = SignageViewState.growth;
    });

    // ----------------------------------------------------------
    // 1) 結果画面を30秒表示
    // ----------------------------------------------------------
    _resultDisplayTimer = Timer(
      const Duration(seconds: 30),
      () {
        if (!mounted) {
          return;
        }

        setState(() {
          signageViewState =
              SignageViewState.complete;

          usbStatus =
              '抜いても大丈夫です';

          processStatus =
              '取り外し可能';
        });

        // ------------------------------------------------------
        // 2) 「抜いても大丈夫です」を15秒表示
        // ------------------------------------------------------
        _returnToWaitingTimer?.cancel();

        _returnToWaitingTimer = Timer(
          const Duration(seconds: 15),
          () {
            if (!mounted) {
              return;
            }

            // UIだけ待機へ戻す。
            //
            // USB監視側の「同じタグを再処理しない」状態は
            // ここではリセットしない。
            // 次に新しいタグが検出されたときだけ処理を開始する。
            setState(() {
              signageViewState =
                  SignageViewState.waiting;

              usbStatus =
                  'BLEタグを接続してください';

              processStatus =
                  '待機中';

              errorMessage =
                  null;

              tagResult =
                  null;

              checkpointHits =
                  [];

              interactionHits =
                  [];

              seedInventory =
                  [];

              activeFlowersByType =
                  {};

              resultDisplayStages =
                  {};

              resultStageDeltas =
                  {};

              bloomCounts =
                  {};

              unusedSeedCounts =
                  {};

              newlyAddedSeeds.clear();
              alreadyOwnedSeeds.clear();

              alreadyImported =
                  false;

              currentImportHash =
                  null;

              deletedLogCount =
                  0;

              lastStageDelta =
                  0;

              isLoading =
                  false;
            });
          },
        );
      },
    );
  }

  // ============================================================
  // IMAGE HELPERS
  // ============================================================

  String _flowerStageAsset(String flowerId, int stage) {
    return 'assets/images/$flowerId/$flowerId$stage.png';
  }

  String _seedAsset(String flowerId) {
    // 既存の種画像名を継続利用。
    return 'assets/images/$flowerId/${flowerId}_seed.png';
  }

  int _displayStageFor(String flowerId) {
    return resultDisplayStages[flowerId] ??
        ((activeFlowersByType[flowerId]?['stage'] as num?)?.toInt() ?? 0);
  }

  // ============================================================
  // COMMON BACKGROUND
  // ============================================================

  Widget _buildWorldBackground() {
    return LayoutBuilder(
      builder:
          (
        context,
        constraints,
      ) {
        final width =
            constraints.maxWidth;

        final height =
            constraints.maxHeight;

        final isPortrait =
            height > width;

        final sunSize =
            (width *
                    (isPortrait
                        ? 0.16
                        : 0.085))
                .clamp(
                  85.0,
                  145.0,
                )
                .toDouble();

        return Stack(
          children: [
            // 空
            const Positioned.fill(
              child: ColoredBox(
                color:
                    Color(
                  0xFFB9E3F7,
                ),
              ),
            ),

            // 地面：常に画面下1/3
            Positioned(
              left:
                  0,
              right:
                  0,
              bottom:
                  0,
              height:
                  height /
                      3,
              child:
                  const ColoredBox(
                color:
                    Color(
                  0xFFE7D2AD,
                ),
              ),
            ),

            // 太陽
            Positioned(
              top:
                  height *
                      0.025,
              right:
                  width *
                      0.035,
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
          ],
        );
      },
    );
  }

  // ============================================================
  // WAITING / PROCESSING
  // ============================================================

  // Widget _buildEmptyPotsRow() {
  //   return LayoutBuilder(
  //     builder:
  //         (
  //       context,
  //       constraints,
  //     ) {
  //       return _buildResponsiveEmptyPotsRow(
  //         availableWidth:
  //             constraints.maxWidth,
  //         availableHeight:
  //             constraints.maxHeight,
  //       );
  //     },
  //   );
  // }

  Widget _buildSimpleState({
    required String handImage,
    required String message,
    required bool showProgress,
  }) {
    return LayoutBuilder(
      builder:
          (
        context,
        constraints,
      ) {
        final width =
            constraints.maxWidth;

        final height =
            constraints.maxHeight;

        final isPortrait =
            height > width;

        final imageHeight =
            (height *
                    (isPortrait
                        ? 0.16
                        : 0.17))
                .clamp(
                  90.0,
                  170.0,
                )
                .toDouble();

        final messageFontSize =
            (width *
                    (isPortrait
                        ? 0.060
                        : 0.028))
                .clamp(
                  30.0,
                  48.0,
                )
                .toDouble();

        return Stack(
          children: [
            Positioned(
              left:
                  width *
                      0.025,
              right:
                  width *
                      0.025,
              bottom:
                  height /
                          3 -
                      height *
                          0.018,
              child:
                  _buildResponsiveEmptyPotsRow(
                availableWidth:
                    width *
                        0.95,
                availableHeight:
                    height,
              ),
            ),

            Positioned.fill(
              child: Center(
                child:
                    Transform.translate(
                  offset:
                      Offset(
                    0,
                    -height *
                        (isPortrait
                            ? 0.10
                            : 0.045),
                  ),
                  child: Column(
                    mainAxisSize:
                        MainAxisSize.min,
                    children: [
                      Image.asset(
                        handImage,
                        height:
                            imageHeight,
                        fit:
                            BoxFit.contain,
                      ),

                      SizedBox(
                        height:
                            height *
                                0.018,
                      ),

                      Text(
                        message,
                        textAlign:
                            TextAlign.center,
                        style:
                            TextStyle(
                          fontSize:
                              messageFontSize,
                          fontWeight:
                              FontWeight.w900,
                          color:
                              const Color(
                            0xFF163B59,
                          ),
                        ),
                      ),

                      if (showProgress) ...[
                        SizedBox(
                          height:
                              height *
                                  0.022,
                        ),

                        SizedBox(
                          width:
                              (width *
                                      0.06)
                                  .clamp(
                                    34.0,
                                    50.0,
                                  )
                                  .toDouble(),
                          height:
                              (width *
                                      0.06)
                                  .clamp(
                                    34.0,
                                    50.0,
                                  )
                                  .toDouble(),
                          child:
                              const CircularProgressIndicator(
                            strokeWidth:
                                5,
                            color:
                                Color(
                              0xFF163B59,
                            ),
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
              ),
            ),
          ],
        );
      },
    );
  }

  // ============================================================
  // RESULT UI
  // ============================================================

  Widget _buildFlowerResultCell(
    String flowerId, {
    required double width,
    required double imageHeight,
    required double bloomFontSize,
    required double deltaFontSize,
  }) {
    final stage =
        _displayStageFor(
      flowerId,
    );

    final maxStage =
        flowerMaxStages[flowerId]!;

    final safeStage =
        stage
            .clamp(
              0,
              maxStage,
            )
            .toInt();

    final delta =
        resultStageDeltas[flowerId] ??
            0;

    final bloomCount =
        bloomCounts[flowerId] ??
            0;

    return SizedBox(
      width:
          width,
      child: Column(
        mainAxisSize:
            MainAxisSize.min,
        children: [
          // ----------------------------------------------------
          // 累計開花数
          // ----------------------------------------------------
          FittedBox(
            fit:
                BoxFit.scaleDown,
            child: Text(
              '開花 $bloomCount 本',
              textAlign:
                  TextAlign.center,
              style:
                  TextStyle(
                fontSize:
                    bloomFontSize,
                fontWeight:
                    FontWeight.w900,
                color:
                    const Color(
                  0xFF163B59,
                ),
              ),
            ),
          ),

          SizedBox(
            height:
                imageHeight *
                    0.015,
          ),

          // ----------------------------------------------------
          // 今回の成長Stage
          // ----------------------------------------------------
          Text(
            '+$delta',
            textAlign:
                TextAlign.center,
            style:
                TextStyle(
              fontSize:
                  deltaFontSize,
              fontWeight:
                  FontWeight.w900,
              color:
                  delta > 0
                      ? const Color(
                          0xFFC62828,
                        )
                      : const Color(
                          0xFF1565C0,
                        ),
            ),
          ),

          SizedBox(
            height:
                imageHeight *
                    0.02,
          ),

          // ----------------------------------------------------
          // 花画像
          //
          // すべてのStageで画像表示領域の高さを固定し、
          // bottomCenter基準で配置する。
          // これによりStage変更時も鉢底の位置を固定する。
          // ----------------------------------------------------
          SizedBox(
            width:
                width,
            height:
                imageHeight,
            child: Align(
              alignment:
                  Alignment.bottomCenter,
              child: Image.asset(
                _flowerStageAsset(
                  flowerId,
                  safeStage,
                ),
                width:
                    width,
                height:
                    imageHeight,
                fit:
                    BoxFit.contain,
                alignment:
                    Alignment.bottomCenter,
                errorBuilder:
                    (
                  context,
                  error,
                  stackTrace,
                ) {
                  return Align(
                    alignment:
                        Alignment.bottomCenter,
                    child: Text(
                      '$flowerId\n'
                      'Stage $safeStage',
                      textAlign:
                          TextAlign.center,
                      style:
                          TextStyle(
                        fontSize:
                            bloomFontSize *
                                0.8,
                        fontWeight:
                            FontWeight.w700,
                        color:
                            const Color(
                          0xFF163B59,
                        ),
                      ),
                    ),
                  );
                },
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildFlowerGarden() {
    return LayoutBuilder(
      builder:
          (
        context,
        constraints,
      ) {
        final width =
            constraints.maxWidth;

        final height =
            constraints.maxHeight;

        final isPortrait =
            height > width;

        // ======================================================
        // 横型 / 縦型で比率だけ切り替える。
        //
        // 固定pxではなく、利用可能領域の幅・高さから算出する。
        // ======================================================

        final horizontalPadding =
            width *
                (isPortrait
                    ? 0.035
                    : 0.025);

        final usableWidth =
            width -
                horizontalPadding *
                    2;

        final frontCellWidth =
            usableWidth /
                (isPortrait
                    ? 4.25
                    : 4.15);

        final backCellWidth =
            frontCellWidth *
                (isPortrait
                    ? 0.90
                    : 0.86);

        final frontImageHeight =
            height *
                (isPortrait
                    ? 0.31
                    : 0.38);

        final backImageHeight =
            height *
                (isPortrait
                    ? 0.27
                    : 0.33);

        final bloomFontSize =
            (width *
                    (isPortrait
                        ? 0.032
                        : 0.015))
                .clamp(
                  14.0,
                  22.0,
                )
                .toDouble();

        final deltaFontSize =
            (width *
                    (isPortrait
                        ? 0.041
                        : 0.020))
                .clamp(
                  20.0,
                  32.0,
                )
                .toDouble();

        final backTop =
            height *
                (isPortrait
                    ? 0.02
                    : 0.00);

        final frontBottom =
            height *
                (isPortrait
                    ? 0.015
                    : 0.00);

        // ======================================================
        // 千鳥配置
        //
        // 後列: tulip / rose / suzuran
        // 前列: sunflower / kernation / ajisai / cosmos
        //
        //     ●      ●      ●
        //   ●    ●      ●      ●
        // ======================================================

        return Stack(
          clipBehavior:
              Clip.none,
          children: [
            Positioned(
              left:
                  horizontalPadding +
                      usableWidth *
                          (isPortrait
                              ? 0.095
                              : 0.105),
              right:
                  horizontalPadding +
                      usableWidth *
                          (isPortrait
                              ? 0.095
                              : 0.105),
              top:
                  backTop,
              child: Row(
                mainAxisAlignment:
                    MainAxisAlignment
                        .spaceBetween,
                crossAxisAlignment:
                    CrossAxisAlignment
                        .end,
                children: [
                  _buildFlowerResultCell(
                    flowerIds[0],
                    width:
                        backCellWidth,
                    imageHeight:
                        backImageHeight,
                    bloomFontSize:
                        bloomFontSize,
                    deltaFontSize:
                        deltaFontSize,
                  ),
                  _buildFlowerResultCell(
                    flowerIds[2],
                    width:
                        backCellWidth,
                    imageHeight:
                        backImageHeight,
                    bloomFontSize:
                        bloomFontSize,
                    deltaFontSize:
                        deltaFontSize,
                  ),
                  _buildFlowerResultCell(
                    flowerIds[4],
                    width:
                        backCellWidth,
                    imageHeight:
                        backImageHeight,
                    bloomFontSize:
                        bloomFontSize,
                    deltaFontSize:
                        deltaFontSize,
                  ),
                ],
              ),
            ),

            Positioned(
              left:
                  horizontalPadding,
              right:
                  horizontalPadding,
              bottom:
                  frontBottom,
              child: Row(
                mainAxisAlignment:
                    MainAxisAlignment
                        .spaceBetween,
                crossAxisAlignment:
                    CrossAxisAlignment
                        .end,
                children: [
                  _buildFlowerResultCell(
                    flowerIds[1],
                    width:
                        frontCellWidth,
                    imageHeight:
                        frontImageHeight,
                    bloomFontSize:
                        bloomFontSize,
                    deltaFontSize:
                        deltaFontSize,
                  ),
                  _buildFlowerResultCell(
                    flowerIds[3],
                    width:
                        frontCellWidth,
                    imageHeight:
                        frontImageHeight,
                    bloomFontSize:
                        bloomFontSize,
                    deltaFontSize:
                        deltaFontSize,
                  ),
                  _buildFlowerResultCell(
                    flowerIds[5],
                    width:
                        frontCellWidth,
                    imageHeight:
                        frontImageHeight,
                    bloomFontSize:
                        bloomFontSize,
                    deltaFontSize:
                        deltaFontSize,
                  ),
                  _buildFlowerResultCell(
                    flowerIds[6],
                    width:
                        frontCellWidth,
                    imageHeight:
                        frontImageHeight,
                    bloomFontSize:
                        bloomFontSize,
                    deltaFontSize:
                        deltaFontSize,
                  ),
                ],
              ),
            ),
          ],
        );
      },
    );
  }

  Widget _buildSeedResultCell(
    String flowerId, {
    required double imageSize,
    required double fontSize,
  }) {
    final count =
        unusedSeedCounts[flowerId] ??
            0;

    return Expanded(
      child: Column(
        mainAxisSize:
            MainAxisSize.min,
        children: [
          Image.asset(
            _seedAsset(
              flowerId,
            ),
            width:
                imageSize,
            height:
                imageSize,
            fit:
                BoxFit.contain,
            errorBuilder:
                (
              context,
              error,
              stackTrace,
            ) {
              return SizedBox(
                width:
                    imageSize,
                height:
                    imageSize,
              );
            },
          ),

          SizedBox(
            height:
                imageSize *
                    0.08,
          ),

          Text(
            '×$count',
            style:
                TextStyle(
              fontSize:
                  fontSize,
              fontWeight:
                  FontWeight.w900,
              color:
                  const Color(
                0xFF5D4633,
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildResultScreen() {
    return LayoutBuilder(
      builder:
          (
        context,
        constraints,
      ) {
        final width =
            constraints.maxWidth;

        final height =
            constraints.maxHeight;

        final isPortrait =
            height > width;

        final horizontalPadding =
            width *
                (isPortrait
                    ? 0.035
                    : 0.022);

        final topPadding =
            height *
                (isPortrait
                    ? 0.045
                    : 0.035);

        final bottomPadding =
            height *
                0.015;

        final seedImageSize =
            (width *
                    (isPortrait
                        ? 0.080
                        : 0.038))
                .clamp(
                  32.0,
                  62.0,
                )
                .toDouble();

        final seedFontSize =
            (width *
                    (isPortrait
                        ? 0.035
                        : 0.016))
                .clamp(
                  16.0,
                  24.0,
                )
                .toDouble();

        final seedTitleFontSize =
            (width *
                    (isPortrait
                        ? 0.036
                        : 0.017))
                .clamp(
                  18.0,
                  25.0,
                )
                .toDouble();

        // 縦型では花壇を大きく取り、
        // 種エリアは下部へまとめる。
        final gardenFlex =
            isPortrait
                ? 8
                : 7;

        final seedFlex =
            isPortrait
                ? 2
                : 2;

        return Padding(
          padding:
              EdgeInsets.fromLTRB(
            horizontalPadding,
            topPadding,
            horizontalPadding,
            bottomPadding,
          ),
          child: Column(
            children: [
              Expanded(
                flex:
                    gardenFlex,
                child:
                    _buildFlowerGarden(),
              ),

              SizedBox(
                height:
                    height *
                        0.010,
              ),

              Expanded(
                flex:
                    seedFlex,
                child: Column(
                  mainAxisAlignment:
                      MainAxisAlignment.center,
                  children: [
                    Text(
                      '持っている種（未使用）',
                      style:
                          TextStyle(
                        fontSize:
                            seedTitleFontSize,
                        fontWeight:
                            FontWeight.w900,
                        color:
                            const Color(
                          0xFF5D4633,
                        ),
                      ),
                    ),

                    SizedBox(
                      height:
                          height *
                              0.008,
                    ),

                    Row(
                      children: [
                        for (final flowerId
                            in flowerIds)
                          _buildSeedResultCell(
                            flowerId,
                            imageSize:
                                seedImageSize,
                            fontSize:
                                seedFontSize,
                          ),
                      ],
                    ),
                  ],
                ),
              ),
            ],
          ),
        );
      },
    );
  }

  // ============================================================
  // TAKE / WAITING MESSAGE
  // ============================================================

  Widget _buildTakeState({
    required String message,
  }) {
    return LayoutBuilder(
      builder:
          (
        context,
        constraints,
      ) {
        final width =
            constraints.maxWidth;

        final height =
            constraints.maxHeight;

        final isPortrait =
            height > width;

        final handHeight =
            (height *
                    (isPortrait
                        ? 0.16
                        : 0.17))
                .clamp(
                  90.0,
                  170.0,
                )
                .toDouble();

        final messageFontSize =
            (width *
                    (isPortrait
                        ? 0.060
                        : 0.028))
                .clamp(
                  30.0,
                  48.0,
                )
                .toDouble();

        return Stack(
          children: [
            // --------------------------------------------------
            // 7個のStage0鉢
            // 地面上端を基準に配置するため、
            // 縦横比が変わっても鉢位置が大きく崩れない。
            // --------------------------------------------------
            Positioned(
              left:
                  width *
                      0.025,
              right:
                  width *
                      0.025,
              bottom:
                  height /
                          3 -
                      height *
                          0.018,
              child:
                  _buildResponsiveEmptyPotsRow(
                availableWidth:
                    width *
                        0.95,
                availableHeight:
                    height,
              ),
            ),

            // --------------------------------------------------
            // TAKE / message
            // --------------------------------------------------
            Positioned.fill(
              child: Center(
                child:
                    Transform.translate(
                  offset:
                      Offset(
                    0,
                    -height *
                        (isPortrait
                            ? 0.10
                            : 0.045),
                  ),
                  child: Column(
                    mainAxisSize:
                        MainAxisSize.min,
                    children: [
                      Image.asset(
                        'assets/images/take.png',
                        height:
                            handHeight,
                        fit:
                            BoxFit.contain,
                      ),

                      SizedBox(
                        height:
                            height *
                                0.018,
                      ),

                      Text(
                        message,
                        textAlign:
                            TextAlign.center,
                        style:
                            TextStyle(
                          fontSize:
                              messageFontSize,
                          fontWeight:
                              FontWeight.w900,
                          color:
                              const Color(
                            0xFF163B59,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ],
        );
      },
    );
  }

  Widget _buildResponsiveEmptyPotsRow({
    required double availableWidth,
    required double availableHeight,
  }) {
    final isPortrait =
        availableHeight >
            availableWidth;

    final potHeight =
        (availableHeight *
                (isPortrait
                    ? 0.095
                    : 0.15))
            .clamp(
              65.0,
              150.0,
            )
            .toDouble();

    return Row(
      crossAxisAlignment:
          CrossAxisAlignment.end,
      children: [
        for (final flowerId
            in flowerIds)
          Expanded(
            child: SizedBox(
              height:
                  potHeight,
              child: Align(
                alignment:
                    Alignment.bottomCenter,
                child: Image.asset(
                  _flowerStageAsset(
                    flowerId,
                    0,
                  ),
                  height:
                      potHeight,
                  fit:
                      BoxFit.contain,
                  alignment:
                      Alignment.bottomCenter,
                  errorBuilder:
                      (
                    context,
                    error,
                    stackTrace,
                  ) {
                    return SizedBox(
                      height:
                          potHeight,
                    );
                  },
                ),
              ),
            ),
          ),
      ],
    );
  }

  // ============================================================
  // MAIN SIGNAGE CONTENT
  // ============================================================

  Widget _buildMainSignageContent() {
    switch (signageViewState) {
      case SignageViewState.waiting:
        return _buildTakeState(
          message:
              '接続してください',
        );

      case SignageViewState.processing:
        return Center(
          child: _buildSimpleState(
            handImage:
                'assets/images/no_take.png',
            message:
                '抜かないでください',
            showProgress:
                true,
          ),
        );

      case SignageViewState.growth:
      case SignageViewState.bloom:
        return _buildResultScreen();

      case SignageViewState.complete:
        return _buildTakeState(
          message:
              '抜いても大丈夫です',
        );
    }
  }

  // ============================================================
  // UI
  // ============================================================

  @override
  Widget build(BuildContext context) {
    if (config == null && errorMessage == null) {
      return const Scaffold(
        backgroundColor: Color(0xFFB9E3F7),
        body: Center(child: CircularProgressIndicator()),
      );
    }

    return Scaffold(
      backgroundColor: const Color(0xFFB9E3F7),
      body: SafeArea(
        child: Stack(
          children: [
            _buildWorldBackground(),
            Positioned.fill(
              child: _buildMainSignageContent(),
            ),
            if (errorMessage != null)
              Positioned(
                left: 30,
                right: 30,
                bottom: 30,
                child: Container(
                  padding: const EdgeInsets.all(16),
                  decoration: BoxDecoration(
                    color: Colors.white.withValues(alpha: 0.94),
                    borderRadius: BorderRadius.circular(18),
                  ),
                  child: Text(
                    errorMessage!,
                    textAlign: TextAlign.center,
                    style: const TextStyle(
                      fontSize: 18,
                      color: Colors.redAccent,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

// ================================================================
// Flower process result
// ================================================================

class FlowerProcessResult {
  final Map<String, Map<String, Object?>> activeFlowers;
  final Map<String, int> displayStages;
  final Map<String, int> stageDeltas;
  final Map<String, int> bloomCounts;
  final Map<String, int> unusedSeedCounts;

  const FlowerProcessResult({
    required this.activeFlowers,
    required this.displayStages,
    required this.stageDeltas,
    required this.bloomCounts,
    required this.unusedSeedCounts,
  });
}
