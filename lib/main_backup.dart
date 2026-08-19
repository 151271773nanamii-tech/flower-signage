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

void main() {
  runApp(const FlowerSignageApp());
}

class FlowerSignageApp extends StatelessWidget {
  const FlowerSignageApp({super.key});

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
  const TagFolderScreen({super.key});

  @override
  State<TagFolderScreen> createState() => _TagFolderScreenState();
}

class _TagFolderScreenState extends State<TagFolderScreen> {
  // ============================================================
  // Config / Data
  // ============================================================

  AppConfig? config;
  TagFolderResult? tagResult;

  List<Checkpoint> checkpoints = [];
  List<CheckpointHit> checkpointHits = [];

  List<RegisteredUser> registeredUsers = [];
  List<InteractionHit> interactionHits = [];

  List<Map<String, Object?>> seedInventory = [];

  final List<String> newlyAddedSeeds = [];
  final List<String> alreadyOwnedSeeds = [];

  String? selectedFolder;
  String? errorMessage;
  String? currentImportHash;

  bool isLoading = false;
  bool alreadyImported = false;

  // ============================================================
  // USB
  // ============================================================

  UsbMonitorService? usbMonitor;

  String usbStatus = 'BLEタグを接続してください';

  bool isAutoProcessing = false;

  // ============================================================
  // Initialize
  // ============================================================

  @override
  void initState() {
    super.initState();

    _initialize();
  }

  Future<void> _initialize() async {
    try {
      debugPrint('=== INITIALIZE START ===');

      // ----------------------------------------------------------
      // Database
      // ----------------------------------------------------------

      final dbOk =
          await DatabaseService.instance.testConnection();

      if (!dbOk) {
        throw Exception(
          'SQLiteデータベースを初期化できませんでした。',
        );
      }

      debugPrint('Database OK');

      // ----------------------------------------------------------
      // Config
      // ----------------------------------------------------------

      final loadedConfig =
          await ConfigService.loadConfig();

      debugPrint('Config OK');

      // ----------------------------------------------------------
      // Checkpoints
      // ----------------------------------------------------------

      final loadedCheckpoints =
          await CheckpointService.loadCheckpoints();

      debugPrint(
        'Checkpoints: ${loadedCheckpoints.length}',
      );

      // ----------------------------------------------------------
      // Users
      // ----------------------------------------------------------

      final loadedUsers =
          await InteractionService.loadUsers();

      debugPrint(
        'Registered users: ${loadedUsers.length}',
      );

      if (!mounted) {
        return;
      }

      setState(() {
        config = loadedConfig;
        checkpoints = loadedCheckpoints;
        registeredUsers = loadedUsers;
      });

      // ----------------------------------------------------------
      // USB monitor
      // ----------------------------------------------------------

      _startUsbMonitor();

      debugPrint('=== INITIALIZE COMPLETE ===');
    } catch (e, stackTrace) {
      debugPrint(
        '=== INITIALIZE ERROR ===',
      );

      debugPrint('$e');
      debugPrint('$stackTrace');

      if (!mounted) {
        return;
      }

      setState(() {
        errorMessage =
            '初期設定の読み込みに失敗しました。\n\n$e';
      });
    }
  }

  // ============================================================
  // USB Monitor
  // ============================================================

