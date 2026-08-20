import 'dart:io';

import 'package:flutter/foundation.dart';

import 'log_parser.dart';
import 'user_info_parser.dart';

// import 'dart:convert';
import 'package:crypto/crypto.dart';

class TagFolderResult {
  final UserInfo userInfo;
  final List<File> logFiles;
  final List<LogParseResult> logResults;

  TagFolderResult({
    required this.userInfo,
    required this.logFiles,
    required this.logResults,
  });

  int get totalRecordCount {
    return logResults.fold(
      0,
      (sum, result) => sum + result.records.length,
    );
  }

  int get totalInvalidLineCount {
    return logResults.fold(
      0,
      (sum, result) => sum + result.invalidLineCount,
    );
  }

  Set<String> get uniqueAddresses {
    final result = <String>{};

    for (final logResult in logResults) {
      result.addAll(logResult.uniqueAddresses);
    }

    return result;
  }

  Set<String> get uniquePublicAddresses {
    final result = <String>{};

    for (final logResult in logResults) {
      result.addAll(
        logResult.uniquePublicAddresses,
      );
    }

    return result;
  }

  Set<String> get uniqueRandomAddresses {
    final result = <String>{};

    for (final logResult in logResults) {
      result.addAll(
        logResult.uniqueRandomAddresses,
      );
    }

    return result;
  }



}

class TagFolderService {
  // ============================================================
  // TAG FOLDER LOAD
  // ============================================================
  static Future<String> calculateLogHash(
    File file,
  ) async {
    final bytes = await file.readAsBytes();
    return sha256.convert(bytes).toString();
  }

  static Future<TagFolderResult> loadFolder(
    String folderPath,
  ) async {
    final directory =
        Directory(
      folderPath,
    );

    if (!await directory.exists()) {
      throw Exception(
        '選択したフォルダが見つかりません。',
      );
    }

    final entities =
        await directory
            .list(
              recursive: false,
              followLinks: false,
            )
            .toList();

    File? userInfoFile;

    final logFiles =
        <File>[];

    // ==========================================================
    // user_info.txt / LOG*.TXT を探す
    // ==========================================================

    for (final entity in entities) {
      if (entity is! File) {
        continue;
      }

      final fileName =
          entity.uri.pathSegments.last;

      final lowerName =
          fileName.toLowerCase();

      // --------------------------------------------------------
      // user_info.txt
      // --------------------------------------------------------

      if (lowerName ==
          'user_info.txt') {
        userInfoFile =
            entity;

        continue;
      }

      // --------------------------------------------------------
      // LOG*.TXT
      // --------------------------------------------------------

      if (lowerName.startsWith(
            'log',
          ) &&
          lowerName.endsWith(
            '.txt',
          )) {
        logFiles.add(
          entity,
        );
      }
    }

    // ==========================================================
    // user_info.txt 必須
    // ==========================================================

    if (userInfoFile == null) {
      throw Exception(
        'user_info.txt が見つかりません。',
      );
    }

    // ==========================================================
    // LOG 必須
    // ==========================================================

    // if (logFiles.isEmpty) {
    //   throw Exception(
    //     'LOGファイルが見つかりません。',
    //   );
    // }

    // ==========================================================
    // ファイル名順
    // ==========================================================

    logFiles.sort(
      (a, b) =>
          a.path.compareTo(
        b.path,
      ),
    );

    // ==========================================================
    // UserInfo
    // ==========================================================

    final userInfo =
        await UserInfoParser
            .parseFile(
      userInfoFile.path,
    );

    // ==========================================================
    // LOG parse
    // ==========================================================

    final logResults =
        <LogParseResult>[];

    for (final logFile in logFiles) {
      final result =
          await LogParser
              .parseFile(
        logFile.path,
      );

      logResults.add(
        result,
      );
    }

    return TagFolderResult(
      userInfo:
          userInfo,
      logFiles:
          logFiles,
      logResults:
          logResults,
    );
  }

