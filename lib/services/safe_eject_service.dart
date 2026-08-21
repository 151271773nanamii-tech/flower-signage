import 'dart:io';

import 'package:flutter/foundation.dart';

class SafeEjectService {
  // ============================================================
  // PUBLIC
  // ============================================================

  static Future<void> eject(
    String volumePath,
  ) async {
    if (Platform.isMacOS) {
      await _ejectMacOS(
        volumePath,
      );

      return;
    }

    if (Platform.isWindows) {
      await _ejectWindows(
        volumePath,
      );

      return;
    }

    if (Platform.isLinux) {
      await _ejectLinux(
        volumePath,
      );

      return;
    }

    throw UnsupportedError(
      'このOSではUSBの安全な取り外しに'
      '対応していません。',
    );
  }

  // ============================================================
  // macOS
  // ============================================================

  static Future<void> _ejectMacOS(
    String volumePath,
  ) async {
    debugPrint(
      '[EJECT] macOS START: $volumePath',
    );

    final result =
        await Process.run(
      'diskutil',
      [
        'eject',
        volumePath,
      ],
    );

    if (result.exitCode != 0) {
      throw Exception(
        'USBの安全な取り外しに'
        '失敗しました。\n'
        '${result.stderr}',
      );
    }

    debugPrint(
      '[EJECT] macOS SUCCESS',
    );
  }

  // ============================================================
  // Windows
  // ============================================================

  static Future<void> _ejectWindows(
    String volumePath,
  ) async {
    debugPrint(
      '[EJECT] Windows START: $volumePath',
    );

    final driveLetter =
        _extractWindowsDriveLetter(
      volumePath,
    );

    final script = '''
\$drive = New-Object -comObject Shell.Application
\$drive.Namespace(17).ParseName('$driveLetter').InvokeVerb('Eject')
''';

    final result =
        await Process.run(
      'powershell',
      [
        '-NoProfile',
        '-NonInteractive',
        '-Command',
        script,
      ],
    );

    if (result.exitCode != 0) {
      throw Exception(
        'USBの安全な取り外しに'
        '失敗しました。\n'
        '${result.stderr}',
      );
    }

    debugPrint(
      '[EJECT] Windows command completed',
    );
  }

  // ============================================================
  // Linux
  // ============================================================

  static Future<void> _ejectLinux(
    String volumePath,
  ) async {
    debugPrint(
      '[EJECT] Linux START: $volumePath',
    );

    final sourceResult =
        await Process.run(
      'findmnt',
      [
        '-n',
        '-o',
        'SOURCE',
        '--target',
        volumePath,
      ],
    );

    if (sourceResult.exitCode != 0) {
      throw Exception(
        'USBデバイスを特定できませんでした。\n'
        '${sourceResult.stderr}',
      );
    }

    final device =
        sourceResult.stdout
            .toString()
            .trim();

    if (device.isEmpty) {
      throw Exception(
        'USBデバイス名が空です。',
      );
    }

    final unmountResult =
        await Process.run(
      'udisksctl',
      [
        'unmount',
        '-b',
        device,
      ],
    );

    if (unmountResult.exitCode != 0) {
      throw Exception(
        'USBのアンマウントに'
        '失敗しました。\n'
        '${unmountResult.stderr}',
      );
    }

    debugPrint(
      '[EJECT] Linux SUCCESS',
    );
  }

  // ============================================================
  // WINDOWS DRIVE
  // ============================================================

  static String _extractWindowsDriveLetter(
    String volumePath,
  ) {
    final normalized =
        volumePath.trim();

    if (normalized.length < 2 ||
        normalized[1] != ':') {
      throw Exception(
        'Windowsのドライブパスが'
        '不正です。\n'
        '$volumePath',
      );
    }

    return normalized.substring(
      0,
      2,
    );
  }
}