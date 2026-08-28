import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_libserialport/flutter_libserialport.dart';

class TagSerialResult {
  final String portName;
  final String macAddress;

  const TagSerialResult({
    required this.portName,
    required this.macAddress,
  });
}

class TagSerialService {
  static const int baudRate = 115200;
  static const int _packetLength = 12;

  // 固定500ms待機を廃止し、応答readのtimeoutで待つ。
  // 正常時は応答が来た時点で即次へ進む。
  static const int _responseTimeoutMs = 350;
  static const int _writeTimeoutMs = 1000;
  static const int _maxAttempts = 3;
  static const Duration _openSettleDelay = Duration(milliseconds: 100);
  static const Duration _retryGap = Duration(milliseconds: 80);

  static List<String> get availablePorts => SerialPort.availablePorts;

  // ============================================================
  // TAG PORT CANDIDATES
  // ============================================================

  static List<String> findTagPortCandidates() {
    final ports = SerialPort.availablePorts;

    debugPrint('Serial ports: $ports');

    if (ports.isEmpty) {
      return const <String>[];
    }

    if (Platform.isMacOS) {
      return ports.where((portName) {
        final lower = portName.toLowerCase();
        return lower.contains('usbserial') ||
            lower.contains('usbmodem') ||
            lower.contains('wchusbserial') ||
            lower.contains('slab_usbtoUART'.toLowerCase());
      }).toList();
    }

    if (Platform.isLinux) {
      return ports.where((portName) {
        final lower = portName.toLowerCase();
        return lower.contains('ttyusb') || lower.contains('ttyacm');
      }).toList();
    }

    if (Platform.isWindows) {
      // ========================================================
      // Windows
      //
      // BLEタグはCOM3 / COM4に対応する。
      // COM3・COM4以外のCOMポートにはアクセスしない。
      // ========================================================

      const allowedPorts = <String>[
        'COM3',
        'COM4',
      ];

      final candidates = ports
          .where(
            (portName) => allowedPorts.contains(
              portName.trim().toUpperCase(),
            ),
          )
          .map(
            (portName) => portName.trim().toUpperCase(),
          )
          .toList();

      return candidates;
    }

    return const <String>[];
  }

  static String? findTagPort() {
    final candidates = findTagPortCandidates();
    return candidates.isEmpty ? null : candidates.first;
  }

  // ============================================================
  // INITIALIZE
  //
  // 0x03 USB STORAGE REQUESTは送らない。
  // タグ側が自動的にStorageへ遷移する前提。
  // ============================================================

  static Future<TagSerialResult> initializeTag({
    required String portName,
  }) async {
    final port = SerialPort(portName);

    try {
      if (!port.openReadWrite()) {
        throw Exception(
          'シリアルポートを開けませんでした。\n'
          'port: $portName\n'
          'error: ${SerialPort.lastError}',
        );
      }

      final config = SerialPortConfig();
      config.baudRate = baudRate;
      config.bits = 8;
      config.stopBits = 1;
      config.parity = SerialPortParity.none;
      config.setFlowControl(SerialPortFlowControl.none);
      port.config = config;

      debugPrint('Serial opened: $portName');

      await Future.delayed(_openSettleDelay);

      await _timeSyncWithRetry(port);
      final macAddress = await _readMacWithRetry(port);

      return TagSerialResult(
        portName: portName,
        macAddress: macAddress,
      );
    } finally {
      try {
        port.close();
      } catch (e) {
        debugPrint('Serial close warning: $e');
      }

      try {
        port.dispose();
      } catch (e) {
        debugPrint('Serial dispose warning: $e');
      }
    }
  }

  // ============================================================
  // TIME SYNC - MAX 3 ATTEMPTS
  // ============================================================

  static Future<void> _timeSyncWithRetry(SerialPort port) async {
    Object? lastError;

    for (int attempt = 1; attempt <= _maxAttempts; attempt++) {
      try {
        debugPrint('TIME SYNC attempt $attempt / $_maxAttempts');
        await _timeSyncOnce(port);
        debugPrint('TIME SYNC SUCCESS');
        return;
      } catch (e) {
        lastError = e;
        debugPrint('TIME SYNC attempt $attempt failed: $e');

        if (attempt < _maxAttempts) {
          await Future.delayed(_retryGap);
        }
      }
    }

    throw Exception(
      'TIME SYNCに$_maxAttempts回失敗しました。\n'
      '最後のエラー: $lastError',
    );
  }

  static Future<void> _timeSyncOnce(SerialPort port) async {
    final now = DateTime.now();
    final year = now.year - 2000;

    if (year < 0 || year > 255) {
      throw Exception(
        'タグへ設定できない年です。\n'
        'year: ${now.year}',
      );
    }

    final packet = _makePacket(
      command: 0x01,
      payload: <int>[
        year,
        now.month,
        now.day,
        now.hour,
        now.minute,
        now.second,
      ],
    );

    debugPrint('TIME TX: ${_hex(packet)}');
    _writePacket(port, packet);

    final response = _readPacket(port);
    debugPrint('TIME RX: ${_hex(response)}');

    _validateHeader(
      response,
      expectedCommand: 0xA1,
    );

    final status = response[4];
    if (status != 0) {
      throw Exception(
        'TIME SYNC status error: '
        '0x${status.toRadixString(16).padLeft(2, '0')}',
      );
    }
  }

