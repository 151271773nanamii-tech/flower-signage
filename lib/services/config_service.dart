import 'dart:convert';

import 'package:flutter/services.dart';

class AppConfig {
  // ============================================================
  // Supported flowers
  // ============================================================

  static const List<String> supportedFlowerIds = [
    'tulip',
    'sunflower',
    'rose',
    'kernation',
    'suzuran',
    'ajisai',
    'cosmos',
  ];

  static const Map<String, int> flowerMaxStages = {
    'tulip': 6,
    'sunflower': 6,
    'rose': 6,
    'kernation': 6,
    'suzuran': 6,
    'ajisai': 5,
    'cosmos': 4,
  };

  // ============================================================
  // Growth
  // ============================================================

  final String growthMetric;

  final int stage1Threshold;
  final int stage2Threshold;
  final int stage3Threshold;

  // ============================================================
  // Initial seeds
  // ============================================================

  final List<String> initialSeeds;

  // ============================================================
  // Scan
  // ============================================================

  final int scanGroupSeconds;

  // ============================================================
  // USB
  // ============================================================

  final int usbPollSeconds;
  final int disconnectMissThreshold;

  // ============================================================
  // LOG
  // ============================================================

  final bool deleteLogsAfterSuccess;
  final bool deleteProcessedLogs;

  // ============================================================
  // Debug
  // ============================================================

  final bool debugLogging;

  const AppConfig({
    required this.growthMetric,
    required this.stage1Threshold,
    required this.stage2Threshold,
    required this.stage3Threshold,
    required this.initialSeeds,
    required this.scanGroupSeconds,
    required this.usbPollSeconds,
    required this.disconnectMissThreshold,
    required this.deleteLogsAfterSuccess,
    required this.deleteProcessedLogs,
    required this.debugLogging,
  });

  factory AppConfig.fromJson(
    Map<String, dynamic> json,
  ) {
    final growth =
        _requireMap(
      json,
      'growth',
    );

    final scan =
        _requireMap(
      json,
      'scan',
    );

    final usb =
        _requireMap(
      json,
      'usb',
    );

    final log =
        _requireMap(
      json,
      'log',
    );

    final debug =
        _requireMap(
      json,
      'debug',
    );

    final config =
        AppConfig(
      growthMetric:
          _requireString(
        growth,
        'metric',
      ),

      stage1Threshold:
          _requireInt(
        growth,
        'stage1_threshold',
      ),

      stage2Threshold:
          _requireInt(
        growth,
        'stage2_threshold',
      ),

      stage3Threshold:
          _requireInt(
        growth,
        'stage3_threshold',
      ),

      initialSeeds:
          _requireStringList(
        json,
        'initial_seeds',
      ),

      scanGroupSeconds:
          _requireInt(
        scan,
        'group_seconds',
      ),

      usbPollSeconds:
          _requireInt(
        usb,
        'poll_seconds',
      ),

      disconnectMissThreshold:
          _requireInt(
        usb,
        'disconnect_miss_threshold',
      ),

      deleteLogsAfterSuccess:
          _requireBool(
        log,
        'delete_after_success',
      ),

      deleteProcessedLogs:
          _requireBool(
        log,
        'delete_processed_logs',
      ),

      debugLogging:
          _requireBool(
        debug,
        'logging',
      ),
    );

    config.validate();

    return config;
  }

  // ============================================================
  // Flower helpers
  // ============================================================

  bool isSupportedFlower(
    String flowerId,
  ) {
    return supportedFlowerIds.contains(
      flowerId,
    );
  }

  int maxStageForFlower(
    String flowerId,
  ) {
    final maxStage =
        flowerMaxStages[flowerId];

    if (maxStage == null) {
      throw ArgumentError(
        '未対応のflower_idです。\n'
        'flower_id: $flowerId\n'
        '使用可能: ${supportedFlowerIds.join(', ')}',
      );
    }

    return maxStage;
  }

  int clampStageForFlower({
    required String flowerId,
    required int stage,
  }) {
    final maxStage =
        maxStageForFlower(
      flowerId,
    );

    return stage
        .clamp(
          0,
          maxStage,
        )
        .toInt();
  }

  bool isBloomStage({
    required String flowerId,
    required int stage,
  }) {
    return stage >=
        maxStageForFlower(
          flowerId,
        );
  }

  String flowerStageAsset({
    required String flowerId,
    required int stage,
  }) {
    final safeStage =
        clampStageForFlower(
      flowerId:
          flowerId,
      stage:
          stage,
    );

    return 'assets/images/'
        '$flowerId/'
        '$flowerId$safeStage.png';
  }

  String flowerSeedAsset(
    String flowerId,
  ) {
    if (!isSupportedFlower(
      flowerId,
    )) {
      throw ArgumentError(
        '未対応のflower_idです。\n'
        'flower_id: $flowerId',
      );
    }

    return 'assets/images/'
        '$flowerId/'
        '${flowerId}_seed.png';
  }

  // ============================================================
  // Validation
  // ============================================================

