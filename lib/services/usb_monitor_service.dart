import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';

import 'tag_serial_service.dart';

class UsbMonitorService {
  UsbMonitorService({
    required this.onTagConnected,
    required this.onTagDisconnected,
    this.interval = const Duration(seconds: 1),
    this.disconnectMissThreshold = 3,
  });

  final void Function(String folderPath)
      onTagConnected;

  final void Function()
      onTagDisconnected;

  final Duration interval;

  final int disconnectMissThreshold;

  Timer? _timer;

  // ============================================================
  // 現在接続中のStorage
  // ============================================================

  String? _currentTagPath;

  // ============================================================
  // UARTから取得したMAC
  // ============================================================

  String? _currentTagMac;

  // ============================================================
  // 処理中フラグ
  // ============================================================

  bool _checking = false;

  bool _switchingToStorage = false;

  int _mountMissCount = 0;

  // ============================================================
  // Getter
  // ============================================================

  bool get isConnected =>
      _currentTagPath != null;

  String? get currentTagPath =>
      _currentTagPath;

  String? get currentTagMac =>
      _currentTagMac;

  // ============================================================
  // SAFE EJECT
  // ============================================================

  /// SafeEjectService.eject() が成功したあとに呼ぶ。
  ///
  /// 物理抜線は追跡しない。
  /// 現在のタグ状態を忘れて、次に検出されたタグを新しい処理対象にする。
  void completeSafeEject() {
    debugPrint(
      'UsbMonitorService: completeSafeEject',
    );

    _currentTagPath = null;
    _currentTagMac = null;
    _mountMissCount = 0;
    _switchingToStorage = false;
  }

  // ============================================================
  // START
  // ============================================================