  // ============================================================
  // MAC REQUEST - MAX 3 ATTEMPTS
  // ============================================================

  static Future<String> _readMacWithRetry(SerialPort port) async {
    Object? lastError;

    for (int attempt = 1; attempt <= _maxAttempts; attempt++) {
      try {
        debugPrint('MAC REQUEST attempt $attempt / $_maxAttempts');
        final mac = _readMacOnce(port);
        debugPrint('MAC REQUEST SUCCESS: $mac');
        return mac;
      } catch (e) {
        lastError = e;
        debugPrint('MAC REQUEST attempt $attempt failed: $e');

        if (attempt < _maxAttempts) {
          await Future.delayed(_retryGap);
        }
      }
    }

    throw Exception(
      'MAC REQUESTに$_maxAttempts回失敗しました。\n'
      '最後のエラー: $lastError',
    );
  }

  static String _readMacOnce(SerialPort port) {
    final packet = _makePacket(command: 0x02);

    debugPrint('MAC TX: ${_hex(packet)}');
    _writePacket(port, packet);

    final response = _readPacket(port);
    debugPrint('MAC RX: ${_hex(response)}');

    _validateHeader(
      response,
      expectedCommand: 0xA2,
    );

    final macBytes = response.sublist(4, 10);
    return macBytes
        .map(
          (value) => value
              .toRadixString(16)
              .padLeft(2, '0')
              .toUpperCase(),
        )
        .join(':');
  }

  // ============================================================
  // PACKET
  // ============================================================

  static Uint8List _makePacket({
    required int command,
    List<int>? payload,
  }) {
    final actualPayload = payload ?? List<int>.filled(6, 0);

    if (actualPayload.length != 6) {
      throw ArgumentError('payloadは6byte必要です。');
    }

    final first10 = <int>[
      0xA5,
      0xFA,
      0x09,
      command,
      ...actualPayload,
    ];

    final crc = _crc16Ccitt(first10);

    return Uint8List.fromList(<int>[
      ...first10,
      crc & 0xFF,
      (crc >> 8) & 0xFF,
    ]);
  }

  static int _crc16Ccitt(List<int> data) {
    int crc = 0x0000;

    for (final byte in data) {
      crc ^= byte << 8;

      for (int i = 0; i < 8; i++) {
        if ((crc & 0x8000) != 0) {
          crc = ((crc << 1) ^ 0x1021) & 0xFFFF;
        } else {
          crc = (crc << 1) & 0xFFFF;
        }
      }
    }

    return crc;
  }

  // ============================================================
  // WRITE / READ
  // ============================================================

  static void _writePacket(
    SerialPort port,
    Uint8List packet,
  ) {
    final written = port.write(
      packet,
      timeout: _writeTimeoutMs,
    );

    if (written != packet.length) {
      throw Exception(
        'シリアル送信に失敗しました。\n'
        'expected: ${packet.length}\n'
        'written: $written',
      );
    }

    port.drain();
  }

  static Uint8List _readPacket(SerialPort port) {
    final data = port.read(
      _packetLength,
      timeout: _responseTimeoutMs,
    );

    if (data.length != _packetLength) {
      throw Exception(
        'タグからの応答が不完全です。\n'
        'expected: $_packetLength bytes\n'
        'received: ${data.length} bytes',
      );
    }

    return data;
  }

  // ============================================================
  // VALIDATION
  // ============================================================

  static void _validateHeader(
    Uint8List response, {
    required int expectedCommand,
  }) {
    if (response.length != _packetLength) {
      throw Exception('タグ応答長が不正です。');
    }

    if (response[0] != 0xA5 ||
        response[1] != 0xFA ||
        response[2] != 0x09 ||
        response[3] != expectedCommand) {
      throw Exception(
        'タグから想定外の応答を受信しました。\n'
        'expected command: '
        '0x${expectedCommand.toRadixString(16).toUpperCase()}\n'
        'RX: ${_hex(response)}',
      );
    }

    final calculatedCrc = _crc16Ccitt(response.sublist(0, 10));
    final receivedCrc = response[10] | (response[11] << 8);

    if (calculatedCrc != receivedCrc) {
      throw Exception(
        'タグ応答のCRCが一致しません。\n'
        'RX: ${_hex(response)}',
      );
    }
  }

  static String _hex(List<int> data) {
    return data
        .map(
          (value) => value
              .toRadixString(16)
              .padLeft(2, '0')
              .toUpperCase(),
        )
        .join(' ');
  }
}