  void validate() {
    if (growthMetric !=
        'unique_address_count') {
      throw FormatException(
        'growth.metric が不正です。\n'
        '"unique_address_count" '
        'を指定してください。\n'
        '現在値: $growthMetric',
      );
    }

    if (stage1Threshold < 0) {
      throw FormatException(
        'stage1_threshold は'
        '0以上にしてください。',
      );
    }

    if (stage2Threshold <=
        stage1Threshold) {
      throw FormatException(
        'stage2_threshold は'
        'stage1_threshold より'
        '大きくしてください。\n'
        '$stage1Threshold -> '
        '$stage2Threshold',
      );
    }

    if (stage3Threshold <=
        stage2Threshold) {
      throw FormatException(
        'stage3_threshold は'
        'stage2_threshold より'
        '大きくしてください。\n'
        '$stage2Threshold -> '
        '$stage3Threshold',
      );
    }

    // 新仕様では初期種の個数を2個に固定しない。
    // 同じ種類の種を複数持つことも可能。
    for (final flowerId
        in initialSeeds) {
      if (!supportedFlowerIds.contains(
        flowerId,
      )) {
        throw FormatException(
          'initial_seeds に'
          '未対応のflower_idがあります。\n'
          'flower_id: $flowerId',
        );
      }
    }

    if (scanGroupSeconds <= 0) {
      throw FormatException(
        'scan.group_seconds は'
        '1以上にしてください。',
      );
    }

    if (usbPollSeconds <= 0) {
      throw FormatException(
        'usb.poll_seconds は'
        '1以上にしてください。',
      );
    }

    if (disconnectMissThreshold <=
        0) {
      throw FormatException(
        'usb.disconnect_miss_threshold '
        'は1以上にしてください。',
      );
    }
  }

  @override
  String toString() {
    return '''
AppConfig(
  growthMetric: $growthMetric,
  stage1Threshold: $stage1Threshold,
  stage2Threshold: $stage2Threshold,
  stage3Threshold: $stage3Threshold,
  initialSeeds: $initialSeeds,
  supportedFlowerIds: $supportedFlowerIds,
  flowerMaxStages: $flowerMaxStages,
  scanGroupSeconds: $scanGroupSeconds,
  usbPollSeconds: $usbPollSeconds,
  disconnectMissThreshold: $disconnectMissThreshold,
  deleteLogsAfterSuccess: $deleteLogsAfterSuccess,
  deleteProcessedLogs: $deleteProcessedLogs,
  debugLogging: $debugLogging
)
''';
  }

  static Map<String, dynamic> _requireMap(
    Map<String, dynamic> json,
    String key,
  ) {
    final value =
        json[key];

    if (value is! Map) {
      throw FormatException(
        '"$key" がありません、'
        'または形式が不正です。',
      );
    }

    return Map<String, dynamic>.from(
      value,
    );
  }

  static String _requireString(
    Map<String, dynamic> json,
    String key,
  ) {
    final value =
        json[key];

    if (value is! String ||
        value.trim().isEmpty) {
      throw FormatException(
        '"$key" は'
        '空でない文字列にしてください。',
      );
    }

    return value.trim();
  }

  static int _requireInt(
    Map<String, dynamic> json,
    String key,
  ) {
    final value =
        json[key];

    if (value is int) {
      return value;
    }

    if (value is num &&
        value % 1 == 0) {
      return value.toInt();
    }

    throw FormatException(
      '"$key" は整数にしてください。',
    );
  }

  static bool _requireBool(
    Map<String, dynamic> json,
    String key,
  ) {
    final value =
        json[key];

    if (value is! bool) {
      throw FormatException(
        '"$key" はtrue/false'
        'にしてください。',
      );
    }

    return value;
  }

  static List<String>
      _requireStringList(
    Map<String, dynamic> json,
    String key,
  ) {
    final value =
        json[key];

    if (value is! List) {
      throw FormatException(
        '"$key" は配列にしてください。',
      );
    }

    final result =
        <String>[];

    for (final item in value) {
      if (item is! String ||
          item.trim().isEmpty) {
        throw FormatException(
          '"$key" の各要素は'
          '空でない文字列にしてください。',
        );
      }

      result.add(
        item.trim(),
      );
    }

    return result;
  }
}

class ConfigService {
  static const String _assetPath =
      'assets/config/app_config.json';

  static Future<AppConfig>
      loadConfig() async {
    try {
      final jsonString =
          await rootBundle.loadString(
        _assetPath,
      );

      final decoded =
          jsonDecode(
        jsonString,
      );

      if (decoded
          is! Map<String, dynamic>) {
        throw const FormatException(
          'app_config.json の'
          '最上位形式が不正です。',
        );
      }

      return AppConfig.fromJson(
        decoded,
      );
    } on FormatException catch (e) {
      throw Exception(
        'app_config.json の'
        '設定内容が不正です.\n\n'
        '${e.message}',
      );
    } catch (e) {
      throw Exception(
        'app_config.json の'
        '読み込みに失敗しました.\n\n'
        '$e',
      );
    }
  }
}