  void _startUsbMonitor() {
    debugPrint(
      '=== START USB MONITOR ===',
    );

    usbMonitor?.stop();

    usbMonitor = UsbMonitorService(
      // ========================================================
      // USB connected
      // ========================================================

      onTagConnected: (folderPath) async {
        debugPrint('');
        debugPrint(
          '==============================',
        );
        debugPrint(
          '=== USB TAG CONNECTED ===',
        );
        debugPrint(
          'folderPath = $folderPath',
        );
        debugPrint(
          '==============================',
        );

        if (isAutoProcessing) {
          debugPrint(
            'Auto processing already running -> skip',
          );

          return;
        }

        isAutoProcessing = true;

        try {
          if (!mounted) {
            debugPrint(
              'Widget is not mounted.',
            );

            return;
          }

          setState(() {
            usbStatus =
                'BLEタグを検出しました\n'
                'データを読み込んでいます...';

            errorMessage = null;
          });

          debugPrint(
            '>>> BEFORE _processTagFolder',
          );

          // ====================================================
          // ★ USB自動読み込み
          // ====================================================

          await _processTagFolder(
            folderPath,
          );

          debugPrint(
            '>>> AFTER _processTagFolder',
          );

          if (!mounted) {
            return;
          }

          setState(() {
            if (alreadyImported) {
              usbStatus =
                  'このタグのデータは処理済みです';
            } else {
              usbStatus =
                  'データの読み込みが完了しました';
            }
          });

          debugPrint(
            '=== AUTO IMPORT COMPLETE ===',
          );
        } catch (e, stackTrace) {
          debugPrint(
            '=== AUTO IMPORT ERROR ===',
          );

          debugPrint(
            'ERROR: $e',
          );

          debugPrint(
            '$stackTrace',
          );

          if (!mounted) {
            return;
          }

          setState(() {
            usbStatus =
                'タグの読み込みに失敗しました';

            errorMessage =
                'USB自動読込エラー\n\n$e';

            isLoading = false;
          });
        } finally {
          isAutoProcessing = false;

          debugPrint(
            '=== AUTO PROCESS END ===',
          );
        }
      },

      // ========================================================
      // USB disconnected
      // ========================================================

      onTagDisconnected: () {
        debugPrint('');
        debugPrint(
          '=== USB TAG DISCONNECTED ===',
        );

        if (!mounted) {
          return;
        }

        setState(() {
          usbStatus =
              'BLEタグを接続してください';
        });
      },
    );

    usbMonitor!.start();
  }

  // ============================================================
  // Dispose
  // ============================================================

  @override
  void dispose() {
    usbMonitor?.stop();

    super.dispose();
  }

  // ============================================================
  // Manual Folder Selection
  // ============================================================

  Future<void> selectTagFolder() async {
    try {
      final folderPath =
          await FilePicker.getDirectoryPath();

      if (folderPath == null) {
        return;
      }

      debugPrint(
        'MANUAL FOLDER: $folderPath',
      );

      await _processTagFolder(
        folderPath,
      );
    } catch (e, stackTrace) {
      debugPrint(
        'MANUAL IMPORT ERROR: $e',
      );

      debugPrint(
        '$stackTrace',
      );

      if (!mounted) {
        return;
      }

      setState(() {
        errorMessage = e.toString();
        isLoading = false;
      });
    }
  }

  // ============================================================
  // Process Tag Folder
  // ============================================================

  Future<void> _processTagFolder(
    String folderPath,
  ) async {
    debugPrint('');
    debugPrint(
      '=== PROCESS TAG FOLDER START ===',
    );

    debugPrint(
      'Path: $folderPath',
    );

    if (config == null) {
      throw Exception(
        '設定ファイルがまだ読み込まれていません。',
      );
    }

    if (mounted) {
      setState(() {
        isLoading = true;

        errorMessage = null;

        tagResult = null;

        checkpointHits = [];
        interactionHits = [];

        seedInventory = [];

        newlyAddedSeeds.clear();
        alreadyOwnedSeeds.clear();

        alreadyImported = false;
        currentImportHash = null;
      });
    }

    // ==========================================================
    // 1. Tag folder
    // ==========================================================

    debugPrint(
      '[1] Loading tag folder...',
    );

    final result =
        await TagFolderService.loadFolder(
      folderPath,
    );

    debugPrint(
      '[1] Tag folder loaded',
    );

    debugPrint(
      'User ID = ${result.userInfo.userId}',
    );

    debugPrint(
      'Tag MAC = ${result.userInfo.macAddress}',
    );

    debugPrint(
      'LOG files = ${result.logFiles.length}',
    );

    debugPrint(
      'Records = ${result.totalRecordCount}',
    );

    debugPrint(
      'Unique MAC = ${result.uniqueAddresses.length}',
    );

    // ==========================================================
    // 2. Import hash
    // ==========================================================

    debugPrint(
      '[2] Creating import hash...',
    );

    final importHash =
        await ImportService.createImportHash(
      result.logFiles,
    );

    debugPrint(
      '[2] Import hash created',
    );

    debugPrint(
      'Hash = $importHash',
    );

    // ==========================================================
    // 3. Already processed?
    // ==========================================================

    debugPrint(
      '[3] Checking import history...',
    );

    final processed =
        await DatabaseService.instance
            .isImportProcessed(
      importHash,
    );

    debugPrint(
      '[3] processed = $processed',
    );

    // ==========================================================
    // Already processed
    // ==========================================================

    if (processed) {
      debugPrint(
        'This LOG has already been processed.',
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
        selectedFolder = folderPath;

        tagResult = result;

        seedInventory = seeds;

        alreadyImported = true;

        currentImportHash =
            importHash;

        isLoading = false;
      });

      debugPrint(
        '=== PROCESS COMPLETE (ALREADY IMPORTED) ===',
      );

      return;
    }

