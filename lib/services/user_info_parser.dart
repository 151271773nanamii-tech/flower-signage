import 'dart:io';

class UserInfo {
  final String userId;
  final String macAddress;

  const UserInfo({
    required this.userId,
    required this.macAddress,
  });
}

class UserInfoParser {
  static Future<UserInfo> parseFile(String filePath) async {
    final file = File(filePath);

    if (!await file.exists()) {
      throw Exception('user_info.txt が見つかりません。');
    }

    final lines = await file.readAsLines();

    String? userId;
    String? macAddress;

    for (final line in lines) {
      final trimmed = line.trim();

      if (trimmed.startsWith('user_id=')) {
        userId = trimmed.substring('user_id='.length).trim();
      }

      if (trimmed.startsWith('mac_address=')) {
        macAddress =
            trimmed.substring('mac_address='.length).trim().toUpperCase();
      }
    }

    if (userId == null || userId.isEmpty) {
      throw Exception('user_id を取得できませんでした。');
    }

    if (macAddress == null || macAddress.isEmpty) {
      throw Exception('mac_address を取得できませんでした。');
    }

    final macRegex = RegExp(
      r'^([0-9A-F]{2}:){5}[0-9A-F]{2}$',
    );

    if (!macRegex.hasMatch(macAddress)) {
      throw Exception(
        'MACアドレスの形式が正しくありません。\n$macAddress',
      );
    }

    return UserInfo(
      userId: userId,
      macAddress: macAddress,
    );
  }
}