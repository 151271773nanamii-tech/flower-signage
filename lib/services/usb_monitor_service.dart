import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';

import 'physical_usb_device_service.dart';
import 'tag_serial_service.dart';

class UsbMonitorService {
  UsbMonitorService({
    required this.onSerialDetected,
    required this.onTagConnected,
    required this.onTagDisconnected,
    required this.onError,
    this.interval = const Duration(seconds: 1),
    this.disconnectMissThreshold = 3,
  });

  final void Function(String portName) onSerialDetected;
  final void Function(String folderPath) onTagConnected;
  final void Function() onTagDisconnected;
  final void Function(Object error, StackTrace stackTrace) onError;

  final Duration interval;
  final int disconnectMissThreshold;

  Timer? _timer;

  String? _currentTagPath;
  String? _currentTagMac;
  String? _currentSerialPort;

  PhysicalUsbDeviceIdentity? _currentPhysicalDevice;
  Map<String, PhysicalUsbDeviceIdentity> _previousPhysicalSnapshot = {};

  bool _checking = false;
  bool _switchingToStorage = false;

  int _mountMissCount = 0;

  // Safe Eject後、およびエラー後は同じ物理タグを再処理しない。
  bool _waitingForPhysicalRemoval = false;
  bool _errorLock = false;

  // Safe Eject / エラー直後はUSBデバイスがモード切替で一時的に
  // 再列挙されることがある。再列挙が落ち着いてから物理抜線判定を有効化する。
  DateTime? _physicalMonitorStartedAt;
  bool _physicalRemovalArmed = false;

  static const Duration _physicalStabilizeDuration = Duration(seconds: 3);
  static const Duration _physicalAbsentFallbackDuration = Duration(seconds: 6);

  bool get isConnected =>
      _currentTagPath != null || _currentPhysicalDevice != null;

  String? get currentTagPath => _currentTagPath;
  String? get currentTagMac => _currentTagMac;
  String? get currentSerialPort => _currentSerialPort;
  PhysicalUsbDeviceIdentity? get currentPhysicalDevice =>
      _currentPhysicalDevice;

  // ============================================================
  // START / STOP
  // ============================================================

  Future<void> start() async {
    debugPrint('UsbMonitorService START');

    _timer?.cancel();

    _checking = false;
    _switchingToStorage = false;
    _mountMissCount = 0;
    _waitingForPhysicalRemoval = false;
    _errorLock = false;
    _physicalMonitorStartedAt = null;
    _physicalRemovalArmed = false;

    try {
      _previousPhysicalSnapshot = await PhysicalUsbDeviceService.listDevices();
    } catch (e) {
      debugPrint('Initial physical USB snapshot failed: $e');
      _previousPhysicalSnapshot = {};
    }

    _check();

    _timer = Timer.periodic(interval, (_) => _check());
  }

  void stop() {
    debugPrint('UsbMonitorService STOP');

    _timer?.cancel();
    _timer = null;

    _checking = false;
    _switchingToStorage = false;
    _mountMissCount = 0;
    _waitingForPhysicalRemoval = false;
    _errorLock = false;
    _physicalMonitorStartedAt = null;
    _physicalRemovalArmed = false;

    _currentTagPath = null;
    _currentTagMac = null;
    _currentSerialPort = null;
    _currentPhysicalDevice = null;
    _previousPhysicalSnapshot = {};
  }

  // ============================================================
  // NORMAL SAFE EJECT COMPLETE
  //
  // StorageはSafe Ejectで消えるため、ここから先はStorageを見ない。
  // PnP / IORegistry上の物理USBデバイス本体が消えるまで待つ。
  // ============================================================

