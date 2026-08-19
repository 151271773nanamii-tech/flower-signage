import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';

class UsbMonitorService {
  UsbMonitorService({
    required this.onTagConnected,
    required this.onTagDisconnected,
    this.interval = const Duration(seconds: 1),
    this.disconnectMissThreshold = 3,
  });

  final void Function(String folderPath) onTagConnected;
  final void Function() onTagDisconnected;

  final Duration interval;
  final int disconnectMissThreshold;

  Timer? _timer;

  String? _currentTagPath;

  bool _checking = false;

  int _mountMissCount = 0;

  bool get isConnected =>
      _currentTagPath != null;

  String? get currentTagPath =>
      _currentTagPath;

  // ============================================================
  // START
  // ============================================================

  void start() {
    debugPrint(
      'UsbMonitorService START',
    );

    _timer?.cancel();

    _checking = false;
    _mountMissCount = 0;

    _check();

    _timer = Timer.periodic(
      interval,
      (_) => _check(),
    );
  }

  // ============================================================
  // STOP
  // ============================================================

  void stop() {
    debugPrint(
      'UsbMonitorService STOP',
    );

    _timer?.cancel();
    _timer = null;

    _checking = false;
    _mountMissCount = 0;
  }

  // ============================================================
  // MAIN CHECK
  // ============================================================

  Future<void> _check() async {
    if (_checking) {
      return;
    }

    _checking = true;

    try {
      // ========================================================
      // すでに接続済み
      // ========================================================

      if (_currentTagPath != null) {
        await _checkCurrentMount();

        return;
      }

      // ========================================================
      // 新しいタグを探す
      // ========================================================

      final detectedPath =
          await _findNewTag();

      if (detectedPath == null) {
        return;
      }

      _currentTagPath =
          detectedPath;

      _mountMissCount = 0;

      debugPrint(
        '================================',
      );

      debugPrint(
        'USB TAG CONNECTED',
      );

      debugPrint(
        'PATH: $detectedPath',
      );

      debugPrint(
        '================================',
      );

      onTagConnected(
        detectedPath,
      );
    } catch (e, stackTrace) {
      debugPrint(
        'USB MONITOR ERROR: $e',
      );

      debugPrint(
        '$stackTrace',
      );
    } finally {
      _checking = false;
    }
  }

  // ============================================================
  // 現在のマウント確認
  // ============================================================

  Future<void> _checkCurrentMount() async {
    final currentPath =
        _currentTagPath;

    if (currentPath == null) {
      return;
    }

    bool mountFound = false;

    try {
      if (Platform.isMacOS) {
        final root =
            Directory('/Volumes');

        if (await root.exists()) {
          final entities =
              await root
                  .list(
                    recursive: false,
                    followLinks: false,
                  )
                  .toList();

          for (final entity in entities) {
            if (entity.path ==
                currentPath) {
              mountFound = true;

              break;
            }
          }
        }
      } else {
        mountFound =
            await Directory(
          currentPath,
        ).exists();
      }
    } catch (e) {
      // 一時的な監視エラーだけで切断しない
      debugPrint(
        'USB mount check error: $e',
      );

      return;
    }

    // ==========================================================
    // 接続維持
    // ==========================================================

    if (mountFound) {
      if (_mountMissCount > 0) {
        debugPrint(
          'USB mount recovered: '
          '$currentPath',
        );
      }

      _mountMissCount = 0;

      return;
    }

    // ==========================================================
    // 見失った
    // ==========================================================

    _mountMissCount++;

    debugPrint(
      'USB MOUNT MISS: '
      '$_mountMissCount / '
      '$disconnectMissThreshold',
    );

    if (_mountMissCount <
        disconnectMissThreshold) {
      return;
    }

    // ==========================================================
    // 切断確定
    // ==========================================================

    debugPrint(
      '================================',
    );

    debugPrint(
      'USB TAG DISCONNECTED',
    );

    debugPrint(
      'OLD PATH: $currentPath',
    );

    debugPrint(
      '================================',
    );

    _currentTagPath = null;

    _mountMissCount = 0;

    onTagDisconnected();
  }