    // ==========================================================
    // 4. All records
    // ==========================================================

    debugPrint(
      '[4] Combining records...',
    );

    final allRecords =
        result.logResults
            .expand(
              (logResult) =>
                  logResult.records,
            )
            .toList();

    debugPrint(
      '[4] Combined records = ${allRecords.length}',
    );

    // ==========================================================
    // 5. Checkpoint detection
    // ==========================================================

    debugPrint(
      '[5] Detecting checkpoints...',
    );

    final hits =
        CheckpointService.detect(
      records: allRecords,
      checkpoints: checkpoints,
      scanGroupSeconds:
          config!.scanGroupSeconds,
    );

    debugPrint(
      '[5] Checkpoint hits = ${hits.length}',
    );

    // ==========================================================
    // 6. Interaction detection
    // ==========================================================

    debugPrint(
      '[6] Detecting interactions...',
    );

    final interactions =
        InteractionService.detect(
      detectedAddresses:
          result.uniqueAddresses,

      users:
          registeredUsers,

      ownTagMac:
          result.userInfo.macAddress,
    );

    debugPrint(
      '[6] Interaction hits = ${interactions.length}',
    );

    // ==========================================================
    // 7. Database
    // ==========================================================

    debugPrint(
      '[7] Saving database...',
    );

    await _saveToDatabase(
      result: result,
      checkpointHits: hits,
      interactionHits: interactions,
    );

    debugPrint(
      '[7] Database save complete',
    );

    // ==========================================================
    // 8. Import history
    // ==========================================================

    debugPrint(
      '[8] Saving import history...',
    );

    await DatabaseService.instance
        .addImportHistory(
      userId:
          result.userInfo.userId,

      importHash:
          importHash,

      growthMetric:
          config!.growthMetric,

      growthValue:
          _calculateGrowthValue(
        result,
      ),

      recordCount:
          result.totalRecordCount,

      uniqueAddressCount:
          result.uniqueAddresses.length,

      status:
          'completed',
    );

    debugPrint(
      '[8] Import history saved',
    );

    // ==========================================================
    // 9. Seed inventory
    // ==========================================================

    debugPrint(
      '[9] Loading seed inventory...',
    );

    final seeds =
        await DatabaseService.instance
            .getSeeds(
      result.userInfo.userId,
    );

    debugPrint(
      '[9] Seed count = ${seeds.length}',
    );

    // ==========================================================
    // 10. UI
    // ==========================================================

    if (!mounted) {
      return;
    }

    setState(() {
      selectedFolder =
          folderPath;

      tagResult =
          result;

      checkpointHits =
          hits;

      interactionHits =
          interactions;

      seedInventory =
          seeds;

      alreadyImported =
          false;

      currentImportHash =
          importHash;

      isLoading =
          false;
    });

