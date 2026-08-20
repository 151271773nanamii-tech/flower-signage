import 'package:flutter/material.dart';

import 'services/tag_serial_service.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  debugPrint('================================');
  debugPrint('TAG SERIAL TEST START');
  debugPrint('================================');

  final portName =
      TagSerialService.findTagPort();

  if (portName == null) {
    debugPrint(
      'ERROR: BLEタグの'
      'シリアルポートが見つかりません。',
    );

    return;
  }

  debugPrint(
    'TAG PORT FOUND: $portName',
  );

  try {
    final result =
        await TagSerialService.initializeTag(
      portName: portName,
    );

    debugPrint(
      '================================',
    );

    debugPrint(
      'TAG INITIALIZE SUCCESS',
    );

    debugPrint(
      'PORT: ${result.portName}',
    );

    debugPrint(
      'MAC: ${result.macAddress}',
    );

    debugPrint(
      '================================',
    );
  } catch (e, stackTrace) {
    debugPrint(
      'TAG INITIALIZE ERROR: $e',
    );

    debugPrint(
      '$stackTrace',
    );
  }
}