  // ============================================================
  // OS別検索
  // ============================================================

  Future<String?> _findNewTag() async {
    if (Platform.isMacOS) {
      return _findTagOnMacOS();
    }

    if (Platform.isWindows) {
      return _findTagOnWindows();
    }

    if (Platform.isLinux) {
      return _findTagOnLinux();
    }

    debugPrint(
      'Unsupported OS: '
      '${Platform.operatingSystem}',
    );

    return null;
  }

  // ============================================================
  // macOS
  // ============================================================

  Future<String?> _findTagOnMacOS() async {
    final root =
        Directory(
      '/Volumes',
    );

    if (!await root.exists()) {
      return null;
    }

    try {
      final entities =
          await root
              .list(
                recursive: false,
                followLinks: false,
              )
              .toList();

      for (final entity in entities) {
        if (entity is! Directory) {
          continue;
        }

        if (entity.path ==
            '/Volumes/Macintosh HD') {
          continue;
        }

        final result =
            await _checkCandidateTag(
          entity.path,
        );

        if (result != null) {
          return result;
        }
      }
    } catch (e) {
      debugPrint(
        'Cannot scan /Volumes: $e',
      );
    }

    return null;
  }

  // ============================================================
  // Windows
  // ============================================================

  Future<String?> _findTagOnWindows() async {
    for (
      int code = 68;
      code <= 90;
      code++
    ) {
      final drive =
          '${String.fromCharCode(code)}:\\';

      final directory =
          Directory(
        drive,
      );

      try {
        if (!await directory.exists()) {
          continue;
        }

        final result =
            await _checkCandidateTag(
          drive,
        );

        if (result != null) {
          return result;
        }
      } catch (_) {
        // 読めないドライブは無視
      }
    }

    return null;
  }

  // ============================================================
  // Linux
  // ============================================================

  Future<String?> _findTagOnLinux() async {
    final roots =
        <String>[];

    final home =
        Platform.environment[
            'HOME'];

    if (home != null) {
      final parts =
          home
              .split('/')
              .where(
                (part) =>
                    part.isNotEmpty,
              )
              .toList();

      if (parts.isNotEmpty) {
        roots.add(
          '/media/${parts.last}',
        );
      }
    }

    roots.addAll(
      [
        '/media',
        '/mnt',
      ],
    );

    final checked =
        <String>{};

    for (final rootPath in roots) {
      if (!checked.add(rootPath)) {
        continue;
      }

      final root =
          Directory(
        rootPath,
      );

      if (!await root.exists()) {
        continue;
      }

      try {
        final entities =
            await root
                .list(
                  recursive: false,
                  followLinks: false,
                )
                .toList();

        for (final entity in entities) {
          if (entity is! Directory) {
            continue;
          }

          final result =
              await _checkCandidateTag(
            entity.path,
          );

          if (result != null) {
            return result;
          }
        }
      } catch (e) {
        debugPrint(
          'Cannot scan '
          '$rootPath: $e',
        );
      }
    }

    return null;
  }

  // ============================================================
  // BLEタグ判定
  // ============================================================

  Future<String?> _checkCandidateTag(
    String folderPath,
  ) async {
    final separator =
        Platform.isWindows
            ? '\\'
            : '/';

    final candidates =
        <String>[
      'user_info.txt',
      'USER_INFO.TXT',
      'User_Info.txt',
    ];

    for (final fileName
        in candidates) {
      final path =
          '$folderPath'
          '$separator'
          '$fileName';

      final file =
          File(
        path,
      );

      try {
        if (await file.exists()) {
          debugPrint(
            'BLE tag candidate confirmed',
          );

          debugPrint(
            'user_info: $path',
          );

          return folderPath;
        }
      } catch (_) {
        // 未接続探索中なので無視
      }
    }

    return null;
  }
}