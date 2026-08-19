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

  LogParseResult({
    required this.records,
    required this.invalidLineCount,
  });

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
  static Future<LogParseResult> parseFile(String filePath) async {
    final file = File(filePath);

    if (!await file.exists()) {
      throw Exception('LOGファイルが見つかりません。');
    }

    final lines = await file.readAsLines();

    final records = <BleRecord>[];
    int invalidLineCount = 0;

    final regex = RegExp(
      r'"addr"\s*:\s*"([0-9A-Fa-f:]{17})\s+\((public|random)\)"'
      r'.*"rssi"\s*:\s*(-?\d+)'
      r'.*"timestamp"\s*:\s*"([^"]+)"',
    );

    for (final line in lines) {
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

    return LogParseResult(
      records: records,
      invalidLineCount: invalidLineCount,
    );
  }
}