import 'config_service.dart';

class GrowthService {
  // ============================================================
  // STAGE CALCULATION
  // ============================================================

  static int calculateStage({
    required int value,
    required AppConfig config,
  }) {
    // ----------------------------------------------------------
    // 異常値チェック
    // ----------------------------------------------------------

    if (value < 0) {
      throw ArgumentError(
        '成長値は0以上である必要があります。\n'
        '現在値: $value',
      );
    }

    // ----------------------------------------------------------
    // Stage 3
    // stage3_threshold 以上
    // 例: 1000〜
    // ----------------------------------------------------------

    if (value >= config.stage3Threshold) {
      return 3;
    }

    // ----------------------------------------------------------
    // Stage 2
    // stage2_threshold 以上
    // stage3_threshold 未満
    //
    // 例: 600〜999
    // ----------------------------------------------------------

    if (value >= config.stage2Threshold) {
      return 2;
    }

    // ----------------------------------------------------------
    // Stage 1
    // stage1_threshold 以上
    // stage2_threshold 未満
    //
    // 例: 299〜599
    // ----------------------------------------------------------

    if (value >= config.stage1Threshold) {
      return 1;
    }

    // ----------------------------------------------------------
    // Stage 0
    // stage1_threshold 未満
    //
    // 例: 0〜298
    // ----------------------------------------------------------

    return 0;
  }

  // ============================================================
  // BLOOM CHECK
  // ============================================================

  static bool isBloomed({
    required int value,
    required AppConfig config,
  }) {
    return calculateStage(
          value: value,
          config: config,
        ) ==
        3;
  }
}