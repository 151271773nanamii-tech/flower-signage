import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';

class ImportService {
  /// 複数LOGファイルの内容から1つのSHA-256を生成する
  static Future<String> createImportHash(
    List<File> logFiles,
  ) async {
    if (logFiles.isEmpty) {
      throw Exception(
        'ハッシュ生成対象のLOGファイルがありません。',
      );
    }

    // ファイル名順に並べる
    final sortedFiles = [...logFiles]
      ..sort(
        (a, b) => a.path.compareTo(b.path),
      );

    final bytes = <int>[];

    for (final file in sortedFiles) {
      if (!await file.exists()) {
        throw Exception(
          'LOGファイルが見つかりません。\n${file.path}',
        );
      }

      // ファイル名も含める
      bytes.addAll(
        utf8.encode(
          file.uri.pathSegments.last,
        ),
      );

      // 内容
      bytes.addAll(
        await file.readAsBytes(),
      );
    }

    return sha256
        .convert(bytes)
        .toString();
  }
}