    debugPrint(
      '=== PROCESS TAG FOLDER COMPLETE ===',
    );
  }

  // ============================================================
  // Save Database
  // ============================================================

  Future<void> _saveToDatabase({
    required TagFolderResult result,
    required List<CheckpointHit> checkpointHits,
    required List<InteractionHit> interactionHits,
  }) async {
    final userId =
        result.userInfo.userId;

    final tagMac =
        result.userInfo.macAddress;

    // ==========================================================
    // User
    // ==========================================================

    await DatabaseService.instance
        .upsertUser(
      userId: userId,
      tagMac: tagMac,
    );

    // ==========================================================
    // Checkpoint Seeds
    // ==========================================================

    for (final hit in checkpointHits) {
      final flower =
          hit.checkpoint.flower;

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
            hit.checkpoint.id,
      );

      if (added) {
        newlyAddedSeeds.add(
          '$flower（${hit.checkpoint.name}）',
        );
      } else {
        alreadyOwnedSeeds.add(
          '$flower（${hit.checkpoint.name}）',
        );
      }
    }

    // ==========================================================
    // Interaction Seeds
    // ==========================================================

    for (final hit in interactionHits) {
      final flower =
          hit.user.flower;

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
            hit.user.userId,
      );

      if (added) {
        newlyAddedSeeds.add(
          '$flower（${hit.user.name}との交流）',
        );
      } else {
        alreadyOwnedSeeds.add(
          '$flower（${hit.user.name}との交流）',
        );
      }
    }
  }

  // ============================================================
  // Growth Value
  // ============================================================

  int _calculateGrowthValue(
    TagFolderResult result,
  ) {
    if (config?.growthMetric ==
        'detection_count') {
      return result.totalRecordCount;
    }

    return result.uniqueAddresses.length;
  }

  int get growthValue {
    if (tagResult == null) {
      return 0;
    }

    return _calculateGrowthValue(
      tagResult!,
    );
  }

  // ============================================================
  // Stage
  // ============================================================

  int get currentStage {
    if (config == null) {
      return 1;
    }

    return GrowthService.calculateStage(
      value: growthValue,
      config: config!,
    );
  }

  // ============================================================
  // Flower
  // ============================================================

  String get flowerEmoji {
    switch (currentStage) {
      case 1:
        return '🌱';

      case 2:
        return '🌿';

      case 3:
        return '🌻';

      default:
        return '🌱';
    }
  }

  String get stageMessage {
    switch (currentStage) {
      case 1:
        return '芽が出ました';

      case 2:
        return '花が成長しています';

      case 3:
        return '花が咲きました！';

      default:
        return '';
    }
  }

  // ============================================================
  // UI
  // ============================================================

  @override
  Widget build(BuildContext context) {
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
              const EdgeInsets.all(32),
          child: Center(
            child: ConstrainedBox(
              constraints:
                  const BoxConstraints(
                maxWidth: 850,
              ),
              child: Column(
                children: [
                  const SizedBox(
                    height: 20,
                  ),

                  // =================================================
                  // Title
                  // =================================================

                  const Text(
                    'BLEタグ 花育成システム',
                    textAlign:
                        TextAlign.center,
                    style: TextStyle(
                      fontSize: 38,
                      fontWeight:
                          FontWeight.bold,
                    ),
                  ),

                  const SizedBox(
                    height: 20,
                  ),

                  // =================================================
                  // USB Status
                  // =================================================

                  Container(
                    width:
                        double.infinity,
                    padding:
                        const EdgeInsets.all(
                      20,
                    ),
                    decoration:
                        BoxDecoration(
                      border:
                          Border.all(),
                      borderRadius:
                          BorderRadius.circular(
                        16,
                      ),
                    ),
                    child: Column(
                      children: [
                        const Text(
                          'USB接続状態',
                          style:
                              TextStyle(
                            fontSize: 20,
                            fontWeight:
                                FontWeight.bold,
                          ),
                        ),

                        const SizedBox(
                          height: 10,
                        ),

                        Text(
                          usbStatus,
                          textAlign:
                              TextAlign.center,
                          style:
                              const TextStyle(
                            fontSize: 22,
                            fontWeight:
                                FontWeight.bold,
                          ),
                        ),
                      ],
                    ),
                  ),

                  const SizedBox(
                    height: 25,
                  ),

                  // =================================================
                  // Manual button
                  // =================================================

                  ElevatedButton(
                    onPressed:
                        isLoading
                            ? null
                            : selectTagFolder,
                    style:
                        ElevatedButton.styleFrom(
                      padding:
                          const EdgeInsets.symmetric(
                        horizontal: 40,
                        vertical: 20,
                      ),
                    ),
                    child:
                        const Text(
                      'タグのフォルダを手動選択',
                      style:
                          TextStyle(
                        fontSize: 21,
                      ),
                    ),
                  ),

                  // =================================================
                  // Loading
                  // =================================================

                  if (isLoading) ...[
                    const SizedBox(
                      height: 30,
                    ),

                    const CircularProgressIndicator(),

                    const SizedBox(
                      height: 15,
                    ),

                    const Text(
                      'タグのデータを読み込んでいます...',
                      style:
                          TextStyle(
                        fontSize: 20,
                      ),
                    ),
                  ],

                  // =================================================
                  // Error
                  // =================================================

                  if (errorMessage != null) ...[
                    const SizedBox(
                      height: 25,
                    ),

                    Container(
                      width:
                          double.infinity,
                      padding:
                          const EdgeInsets.all(
                        20,
                      ),
                      decoration:
                          BoxDecoration(
                        border:
                            Border.all(),
                        borderRadius:
                            BorderRadius.circular(
                          16,
                        ),
                      ),
                      child:
                          Column(
                        children: [
                          const Text(
                            'エラー',
                            style:
                                TextStyle(
                              fontSize: 25,
                              fontWeight:
                                  FontWeight.bold,
                            ),
                          ),

                          const SizedBox(
                            height: 10,
                          ),

                          Text(
                            errorMessage!,
                            textAlign:
                                TextAlign.center,
                          ),
                        ],
                      ),
                    ),
                  ],

                  // =================================================
                  // Result
                  // =================================================

                  if (tagResult != null) ...[
                    const SizedBox(
                      height: 30,
                    ),

                    if (alreadyImported) ...[
                      Container(
                        width:
                            double.infinity,
                        padding:
                            const EdgeInsets.all(
                          20,
                        ),
                        decoration:
                            BoxDecoration(
                          border:
                              Border.all(),
                          borderRadius:
                              BorderRadius.circular(
                            16,
                          ),
                        ),
                        child:
                            const Text(
                          '✓ このデータは処理済みです\n'
                          '花や種の追加は行いません。',
                          textAlign:
                              TextAlign.center,
                          style:
                              TextStyle(
                            fontSize: 20,
                            fontWeight:
                                FontWeight.bold,
                          ),
                        ),
                      ),

                      const SizedBox(
                        height: 25,
                      ),
                    ],

                    const Divider(),

                    const SizedBox(
                      height: 25,
                    ),

                    // =================================================
                    // User
                    // =================================================

                    const Text(
                      'ユーザ情報',
                      style:
                          TextStyle(
                        fontSize: 27,
                        fontWeight:
                            FontWeight.bold,
                      ),
                    ),

                    const SizedBox(
                      height: 15,
                    ),

                    Text(
                      'User ID：'
                      '${tagResult!.userInfo.userId}',
                      style:
                          const TextStyle(
                        fontSize: 24,
                        fontWeight:
                            FontWeight.bold,
                      ),
                    ),

                    const SizedBox(
                      height: 5,
                    ),

                    Text(
                      'Tag MAC：'
                      '${tagResult!.userInfo.macAddress}',
                      style:
                          const TextStyle(
                        fontSize: 19,
                      ),
                    ),

                    const SizedBox(
                      height: 30,
                    ),

                    // =================================================
                    // Flower
                    // =================================================

                    AnimatedSwitcher(
                      duration:
                          const Duration(
                        milliseconds: 700,
                      ),
                      child:
                          Text(
                        flowerEmoji,
                        key:
                            ValueKey(
                          currentStage,
                        ),
                        style:
                            const TextStyle(
                          fontSize: 150,
                        ),
                      ),
                    ),

                    Text(
                      'Stage $currentStage / 3',
                      style:
                          const TextStyle(
                        fontSize: 32,
                        fontWeight:
                            FontWeight.bold,
                      ),
                    ),

                    const SizedBox(
                      height: 8,
                    ),

                    Text(
                      stageMessage,
                      style:
                          const TextStyle(
                        fontSize: 24,
                      ),
                    ),

                    const SizedBox(
                      height: 25,
                    ),

                    Text(
                      'BLE情報量：$growthValue',
                      style:
                          const TextStyle(
                        fontSize: 25,
                        fontWeight:
                            FontWeight.bold,
                      ),
                    ),

                    const SizedBox(
                      height: 5,
                    ),

                    Text(
                      'ユニークMAC数：'
                      '${tagResult!.uniqueAddresses.length}',
                      style:
                          const TextStyle(
                        fontSize: 19,
                      ),
                    ),

                    const SizedBox(
                      height: 30,
                    ),

                    // =================================================
                    // Checkpoints
                    // =================================================

                    const Divider(),

                    const SizedBox(
                      height: 20,
                    ),

                    const Text(
                      'チェックポイント',
                      style:
                          TextStyle(
                        fontSize: 27,
                        fontWeight:
                            FontWeight.bold,
                      ),
                    ),

                    const SizedBox(
                      height: 15,
                    ),

                    if (checkpointHits.isEmpty)
                      const Text(
                        'チェックポイントは検出されませんでした',
                        style:
                            TextStyle(
                          fontSize: 18,
                        ),
                      ),

                    ...checkpointHits.map(
                      (hit) =>
                          Padding(
                        padding:
                            const EdgeInsets.only(
                          bottom: 12,
                        ),
                        child:
                            Text(
                          '📍 ${hit.checkpoint.name}\n'
                          '検出 ${hit.detectedCount}/${hit.totalAddressCount}'
                          ' (${(hit.detectedRatio * 100).toStringAsFixed(0)}%)\n'
                          '🌱 ${hit.checkpoint.flower} の種',
                          textAlign:
                              TextAlign.center,
                          style:
                              const TextStyle(
                            fontSize: 20,
                          ),
                        ),
                      ),
                    ),

                    const SizedBox(
                      height: 25,
                    ),

                    // =================================================
                    // Interaction
                    // =================================================

                    const Divider(),

                    const SizedBox(
                      height: 20,
                    ),

                    const Text(
                      '交流',
                      style:
                          TextStyle(
                        fontSize: 27,
                        fontWeight:
                            FontWeight.bold,
                      ),
                    ),

                    const SizedBox(
                      height: 15,
                    ),

                    if (interactionHits.isEmpty)
                      const Text(
                        '交流は検出されませんでした',
                        style:
                            TextStyle(
                          fontSize: 18,
                        ),
                      ),

                    ...interactionHits.map(
                      (hit) =>
                          Padding(
                        padding:
                            const EdgeInsets.only(
                          bottom: 10,
                        ),
                        child:
                            Text(
                          '🤝 ${hit.user.name}\n'
                          '🌱 ${hit.user.flower} の種',
                          textAlign:
                              TextAlign.center,
                          style:
                              const TextStyle(
                            fontSize: 20,
                          ),
                        ),
                      ),
                    ),

                    const SizedBox(
                      height: 25,
                    ),

                    // =================================================
                    // New seeds
                    // =================================================

                    if (newlyAddedSeeds.isNotEmpty) ...[
                      const Divider(),

                      const SizedBox(
                        height: 20,
                      ),

                      const Text(
                        '🎁 新しい種を獲得しました！',
                        style:
                            TextStyle(
                          fontSize: 26,
                          fontWeight:
                              FontWeight.bold,
                        ),
                      ),

                      const SizedBox(
                        height: 12,
                      ),

                      ...newlyAddedSeeds.map(
                        (seed) =>
                            Padding(
                          padding:
                              const EdgeInsets.only(
                            bottom: 6,
                          ),
                          child:
                              Text(
                            '🌱 $seed',
                            textAlign:
                                TextAlign.center,
                            style:
                                const TextStyle(
                              fontSize: 20,
                            ),
                          ),
                        ),
                      ),

                      const SizedBox(
                        height: 20,
                      ),
                    ],

                    // =================================================
                    // Seed collection
                    // =================================================

                    const Divider(),

                    const SizedBox(
                      height: 20,
                    ),

                    const Text(
                      '種コレクション',
                      style:
                          TextStyle(
                        fontSize: 27,
                        fontWeight:
                            FontWeight.bold,
                      ),
                    ),

                    const SizedBox(
                      height: 10,
                    ),

                    Text(
                      '所持数：'
                      '${seedInventory.length}',
                      style:
                          const TextStyle(
                        fontSize: 21,
                        fontWeight:
                            FontWeight.bold,
                      ),
                    ),

                    const SizedBox(
                      height: 10,
                    ),

                    ...seedInventory.map(
                      (seed) =>
                          Padding(
                        padding:
                            const EdgeInsets.only(
                          bottom: 5,
                        ),
                        child:
                            Text(
                          '🌱 ${seed['flower_id']}',
                          style:
                              const TextStyle(
                            fontSize: 19,
                          ),
                        ),
                      ),
                    ),

                    // =================================================
                    // Source
                    // =================================================

                    if (selectedFolder != null) ...[
                      const SizedBox(
                        height: 30,
                      ),

                      Text(
                        '読み込み元\n'
                        '$selectedFolder',
                        textAlign:
                            TextAlign.center,
                        style:
                            const TextStyle(
                          fontSize: 13,
                        ),
                      ),
                    ],

                    const SizedBox(
                      height: 40,
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