  // ============================================================
  // LOG安全削除
  //
  // SQLite保存および保存確認が完了した後だけ
  // main.dart から呼び出す。
  //
  // 削除対象：
  //   LOG*.TXT
  //
  // 削除しない：
  //   CONFIG.TXT
  //   user_info.txt
  //   その他すべて
  // ============================================================

  static Future<int> deleteLogFiles(
    List<File> logFiles,
  ) async {
    debugPrint(
      '[DELETE] START',
    );

    // ==========================================================
    // LOGがない
    // ==========================================================

    if (logFiles.isEmpty) {
      debugPrint(
        '[DELETE] No LOG files',
      );

      return 0;
    }

    final safeFiles =
        <File>[];

    // ==========================================================
    // 1. 削除対象の安全確認
    // ==========================================================

    for (final file in logFiles) {
      final normalizedPath =
          file.path.replaceAll(
        '\\',
        '/',
      );

      final fileName =
          normalizedPath
              .split('/')
              .last;

      final upperName =
          fileName.toUpperCase();

      // --------------------------------------------------------
      // LOG*.TXT 以外は絶対削除しない
      // --------------------------------------------------------

      final isLogFile =
          upperName.startsWith(
            'LOG',
          ) &&
          upperName.endsWith(
            '.TXT',
          );

      if (!isLogFile) {
        debugPrint(
          '[DELETE] SKIP non-LOG: '
          '$fileName',
        );

        continue;
      }

      // --------------------------------------------------------
      // 念のため重要ファイルを明示的に保護
      // --------------------------------------------------------

      if (upperName ==
              'CONFIG.TXT' ||
          upperName ==
              'USER_INFO.TXT') {
        debugPrint(
          '[DELETE] PROTECTED: '
          '$fileName',
        );

        continue;
      }

      // --------------------------------------------------------
      // 実在確認
      // --------------------------------------------------------

      try {
        if (await file.exists()) {
          safeFiles.add(
            file,
          );
        }
      } catch (e) {
        throw Exception(
          'LOG削除前確認エラー\n'
          '${file.path}\n'
          '$e',
        );
      }
    }

    debugPrint(
      '[DELETE] Safe count = '
      '${safeFiles.length}',
    );

    // ==========================================================
    // 削除対象0件
    // ==========================================================

    if (safeFiles.isEmpty) {
      debugPrint(
        '[DELETE] Nothing to delete',
      );

      return 0;
    }

    // ==========================================================
    // 2. 削除実行
    // ==========================================================

    int deletedCount = 0;

    for (final file in safeFiles) {
      try {
        await file.delete();

        deletedCount++;

        debugPrint(
          '[DELETE] '
          '$deletedCount / '
          '${safeFiles.length} '
          '${file.path}',
        );
      } catch (e) {
        throw Exception(
          'LOG削除に失敗しました。\n'
          '削除済み: '
          '$deletedCount / '
          '${safeFiles.length}\n'
          '失敗ファイル: '
          '${file.path}\n'
          '$e',
        );
      }
    }

    // ==========================================================
    // 3. 削除後確認
    // ==========================================================

    int remainingCount = 0;

    final remainingPaths =
        <String>[];

    for (final file in safeFiles) {
      try {
        if (await file.exists()) {
          remainingCount++;

          remainingPaths.add(
            file.path,
          );
        }
      } catch (_) {
        remainingCount++;

        remainingPaths.add(
          file.path,
        );
      }
    }

    // ==========================================================
    // 削除失敗が残った
    // ==========================================================

    if (remainingCount > 0) {
      debugPrint(
        '[DELETE] Remaining files:',
      );

      for (final path in remainingPaths) {
        debugPrint(
          '[DELETE] REMAIN: $path',
        );
      }

      throw Exception(
        'LOG削除確認に失敗しました。\n'
        '$remainingCount 個のLOGが'
        '残っています。',
      );
    }

    // ==========================================================
    // SUCCESS
    // ==========================================================

    debugPrint(
      '[DELETE] SUCCESS',
    );

    debugPrint(
      '[DELETE] Deleted = '
      '$deletedCount',
    );

    return deletedCount;
  }
}