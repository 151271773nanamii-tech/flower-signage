import 'config_service.dart';

class GrowthService {
  // ============================================================
  // STAGE CALCULATION
  //
  // 返す値は「花の現在Stage」ではなく、
  // 今回の接続で加算するStage数。
  // ============================================================

  static int calculateStage({
    required int value,
    required AppConfig config,
  }) {
    if (value < 0) {
      throw ArgumentError(
        '成長値は0以上である必要があります。\n'
        '現在値: $value',
      );
    }

    if (value >=
        config.stage3Threshold) {
      return 3;
    }

    if (value >=
        config.stage2Threshold) {
      return 2;
    }

    if (value >=
        config.stage1Threshold) {
      return 1;
    }

    return 0;
  }

  static int calculateStageDelta({
    required int value,
    required AppConfig config,
  }) {
    return calculateStage(
      value:
          value,
      config:
          config,
    );
  }

  static int maxStageForFlower({
    required String flowerId,
    required AppConfig config,
  }) {
    return config.maxStageForFlower(
      flowerId,
    );
  }

  static bool isBloomed({
    required String flowerId,
    required int stage,
    required AppConfig config,
  }) {
    return stage >=
        config.maxStageForFlower(
          flowerId,
        );
  }
}