  void start() {
    debugPrint(
      'UsbMonitorService START',
    );

    _timer?.cancel();

    _checking = false;

    _switchingToStorage = false;

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

    _switchingToStorage = false;

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
      // すでにStorageとして接続済み
      // ========================================================

      if (_currentTagPath != null) {
        await _checkCurrentMount();

        return;
      }

      // ========================================================
      // Storage切替処理中
      // ========================================================

      if (_switchingToStorage) {
        return;
      }

      // ========================================================
      // まず、すでにStorageモードのタグがないか確認
      //
      // アプリ起動前にStorageモードになっていた場合に対応
      // ========================================================

      final existingStorage =
          await _findMountedTagStorage();

      if (existingStorage != null) {
        await _confirmConnectedStorage(
          existingStorage,
        );

        return;
      }

      // ========================================================
      // UARTタグを探す
      // ========================================================

      final portName =
          TagSerialService.findTagPort();

      if (portName == null) {
        return;
      }

      // ========================================================
      // UART
      // ↓
      // TIME SYNC
      // ↓
      // MAC
      // ↓
      // USB Storage
      // ========================================================

      await _switchSerialTagToStorage(
        portName,
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
  // UARTタグ → USB Storage
  // ============================================================

  Future<void> _switchSerialTagToStorage(
    String portName,
  ) async {
    if (_switchingToStorage) {
      return;
    }

    _switchingToStorage = true;

    try {
      debugPrint(
        '================================',
      );

      debugPrint(
        'SERIAL TAG FOUND',
      );

      debugPrint(
        'PORT: $portName',
      );

      debugPrint(
        '================================',
      );

      // ========================================================
      // 切替前のStorage一覧を保存
      // ========================================================

      final beforeVolumes =
          await _getMountedStoragePaths();

      // ========================================================
      // TIME SYNC
      // MAC取得
      // STORAGEコマンド送信
      // ========================================================

      final result =
          await TagSerialService.initializeTag(
        portName: portName,
      );

      _currentTagMac =
          result.macAddress;

      debugPrint(
        'TAG MAC: '
        '${result.macAddress}',
      );

      debugPrint(
        'Waiting for USB storage...',
      );

      // ========================================================
      // Storage出現待ち
      // ========================================================

      final storagePath =
          await _waitForNewStorage(
        beforeVolumes:
            beforeVolumes,
      );

      if (storagePath == null) {
        throw Exception(
          'USB Storageへの切替後、'
          'ストレージが見つかりませんでした。',
        );
      }

      // ========================================================
      // filesystem ready待ち
      //
      // Pythonで確認した
      // 「Volume出現直後はまだ読めない」
      // ケースへの対処
      // ========================================================

      final ready =
          await _waitForFilesystemReady(
        storagePath,
      );

      if (!ready) {
        throw Exception(
          'USB Storageは認識されましたが、'
          'ファイルを読み込めませんでした。\n'
          '$storagePath',
        );
      }

      // ========================================================
      // BLEタグとして確認
      // ========================================================

      final valid =
          await _isTagStorage(
        storagePath,
      );

      if (!valid) {
        throw Exception(
          'USB Storageは認識されましたが、'
          'BLEタグ用のuser_info.txtが'
          '見つかりませんでした。\n'
          '$storagePath',
        );
      }

      // ========================================================
      // 接続確定
      // ========================================================

      await _confirmConnectedStorage(
        storagePath,
      );
    } catch (e) {
      _currentTagMac = null;

      rethrow;
    } finally {
      _switchingToStorage = false;
    }
  }

  // ============================================================
  // Storage接続確定
  // ============================================================

  Future<void> _confirmConnectedStorage(
    String storagePath,
  ) async {
    if (_currentTagPath != null) {
      return;
    }

    _currentTagPath =
        storagePath;

    _mountMissCount = 0;

    debugPrint(
      '================================',
    );

    debugPrint(
      'USB TAG CONNECTED',
    );

    debugPrint(
      'PATH: $storagePath',
    );

    if (_currentTagMac != null) {
      debugPrint(
        'MAC: $_currentTagMac',
      );
    }

    debugPrint(
      '================================',
    );

    onTagConnected(
      storagePath,
    );
  }

  // ============================================================
  // Storage出現待ち
  // ============================================================

  Future<String?> _waitForNewStorage({
    required Set<String> beforeVolumes,
  }) async {
    // 最大15秒待つ

    for (
      int second = 1;
      second <= 15;
      second++
    ) {
      await Future.delayed(
        const Duration(
          seconds: 1,
        ),
      );

      final currentVolumes =
          await _getMountedStoragePaths();

      final newVolumes =
          currentVolumes
              .difference(
                beforeVolumes,
              );

      debugPrint(
        '[STORAGE WAIT] '
        '$second / 15',
      );

      debugPrint(
        '[STORAGE WAIT] '
        'current=$currentVolumes',
      );

      if (newVolumes.isEmpty) {
        continue;
      }

      // ========================================================
      // 新しく出たVolumeの中からタグを探す
      // ========================================================

      for (final path
          in newVolumes) {
        debugPrint(
          '[STORAGE FOUND] '
          '$path',
        );

        return path;
      }
    }

    return null;
  }

  // ============================================================
  // filesystem ready待ち
  // ============================================================

  Future<bool> _waitForFilesystemReady(
    String storagePath,
  ) async {
    for (
      int retry = 1;
      retry <= 10;
      retry++
    ) {
      try {
        final directory =
            Directory(
          storagePath,
        );

        if (!await directory.exists()) {
          await Future.delayed(
            const Duration(
              seconds: 1,
            ),
          );

          continue;
        }

        // 実際に一覧を読む
        await directory
            .list(
              recursive: false,
              followLinks: false,
            )
            .toList();

        debugPrint(
          '[FILESYSTEM READY] '
          'after ${retry}s',
        );

        return true;
      } on FileSystemException catch (e) {
        debugPrint(
          '[FILESYSTEM WAIT] '
          '$retry / 10 '
          '$e',
        );
      } catch (e) {
        debugPrint(
          '[FILESYSTEM WAIT] '
          '$retry / 10 '
          '$e',
        );
      }

      await Future.delayed(
        const Duration(
          seconds: 1,
        ),
      );
    }

    return false;
  }

  // ============================================================
  // 現在のStorageがまだ存在するか確認
  // ============================================================

  Future<void> _checkCurrentMount() async {
    final currentPath =
        _currentTagPath;

    if (currentPath == null) {
      return;
    }

    bool mountFound = false;

    try {
      mountFound =
          await Directory(
        currentPath,
      ).exists();
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

    if (_currentTagMac != null) {
      debugPrint(
        'OLD MAC: $_currentTagMac',
      );
    }

    debugPrint(
      '================================',
    );

    _currentTagPath = null;

    _currentTagMac = null;

    _mountMissCount = 0;

    onTagDisconnected();
  }

  // ============================================================
  // すでにStorageモードのタグを探す
  // ============================================================

  Future<String?>
      _findMountedTagStorage() async {
    final paths =
        await _getMountedStoragePaths();

    for (final path in paths) {
      try {
        if (await _isTagStorage(
          path,
        )) {
          return path;
        }
      } catch (_) {
        // 読めないVolumeは無視
      }
    }

    return null;
  }

  // ============================================================
  // BLEタグStorage判定
  //
  // user_info.txt があればタグとして扱う
  // ============================================================

  Future<bool> _isTagStorage(
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

      try {
        if (await File(
          path,
        ).exists()) {
          debugPrint(
            'BLE tag storage confirmed',
          );

          debugPrint(
            'user_info: $path',
          );

          return true;
        }
      } catch (_) {
        // 他Volumeなどは無視
      }
    }

    return false;
  }

  // ============================================================
  // OS別マウント一覧
  // ============================================================

  Future<Set<String>>
      _getMountedStoragePaths() async {
    if (Platform.isMacOS) {
      return _getMacVolumes();
    }

    if (Platform.isWindows) {
      return _getWindowsVolumes();
    }

    if (Platform.isLinux) {
      return _getLinuxVolumes();
    }

    return <String>{};
  }

  // ============================================================
  // macOS
  // ============================================================

  Future<Set<String>>
      _getMacVolumes() async {
    final result =
        <String>{};

    final root =
        Directory(
      '/Volumes',
    );

    if (!await root.exists()) {
      return result;
    }

    try {
      final entities =
          await root
              .list(
                recursive: false,
                followLinks: false,
              )
              .toList();

      for (final entity
          in entities) {
        if (entity is! Directory) {
          continue;
        }

        // 内蔵ディスク除外
        if (entity.path ==
            '/Volumes/Macintosh HD') {
          continue;
        }

        result.add(
          entity.path,
        );
      }
    } catch (e) {
      debugPrint(
        'Cannot scan /Volumes: $e',
      );
    }

    return result;
  }

  // ============================================================
  // Windows
  // ============================================================

  Future<Set<String>>
      _getWindowsVolumes() async {
    final result =
        <String>{};

    // D: ～ Z:

    for (
      int code = 68;
      code <= 90;
      code++
    ) {
      final drive =
          '${String.fromCharCode(code)}:\\';

      try {
        if (await Directory(
          drive,
        ).exists()) {
          result.add(
            drive,
          );
        }
      } catch (_) {}
    }

    return result;
  }

  // ============================================================
  // Linux
  // ============================================================

  Future<Set<String>>
      _getLinuxVolumes() async {
    final result =
        <String>{};

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

    for (final rootPath
        in roots) {
      if (!checked.add(
        rootPath,
      )) {
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

        for (final entity
            in entities) {
          if (entity
              is Directory) {
            result.add(
              entity.path,
            );
          }
        }
      } catch (e) {
        debugPrint(
          'Cannot scan '
          '$rootPath: $e',
        );
      }
    }

    return result;
  }
}