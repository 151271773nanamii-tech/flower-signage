import 'dart:io';

class BleRecord {
  final String address;
  final String addressType;
  final int rssi;
  final DateTime timestamp;

  BleRecord({
    required this.address,
    required this.addressType,
    required this.rssi,
    required this.timestamp,
  });
}

class LogParseResult {
  final List<BleRecord> records;
  final int invalidLineCount;
  final int totalNonEmptyLineCount;

  LogParseResult({
    required this.records,
    required this.invalidLineCount,
    required this.totalNonEmptyLineCount,
  });

  int get validLineCount => records.length;

  double get invalidRatio {
    if (totalNonEmptyLineCount == 0) {
      return 0.0;
    }
    return invalidLineCount / totalNonEmptyLineCount;
  }

  bool get hasAnyValidRecord => records.isNotEmpty;

  Set<String> get uniqueAddresses {
    return records.map((record) => record.address).toSet();
  }

  Set<String> get uniquePublicAddresses {
    return records
        .where((record) => record.addressType == 'public')
        .map((record) => record.address)
        .toSet();
  }

  Set<String> get uniqueRandomAddresses {
    return records
        .where((record) => record.addressType == 'random')
        .map((record) => record.address)
        .toSet();
  }
}

class LogParser {
  /// 大量の不正行を正常データとして処理しないための安全基準。
  /// 20行以上あるLOGで、不正行が80%以上なら破損扱いとする。
  static const int _minimumLinesForCorruptionCheck = 20;
  static const double _maxInvalidRatio = 0.80;

  static Future<LogParseResult> parseFile(String filePath) async {
    final file = File(filePath);

    if (!await file.exists()) {
      throw Exception('LOGファイルが見つかりません。\n$filePath');
    }

    final lines = await file.readAsLines();

    final records = <BleRecord>[];
    int invalidLineCount = 0;
    int totalNonEmptyLineCount = 0;

    final regex = RegExp(
      r'"addr"\s*:\s*"([0-9A-Fa-f:]{17})\s+\((public|random)\)"'
      r'.*"rssi"\s*:\s*(-?\d+)'
      r'.*"timestamp"\s*:\s*"([^"]+)"',
    );

    for (final line in lines) {
      if (line.trim().isEmpty) {
        continue;
      }

      totalNonEmptyLineCount++;

      final match = regex.firstMatch(line);

      if (match == null) {
        invalidLineCount++;
        continue;
      }

      try {
        final address = match.group(1)!.toUpperCase();
        final addressType = match.group(2)!;
        final rssi = int.parse(match.group(3)!);
        final timestamp = DateTime.parse(match.group(4)!);

        records.add(
          BleRecord(
            address: address,
            addressType: addressType,
            rssi: rssi,
            timestamp: timestamp,
          ),
        );
      } catch (_) {
        invalidLineCount++;
      }
    }

    if (totalNonEmptyLineCount > 0 && records.isEmpty) {
      throw Exception(
        'LOGファイルを解析できませんでした。\n'
        '有効なBLEレコードが0件です。\n'
        'file: $filePath\n'
        'lines: $totalNonEmptyLineCount',
      );
    }

    final invalidRatio = totalNonEmptyLineCount == 0
        ? 0.0
        : invalidLineCount / totalNonEmptyLineCount;

    if (totalNonEmptyLineCount >= _minimumLinesForCorruptionCheck &&
        invalidRatio >= _maxInvalidRatio) {
      throw Exception(
        'LOGファイルの破損率が高いため処理を中止しました。\n'
        'file: $filePath\n'
        'valid: ${records.length}\n'
        'invalid: $invalidLineCount\n'
        'invalid ratio: ${(invalidRatio * 100).toStringAsFixed(1)}%',
      );
    }

    return LogParseResult(
      records: records,
      invalidLineCount: invalidLineCount,
      totalNonEmptyLineCount: totalNonEmptyLineCount,
    );
  }
}
