import 'dart:convert';

import 'package:flutter/services.dart';

import 'log_parser.dart';

class Checkpoint {
  final String id;
  final String name;
  final List<String> addresses;
  final double requiredRatio;
  final String flower;

  const Checkpoint({
    required this.id,
    required this.name,
    required this.addresses,
    required this.requiredRatio,
    required this.flower,
  });

  factory Checkpoint.fromJson(Map<String, dynamic> json) {
    final rawAddresses = json['addresses'] as List<dynamic>;

    return Checkpoint(
      id: json['id'].toString(),
      name: json['name'].toString(),
      addresses: rawAddresses
          .map(
            (address) =>
                address.toString().trim().toUpperCase(),
          )
          .toList(),
      requiredRatio:
          (json['required_ratio'] as num).toDouble(),
      flower: json['flower'].toString(),
    );
  }
}

class CheckpointHit {
  final Checkpoint checkpoint;

  /// 成立したスキャンで検出された登録アドレス数
  final int detectedCount;

  /// チェックポイントに登録されている全アドレス数
  final int totalAddressCount;

  /// 成立したときの検出割合
  final double detectedRatio;

  /// 成立したスキャンの開始時刻
  final DateTime scanTime;

  const CheckpointHit({
    required this.checkpoint,
    required this.detectedCount,
    required this.totalAddressCount,
    required this.detectedRatio,
    required this.scanTime,
  });
}

class CheckpointService {
  /// checkpoints.jsonを読み込む
  static Future<List<Checkpoint>> loadCheckpoints() async {
    final jsonString = await rootBundle.loadString(
      'assets/config/checkpoints.json',
    );

    final decoded = jsonDecode(jsonString);

    if (decoded is! List) {
      throw const FormatException(
        'checkpoints.json の形式が正しくありません。',
      );
    }

    return decoded
        .map(
          (item) => Checkpoint.fromJson(
            Map<String, dynamic>.from(item as Map),
          ),
        )
        .toList();
  }

  /// ログを時間ごとのスキャンにまとめて
  /// チェックポイントを判定する
  ///
  /// scanGroupSeconds:
  /// 何秒以内のデータを同じスキャンとして扱うか
  static List<CheckpointHit> detect({
    required List<BleRecord> records,
    required List<Checkpoint> checkpoints,
    int scanGroupSeconds = 15,
  }) {
    if (records.isEmpty) {
      return [];
    }

    // 時刻順に並べる
    final sortedRecords = [...records]
      ..sort(
        (a, b) => a.timestamp.compareTo(b.timestamp),
      );

    // ------------------------------------------------------------
    // スキャン単位にグループ化
    // ------------------------------------------------------------

    final scanGroups = <List<BleRecord>>[];

    List<BleRecord> currentGroup = [];
    DateTime? groupStart;

    for (final record in sortedRecords) {
      if (groupStart == null) {
        groupStart = record.timestamp;
        currentGroup.add(record);
        continue;
      }

      final difference = record.timestamp
          .difference(groupStart)
          .inSeconds;

      if (difference < scanGroupSeconds) {
        currentGroup.add(record);
      } else {
        scanGroups.add(currentGroup);

        currentGroup = [record];
        groupStart = record.timestamp;
      }
    }

    if (currentGroup.isNotEmpty) {
      scanGroups.add(currentGroup);
    }

    // ------------------------------------------------------------
    // 各チェックポイントを判定
    // ------------------------------------------------------------

    final hits = <CheckpointHit>[];

    for (final checkpoint in checkpoints) {
      // 同じチェックポイントは
      // ログ全体で1回だけ獲得
      CheckpointHit? bestHit;

      for (final scan in scanGroups) {
        if (scan.isEmpty) {
          continue;
        }

        // publicだけを使用
        final detectedPublicAddresses = scan
            .where(
              (record) =>
                  record.addressType == 'public',
            )
            .map(
              (record) =>
                  record.address.toUpperCase(),
            )
            .toSet();

        final checkpointAddresses =
            checkpoint.addresses.toSet();

        final detectedCount =
            checkpointAddresses
                .intersection(
                  detectedPublicAddresses,
                )
                .length;

        final totalCount =
            checkpointAddresses.length;

        if (totalCount == 0) {
          continue;
        }

        final ratio =
            detectedCount / totalCount;

        // 半分以上など、設定した割合以上なら成立
        if (ratio >= checkpoint.requiredRatio) {
          final hit = CheckpointHit(
            checkpoint: checkpoint,
            detectedCount: detectedCount,
            totalAddressCount: totalCount,
            detectedRatio: ratio,
            scanTime: scan.first.timestamp,
          );

          // 最も検出割合が高かったものを残す
          if (bestHit == null ||
              hit.detectedRatio >
                  bestHit.detectedRatio) {
            bestHit = hit;
          }
        }
      }

      // 同じチェックポイントは1件だけ追加
      if (bestHit != null) {
        hits.add(bestHit);
      }
    }

    return hits;
  }
}