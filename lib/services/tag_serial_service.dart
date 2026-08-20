import 'dart:io';
// import 'dart:typed_data';

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

  // ============================================================
  // 利用可能ポート
  // ============================================================

  static List<String> get availablePorts {
    return SerialPort.availablePorts;
  }

  // ============================================================
  // BLEタグらしいシリアルポートを探す
  //
  // 今はmacOS実機で確認できた名前を優先。
  // Windows/Linux対応は後でこの部分を拡張する。
  // ============================================================

  static String? findTagPort() {
    final ports = SerialPort.availablePorts;

    debugPrint(
      'Serial ports: $ports',
    );

    if (ports.isEmpty) {
      return null;
    }

    if (Platform.isMacOS) {
      for (final portName in ports) {
        final lower =
            portName.toLowerCase();

        if (lower.contains(
              'usbserial',
            ) ||
            lower.contains(
              'usbmodem',
            )) {
          return portName;
        }
      }

      return null;
    }

    if (Platform.isLinux) {
      for (final portName in ports) {
        final lower =
            portName.toLowerCase();

        if (lower.contains(
              'ttyusb',
            ) ||
            lower.contains(
              'ttyacm',
            )) {
          return portName;
        }
      }

      return null;
    }

    if (Platform.isWindows) {
      // WindowsはCOMポート名だけでは
      // タグを一意に特定できないため、
      // 後で安全なプロトコル確認を追加する。
      return ports.firstOrNull;
    }

    return null;
  }

  // ============================================================
  // 初期化シーケンス
  //
  // TIME SYNC
  // ↓
  // MAC REQUEST
  // ↓
  // USB STORAGE REQUEST
  //
  // USB Storage切替後はポート自体が消えることがある。
  // ============================================================

  static Future<TagSerialResult> initializeTag({
    required String portName,
  }) async {
    final port =
        SerialPort(
      portName,
    );

    // SerialPortConfig? config;

    try {
      if (!port.openReadWrite()) {
        throw Exception(
          'シリアルポートを'
          '開けませんでした。\n'
          'port: $portName\n'
          'error: '
          '${SerialPort.lastError}',
        );
      }

      final config = SerialPortConfig();

      config.baudRate =
          baudRate;

      config.bits =
          8;

      config.stopBits =
          1;

      config.parity =
          SerialPortParity.none;

      config.setFlowControl(
        SerialPortFlowControl.none,
      );

      port.config =
          config;

      debugPrint(
        'Serial opened: '
        '$portName',
      );

      await Future.delayed(
        const Duration(
          milliseconds: 300,
        ),
      );

      // ========================================================
      // 1. TIME SYNC
      // ========================================================

      await _timeSync(
        port,
      );

      await Future.delayed(
        const Duration(
          milliseconds: 300,
        ),
      );

      // ========================================================
      // 2. MAC
      // ========================================================

      final macAddress =
          await _readMac(
        port,
      );

      await Future.delayed(
        const Duration(
          milliseconds: 300,
        ),
      );

      // ========================================================
      // 3. USB STORAGE
      // ========================================================

      await _requestUsbStorage(
        port,
      );

      return TagSerialResult(
        portName:
            portName,
        macAddress:
            macAddress,
      );
    } finally {
      // USB Storage切替後はデバイス自体が消えるため、
      // libserialportのclose/disposeが競合する可能性がある。
      //
      // まず実機確認のため、ここでは明示的なdisposeを行わない。
      debugPrint(
        'Serial cleanup skipped after storage switch',
      );
    }
  }

  // ============================================================
  // TIME SYNC
  // ============================================================

  static Future<void> _timeSync(
    SerialPort port,
  ) async {
    final now =
        DateTime.now();

    final year =
        now.year - 2000;

    if (year < 0 ||
        year > 255) {
      throw Exception(
        'タグへ設定できない'
        '年です。\n'
        'year: ${now.year}',
      );
    }

    final payload =
        <int>[
      year,
      now.month,
      now.day,
      now.hour,
      now.minute,
      now.second,
    ];

    final packet =
        _makePacket(
      command:
          0x01,
      payload:
          payload,
    );

    debugPrint(
      'TIME TX: '
      '${_hex(packet)}',
    );

    _writePacket(
      port,
      packet,
    );

    await Future.delayed(
      const Duration(
        milliseconds: 500,
      ),
    );

    final response =
        _readPacket(
      port,
    );

    debugPrint(
      'TIME RX: '
      '${_hex(response)}',
    );

    _validateHeader(
      response,
      expectedCommand:
          0xA1,
    );

    final status =
        response[4];

    if (status != 0) {
      throw Exception(
        'TIME SYNCに'
        '失敗しました。\n'
        'status: '
        '0x${status.toRadixString(16).padLeft(2, '0')}',
      );
    }

    debugPrint(
      'TIME SYNC SUCCESS',
    );
  }

  // ============================================================
  // MAC REQUEST
  //
  // A2応答のbyte 4〜9がMACアドレス
  // ============================================================

  static Future<String> _readMac(
    SerialPort port,
  ) async {
    final packet =
        _makePacket(
      command:
          0x02,
    );

    debugPrint(
      'MAC TX: '
      '${_hex(packet)}',
    );

    _writePacket(
      port,
      packet,
    );

    await Future.delayed(
      const Duration(
        milliseconds: 500,
      ),
    );

    final response =
        _readPacket(
      port,
    );

    debugPrint(
      'MAC RX: '
      '${_hex(response)}',
    );

    _validateHeader(
      response,
      expectedCommand:
          0xA2,
    );

    final macBytes =
        response.sublist(
      4,
      10,
    );

    final mac =
        macBytes
            .map(
              (value) =>
                  value
                      .toRadixString(
                        16,
                      )
                      .padLeft(
                        2,
                        '0',
                      )
                      .toUpperCase(),
            )
            .join(':');

    debugPrint(
      'TAG MAC: $mac',
    );

    return mac;
  }

  // ============================================================
  // USB STORAGE
  //
  // 成功するとシリアルポートが消えるため、
  // 応答が返らなくても異常とは限らない。
  // ============================================================

  static Future<void> _requestUsbStorage(
    SerialPort port,
  ) async {
    final packet =
        _makePacket(
      command:
          0x03,
    );

    debugPrint(
      'STORAGE TX: '
      '${_hex(packet)}',
    );

    _writePacket(
      port,
      packet,
    );

    debugPrint(
      'USB STORAGE REQUEST SENT',
    );

    // ここでは応答を待たない。
    //
    // Python実機試験で
    // Storage切替成功時に
    // シリアルデバイス自体が消えることを確認済み。
  }

  // ============================================================
  // PACKET
  //
  // 12 bytes
  //
  // A5 FA
  // 09
  // command
  // payload 6byte
  // CRC16 2byte little endian
  // ============================================================

  static Uint8List _makePacket({
    required int command,
    List<int>? payload,
  }) {
    final actualPayload =
        payload ??
            List<int>.filled(
              6,
              0,
            );

    if (actualPayload.length !=
        6) {
      throw ArgumentError(
        'payloadは6byte'
        '必要です。',
      );
    }

    final first10 =
        <int>[
      0xA5,
      0xFA,
      0x09,
      command,
      ...actualPayload,
    ];

    final crc =
        _crc16Ccitt(
      first10,
    );

    return Uint8List.fromList(
      [
        ...first10,

        // little endian
        crc & 0xFF,
        (crc >> 8) & 0xFF,
      ],
    );
  }

  // ============================================================
  // CRC-16/CCITT
  //
  // polynomial = 0x1021
  // initial    = 0x0000
  // ============================================================

  static int _crc16Ccitt(
    List<int> data,
  ) {
    int crc =
        0x0000;

    for (final byte
        in data) {
      crc ^=
          byte << 8;

      for (
        int i = 0;
        i < 8;
        i++
      ) {
        if ((crc & 0x8000) !=
            0) {
          crc =
              ((crc << 1) ^
                      0x1021) &
                  0xFFFF;
        } else {
          crc =
              (crc << 1) &
                  0xFFFF;
        }
      }
    }

    return crc;
  }

  // ============================================================
  // WRITE
  // ============================================================

  static void _writePacket(
    SerialPort port,
    Uint8List packet,
  ) {
    final written =
        port.write(
      packet,
      timeout:
          2000,
    );

    if (written !=
        packet.length) {
      throw Exception(
        'シリアル送信に'
        '失敗しました。\n'
        'expected: '
        '${packet.length}\n'
        'written: '
        '$written',
      );
    }

    port.drain();
  }

  // ============================================================
  // READ
  // ============================================================

  static Uint8List _readPacket(
    SerialPort port,
  ) {
    final data =
        port.read(
      _packetLength,
      timeout:
          2000,
    );

    if (data.length !=
        _packetLength) {
      throw Exception(
        'タグからの応答が'
        '不完全です。\n'
        'expected: '
        '$_packetLength bytes\n'
        'received: '
        '${data.length} bytes',
      );
    }

    return data;
  }

  // ============================================================
  // RESPONSE VALIDATION
  // ============================================================

  static void _validateHeader(
    Uint8List response, {
    required int expectedCommand,
  }) {
    if (response.length !=
        _packetLength) {
      throw Exception(
        'タグ応答長が'
        '不正です。',
      );
    }

    if (response[0] !=
            0xA5 ||
        response[1] !=
            0xFA ||
        response[2] !=
            0x09 ||
        response[3] !=
            expectedCommand) {
      throw Exception(
        'タグから想定外の'
        '応答を受信しました。\n'
        'RX: ${_hex(response)}',
      );
    }

    // ----------------------------------------------------------
    // CRC確認
    // ----------------------------------------------------------

    final calculatedCrc =
        _crc16Ccitt(
      response.sublist(
        0,
        10,
      ),
    );

    final receivedCrc =
        response[10] |
            (response[11]
                << 8);

    if (calculatedCrc !=
        receivedCrc) {
      throw Exception(
        'タグ応答のCRCが'
        '一致しません。\n'
        'RX: ${_hex(response)}',
      );
    }
  }

  // ============================================================
  // HEX
  // ============================================================

  static String _hex(
    List<int> data,
  ) {
    return data
        .map(
          (value) =>
              value
                  .toRadixString(
                    16,
                  )
                  .padLeft(
                    2,
                    '0',
                  )
                  .toUpperCase(),
        )
        .join(' ');
  }
}

// ============================================================
// Dart 3以前でも使えるように補助
// ============================================================

extension _FirstOrNullExtension<T>
    on List<T> {
  T? get firstOrNull {
    if (isEmpty) {
      return null;
    }

    return first;
  }
}