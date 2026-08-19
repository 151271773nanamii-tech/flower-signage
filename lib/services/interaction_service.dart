import 'dart:convert';

import 'package:flutter/services.dart';

/// 登録されているBLEタグ利用者
class RegisteredUser {
  final String userId;
  final String name;
  final String tagMac;

  /// この利用者と交流したときに獲得する花
  final String flower;

  const RegisteredUser({
    required this.userId,
    required this.name,
    required this.tagMac,
    required this.flower,
  });

  factory RegisteredUser.fromJson(
    Map<String, dynamic> json,
  ) {
    return RegisteredUser(
      userId: json['user_id'].toString(),
      name: json['name'].toString(),
      tagMac: json['tag_mac']
          .toString()
          .trim()
          .toUpperCase(),
      flower: json['flower'].toString(),
    );
  }
}

/// 交流が成立した相手
class InteractionHit {
  final RegisteredUser user;

  const InteractionHit({
    required this.user,
  });
}

/// 他ユーザとの交流を判定するサービス
class InteractionService {
  /// users.json を読み込む
  static Future<List<RegisteredUser>> loadUsers() async {
    final jsonString = await rootBundle.loadString(
      'assets/config/users.json',
    );

    final decoded = jsonDecode(jsonString);

    if (decoded is! List) {
      throw const FormatException(
        'users.json の形式が正しくありません。',
      );
    }

    return decoded
        .map(
          (item) => RegisteredUser.fromJson(
            Map<String, dynamic>.from(item as Map),
          ),
        )
        .toList();
  }

  /// BLEログから他ユーザとの交流を判定
  ///
  /// 同じMACアドレスが何回検出されても
  /// 1ユーザにつき1回だけ交流成立。
  static List<InteractionHit> detect({
    required Set<String> detectedAddresses,
    required List<RegisteredUser> users,
    required String ownTagMac,
  }) {
    final detectedUpper = detectedAddresses
        .map(
          (address) =>
              address.trim().toUpperCase(),
        )
        .toSet();

    final ownMac =
        ownTagMac.trim().toUpperCase();

    final hits = <InteractionHit>[];

    for (final user in users) {
      // 自分自身は交流相手として判定しない
      if (user.tagMac == ownMac) {
        continue;
      }

      // 1回以上検出されていれば交流成立
      if (detectedUpper.contains(user.tagMac)) {
        hits.add(
          InteractionHit(
            user: user,
          ),
        );
      }
    }

    return hits;
  }
}