  void completeSafeEject() {
    debugPrint('UsbMonitorService: completeSafeEject');

    _currentTagPath = null;
    _mountMissCount = 0;

    // 結果表示に入った時点から物理抜線を継続監視する。
    // 1回でも物理USBが存在しないと判定されたら即切断扱いにする。
    _waitingForPhysicalRemoval = true;
    _errorLock = false;
    _physicalMonitorStartedAt = DateTime.now();
    _physicalRemovalArmed = false;

    debugPrint('================================');
    debugPrint('SAFE EJECT COMPLETE');
    debugPrint('PHYSICAL REMOVAL MONITOR START');
    debugPrint('PHYSICAL DEVICE: $_currentPhysicalDevice');
    debugPrint('SERIAL PORT: $_currentSerialPort');
    debugPrint('================================');
  }

  // ============================================================
  // ERROR LOCK
  //
  // エラー後も同じタグを自動再処理しない。
  // 物理USB本体が抜かれるまで監視だけを続ける。
  // ============================================================

  void lockUntilPhysicalRemovalAfterError() {
    debugPrint('UsbMonitorService: lockUntilPhysicalRemovalAfterError');

    _currentTagPath = null;
    _mountMissCount = 0;

    // エラー表示後は同じタグを再処理せず、
    // 物理USBが抜かれるまで継続して監視する。
    // 1回でも不在なら即切断扱いにする。
    _errorLock = true;
    _waitingForPhysicalRemoval = true;
    _physicalMonitorStartedAt = DateTime.now();
    _physicalRemovalArmed = false;

    debugPrint('================================');
    debugPrint('ERROR PHYSICAL REMOVAL MONITOR START');
    debugPrint('PHYSICAL DEVICE: $_currentPhysicalDevice');
    debugPrint('SERIAL PORT: $_currentSerialPort');
    debugPrint('================================');
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
      // --------------------------------------------------------
      // 正常Eject後 / エラー後：物理抜線だけを監視
      // --------------------------------------------------------
      if (_waitingForPhysicalRemoval) {
        await _checkPhysicalRemoval();
        return;
      }

      // --------------------------------------------------------
      // Storage接続確定後、処理完了前：予期せぬ切断を監視
      // --------------------------------------------------------
      if (_currentTagPath != null) {
        await _checkCurrentMount();
        return;
      }

      if (_switchingToStorage) {
        return;
      }

      // --------------------------------------------------------
      // Serial候補を探す
      // --------------------------------------------------------
      final candidates = TagSerialService.findTagPortCandidates();

      if (candidates.isNotEmpty) {
        for (final portName in candidates) {
          final handled = await _trySerialCandidate(portName);
          if (handled) {
            return;
          }
        }
      }

      // --------------------------------------------------------
      // フォールバック：すでにStorageモードで起動したタグ
      // --------------------------------------------------------
      final existingStorage = await _findMountedTagStorage();
      if (existingStorage != null) {
        await _captureFallbackPhysicalDevice();

        // WindowsではSafe Eject後にドライブ文字だけが一時的・幽霊的に
        // 残ることがある。Serialも物理USBも特定できないStorageは
        // 新しいタグ接続として扱わない。
        if (Platform.isWindows &&
            _currentSerialPort == null &&
            _currentPhysicalDevice == null) {
          return;
        }

        await _confirmConnectedStorage(existingStorage);
        return;
      }

      // 待機中snapshotを更新。
      try {
        _previousPhysicalSnapshot =
            await PhysicalUsbDeviceService.listDevices();
      } catch (_) {}
    } catch (e, stackTrace) {
      debugPrint('USB MONITOR ERROR: $e');
      debugPrint('$stackTrace');

      lockUntilPhysicalRemovalAfterError();
      onError(e, stackTrace);
    } finally {
      _checking = false;
    }
  }

  // ============================================================
  // SERIAL CANDIDATE
  //
  // WindowsではTagSerialService側でCOM3 / COM4だけを候補にする。
  // タグプロトコル(TIME/MAC)まで正常に通ったポートだけ採用する。
  // ============================================================

  Future<bool> _trySerialCandidate(String portName) async {
    if (_switchingToStorage) {
      return false;
    }

    _switchingToStorage = true;

    try {
      debugPrint('================================');
      debugPrint('SERIAL CANDIDATE FOUND');
      debugPrint('PORT: $portName');
      debugPrint('================================');

      _currentSerialPort = portName;

      // Serial検出時点で物理USB識別子を確保。
      _currentPhysicalDevice =
          await PhysicalUsbDeviceService.identifyForSerialPort(portName);

      // Windowsでは内蔵COMポート(COM1等)をタグ候補にしない。
      if (Platform.isWindows && _currentPhysicalDevice == null) {
        _currentSerialPort = null;
        return false;
      }

      if (_currentPhysicalDevice == null && Platform.isMacOS) {
        // macOSはIORegistryから直接親USB情報が取れない機種があるため、
        // 挿入前snapshotとの差分で物理USBを補完。
        final current = await PhysicalUsbDeviceService.listDevices();
        final addedKeys = current.keys
            .where((key) => !_previousPhysicalSnapshot.containsKey(key))
            .toList();

        if (addedKeys.length == 1) {
          _currentPhysicalDevice = current[addedKeys.single];
        }

        // アプリ起動時からタグが挿さっていた場合は差分がない。
        // Serialポート名にUSB Serial Numberが含まれていれば対応付ける。
        if (_currentPhysicalDevice == null) {
          final lowerPort = portName.toLowerCase();
          final serialMatches = current.values.where((device) {
            final serial = device.serialNumber?.toLowerCase();
            if (serial == null || serial.isEmpty) return false;
            return lowerPort.contains(serial) || serial.contains(lowerPort);
          }).toList();

          if (serialMatches.length == 1) {
            _currentPhysicalDevice = serialMatches.single;
          }
        }

        // 専用サイネージ等でSerial Numberを持つUSB機器が1台だけなら
        // それを最後のmacOSフォールバックとして採用する。
        if (_currentPhysicalDevice == null) {
          final serialDevices = current.values
              .where(
                (device) =>
                    device.serialNumber != null &&
                    device.serialNumber!.isNotEmpty,
              )
              .toList();

          if (serialDevices.length == 1) {
            _currentPhysicalDevice = serialDevices.single;
          }
        }
      }

      debugPrint('PHYSICAL USB: $_currentPhysicalDevice');

      // USB系のSerialポートであることを確認した時点で
      // UIを「抜かないでください」へ切り替える。
      onSerialDetected(portName);

      final beforeVolumes = await _getMountedStoragePaths();

      try {
        final result = await TagSerialService.initializeTag(portName: portName);

        _currentTagMac = result.macAddress;
        debugPrint('TAG MAC: ${result.macAddress}');
      } catch (e) {
        // WindowsでCOM1等の無関係ポートを試した場合は
        // 他候補へ進める。ただしタグらしいUSB候補をすでに特定できて
        // いる場合は通信失敗として上位へ送る。
        debugPrint('Serial candidate failed: $portName / $e');

        if (_currentPhysicalDevice != null) {
          rethrow;
        }

        _currentSerialPort = null;
        return false;
      }

      debugPrint('Waiting for automatic USB storage mode...');

      // 0x03は送らない。
      // タグが自動でStorageになるのを待つ。
      final storagePath = await _waitForTagStorage(
        beforeVolumes: beforeVolumes,
      );

      if (storagePath == null) {
        throw Exception(
          'Serial通信は成功しましたが、'
          'タグのStorageが見つかりませんでした。',
        );
      }

      final ready = await _waitForFilesystemReady(storagePath);
      if (!ready) {
        throw Exception(
          'USB Storageは認識されましたが、'
          '中身を読み込める状態になりませんでした。\n'
          '$storagePath',
        );
      }

      final valid = await _isTagStorage(storagePath);
      if (!valid) {
        throw Exception(
          'USB Storageは認識されましたが、'
          'BLEタグ用のuser_info.txtが見つかりませんでした。\n'
          '$storagePath',
        );
      }

      await _confirmConnectedStorage(storagePath);
      return true;
    } finally {
      _switchingToStorage = false;
    }
  }

  // ============================================================
  // STORAGE WAIT
  // ============================================================

  Future<String?> _waitForTagStorage({
    required Set<String> beforeVolumes,
  }) async {
    // 最大15秒、200ms間隔。
    // 新規Volumeだけでなく、途中で既存Volumeとして見えるケースも
    // user_info.txt確認によって拾う。
    const waitStep = Duration(milliseconds: 200);
    const maxLoops = 75;

    for (int loop = 1; loop <= maxLoops; loop++) {
      await Future.delayed(waitStep);

      final currentVolumes = await _getMountedStoragePaths();
      final newVolumes = currentVolumes.difference(beforeVolumes);

      if (loop % 5 == 0) {
        debugPrint(
          '[STORAGE WAIT] ${(loop * 0.2).toStringAsFixed(1)} / 15.0 sec',
        );
      }

      // 新しく出たVolumeを優先。
      for (final path in newVolumes) {
        if (await _isTagStorage(path)) {
          debugPrint('[TAG STORAGE FOUND] $path');
          return path;
        }
      }

      // Volume出現直後はuser_infoがまだ見えないことがあるため、
      // 全Volumeからも確認する。
      for (final path in currentVolumes) {
        if (await _isTagStorage(path)) {
          debugPrint('[TAG STORAGE READY] $path');
          return path;
        }
      }
    }

    return null;
  }

  Future<bool> _waitForFilesystemReady(String storagePath) async {
    const waitStep = Duration(milliseconds: 200);
    const maxLoops = 50; // 最大10秒

    for (int retry = 1; retry <= maxLoops; retry++) {
      try {
        final directory = Directory(storagePath);

        if (!await directory.exists()) {
          await Future.delayed(waitStep);
          continue;
        }

        await directory.list(recursive: false, followLinks: false).toList();

        debugPrint(
          '[FILESYSTEM READY] after '
          '${(retry * 0.2).toStringAsFixed(1)} sec',
        );
        return true;
      } catch (e) {
        if (retry % 5 == 0) {
          debugPrint('[FILESYSTEM WAIT] $retry / $maxLoops $e');
        }
      }

      await Future.delayed(waitStep);
    }

    return false;
  }

  // ============================================================
  // STORAGE CONNECTED
  // ============================================================

  Future<void> _confirmConnectedStorage(String storagePath) async {
    if (_waitingForPhysicalRemoval || _errorLock) {
      return;
    }

    if (_currentTagPath != null) {
      return;
    }

    _currentTagPath = storagePath;
    _mountMissCount = 0;

    debugPrint('================================');
    debugPrint('USB TAG CONNECTED');
    debugPrint('PATH: $storagePath');
    debugPrint('MAC: $_currentTagMac');
    debugPrint('PHYSICAL: $_currentPhysicalDevice');
    debugPrint('================================');

    onTagConnected(storagePath);
  }

  // ============================================================
  // PRE-EJECT STORAGE DISCONNECT
  // ============================================================

  Future<void> _checkCurrentMount() async {
    final currentPath = _currentTagPath;
    if (currentPath == null) return;

    bool mountFound = false;

    try {
      mountFound = await Directory(currentPath).exists();
    } catch (e) {
      debugPrint('USB mount check error: $e');
      return;
    }

    if (mountFound) {
      _mountMissCount = 0;
      return;
    }

    _mountMissCount++;

    debugPrint(
      'USB MOUNT MISS: '
      '$_mountMissCount / $disconnectMissThreshold',
    );

    if (_mountMissCount < disconnectMissThreshold) {
      return;
    }

    // Safe Eject前にStorageが消えた場合は予期しない抜線扱い。
    debugPrint('UNEXPECTED STORAGE DISCONNECT');

    _currentTagPath = null;
    _mountMissCount = 0;

    await _notifyPhysicalRemovalAndReset();
  }

  // ============================================================
  // PHYSICAL USB REMOVAL
  // ============================================================

  Future<void> _checkPhysicalRemoval() async {
    final startedAt = _physicalMonitorStartedAt ?? DateTime.now();
    _physicalMonitorStartedAt ??= startedAt;

    bool stillPresent = false;
    bool presenceCheckSucceeded = false;

    // ==========================================================
    // Windows
    // ==========================================================
    // Safe Ejectやタグ内部のUSBモード切替では、COM3/COM4やPnPノードが
    // 一時的に消えて再出現することがある。
    // その瞬間を「物理的に抜いた」とは判定しない。
    //
    // 1) Serialポートが存在すれば「接続中」
    // 2) Serialが一時的に消えていてもPnP側で物理USBが確認できれば「接続中」
    // 3) Safe Eject / エラー直後3秒間は再列挙の安定待ち
    // 4) 3秒経過後に一度「接続中」を確認してから監視をARMする
    // 5) ARM後は1回でも不在なら即座に物理抜線確定
    // 6) 6秒経っても一度も安定接続を確認できない場合は、
    //    本当に抜かれているケースとして抜線確定
    // ==========================================================
    if (Platform.isWindows) {
      final serialPort = _currentSerialPort;

      if (serialPort != null) {
        final normalizedTarget = serialPort.trim().toUpperCase();
        final ports = TagSerialService.availablePorts
            .map((port) => port.trim().toUpperCase())
            .toSet();

        if (ports.contains(normalizedTarget)) {
          stillPresent = true;
          presenceCheckSucceeded = true;
        }
      }

      if (!stillPresent && _currentPhysicalDevice != null) {
        try {
          final pnpPresent = await PhysicalUsbDeviceService.isPresent(
            _currentPhysicalDevice!,
          );
          presenceCheckSucceeded = true;
          if (pnpPresent) {
            stillPresent = true;
          }
        } catch (e) {
          debugPrint('Physical USB presence check error: $e');
        }
      }
    } else {
      final physical = _currentPhysicalDevice;

      if (physical != null) {
        try {
          stillPresent = await PhysicalUsbDeviceService.isPresent(physical);
          presenceCheckSucceeded = true;
        } catch (e) {
          debugPrint('Physical USB presence check error: $e');
          return;
        }
      } else {
        try {
          final current = await PhysicalUsbDeviceService.listDevices();
          final added = current.keys
              .where((key) => !_previousPhysicalSnapshot.containsKey(key))
              .toList();
          stillPresent = added.isNotEmpty;
          presenceCheckSucceeded = true;
        } catch (e) {
          debugPrint('Physical USB fallback check error: $e');
          return;
        }
      }
    }

    if (!presenceCheckSucceeded) {
      return;
    }

    final elapsed = DateTime.now().difference(startedAt);

    // Safe Eject / エラー直後のUSB再列挙中は、不在を抜線扱いしない。
    if (elapsed < _physicalStabilizeDuration) {
      return;
    }

    // 再列挙後に一度でも存在を確認できた時点で、物理抜線監視を有効化。
    if (!_physicalRemovalArmed) {
      if (stillPresent) {
        _physicalRemovalArmed = true;
        debugPrint('PHYSICAL REMOVAL MONITOR ARMED');
        return;
      }

      // ずっと不在のままなら、実際に抜かれた可能性が高い。
      // 6秒まで待ってから1回だけ抜線確定する。
      if (elapsed < _physicalAbsentFallbackDuration) {
        return;
      }

      debugPrint('[PHYSICAL REMOVE] detected');
      await _notifyPhysicalRemovalAndReset();
      return;
    }

    // ARM後はユーザー要望どおり、1回でも不在なら即抜線確定。
    if (!stillPresent) {
      debugPrint('[PHYSICAL REMOVE] detected');
      await _notifyPhysicalRemovalAndReset();
    }
  }

  Future<void> _notifyPhysicalRemovalAndReset() async {
    debugPrint('================================');
    debugPrint('PHYSICAL USB TAG REMOVED');
    debugPrint('================================');

    _currentTagPath = null;
    _currentTagMac = null;
    _currentSerialPort = null;
    _currentPhysicalDevice = null;

    _mountMissCount = 0;
    _switchingToStorage = false;
    _waitingForPhysicalRemoval = false;
    _errorLock = false;
    _physicalMonitorStartedAt = null;
    _physicalRemovalArmed = false;

    try {
      _previousPhysicalSnapshot = await PhysicalUsbDeviceService.listDevices();
    } catch (_) {
      _previousPhysicalSnapshot = {};
    }

    onTagDisconnected();
  }

  // ============================================================
  // STORAGE SEARCH
  // ============================================================

  Future<String?> _findMountedTagStorage() async {
    if (_waitingForPhysicalRemoval || _errorLock) {
      return null;
    }

    final paths = await _getMountedStoragePaths();

    for (final path in paths) {
      try {
        if (await _isTagStorage(path)) {
          return path;
        }
      } catch (_) {}
    }

    return null;
  }

  Future<bool> _isTagStorage(String folderPath) async {
    final separator = Platform.isWindows ? '\\' : '/';

    const candidates = <String>[
      'user_info.txt',
      'USER_INFO.TXT',
      'User_Info.txt',
    ];

    for (final fileName in candidates) {
      final path = '$folderPath$separator$fileName';

      try {
        if (await File(path).exists()) {
          return true;
        }
      } catch (_) {}
    }

    return false;
  }

  Future<void> _captureFallbackPhysicalDevice() async {
    if (_currentPhysicalDevice != null) {
      return;
    }

    final current = await PhysicalUsbDeviceService.listDevices();
    final addedKeys = current.keys
        .where((key) => !_previousPhysicalSnapshot.containsKey(key))
        .toList();

    if (addedKeys.length == 1) {
      _currentPhysicalDevice = current[addedKeys.single];
      debugPrint('Fallback physical USB captured: $_currentPhysicalDevice');
    }
  }

  // ============================================================
  // MOUNT LIST
  // ============================================================

  Future<Set<String>> _getMountedStoragePaths() async {
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

  Future<Set<String>> _getMacVolumes() async {
    final result = <String>{};
    final root = Directory('/Volumes');

    if (!await root.exists()) {
      return result;
    }

    try {
      final entities = await root
          .list(recursive: false, followLinks: false)
          .toList();

      for (final entity in entities) {
        if (entity is! Directory) continue;
        if (entity.path == '/Volumes/Macintosh HD') continue;
        result.add(entity.path);
      }
    } catch (e) {
      debugPrint('Cannot scan /Volumes: $e');
    }

    return result;
  }

  Future<Set<String>> _getWindowsVolumes() async {
    final result = <String>{};

    for (int code = 68; code <= 90; code++) {
      final drive = '${String.fromCharCode(code)}:\\';

      try {
        if (await Directory(drive).exists()) {
          result.add(drive);
        }
      } catch (_) {}
    }

    return result;
  }

  Future<Set<String>> _getLinuxVolumes() async {
    final result = <String>{};
    final roots = <String>[];

    final home = Platform.environment['HOME'];
    if (home != null) {
      final parts = home.split('/').where((part) => part.isNotEmpty).toList();

      if (parts.isNotEmpty) {
        roots.add('/media/${parts.last}');
      }
    }

    roots.addAll(<String>['/media', '/mnt']);

    final checked = <String>{};

    for (final rootPath in roots) {
      if (!checked.add(rootPath)) continue;

      final root = Directory(rootPath);
      if (!await root.exists()) continue;

      try {
        final entities = await root
            .list(recursive: false, followLinks: false)
            .toList();

        for (final entity in entities) {
          if (entity is Directory) {
            result.add(entity.path);
          }
        }
      } catch (e) {
        debugPrint('Cannot scan $rootPath: $e');
      }
    }

    return result;
  }
}
