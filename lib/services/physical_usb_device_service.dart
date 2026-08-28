import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';

class PhysicalUsbDeviceIdentity {
  final String platform;
  final String key;
  final String? label;
  final String? vendorId;
  final String? productId;
  final String? serialNumber;
  final String? containerId;

  const PhysicalUsbDeviceIdentity({
    required this.platform,
    required this.key,
    this.label,
    this.vendorId,
    this.productId,
    this.serialNumber,
    this.containerId,
  });

  @override
  String toString() {
    return 'PhysicalUsbDeviceIdentity('
        'platform=$platform, '
        'key=$key, '
        'label=$label, '
        'vid=$vendorId, '
        'pid=$productId, '
        'serial=$serialNumber, '
        'containerId=$containerId)';
  }
}

class PhysicalUsbDeviceService {
  // ============================================================
  // SERIAL PORT -> PHYSICAL USB DEVICE
  // ============================================================

  static Future<PhysicalUsbDeviceIdentity?> identifyForSerialPort(
    String portName,
  ) async {
    if (Platform.isWindows) {
      return _identifyWindowsForSerialPort(portName);
    }

    if (Platform.isMacOS) {
      return _identifyMacForSerialPort(portName);
    }

    if (Platform.isLinux) {
      return _identifyLinuxForSerialPort(portName);
    }

    return null;
  }

  // ============================================================
  // PRESENCE CHECK
  // ============================================================

  static Future<bool> isPresent(PhysicalUsbDeviceIdentity identity) async {
    if (identity.platform == 'windows') {
      return _isPresentWindows(identity);
    }

    if (identity.platform == 'macos') {
      return _isPresentMac(identity);
    }

    if (identity.platform == 'linux') {
      return _isPresentLinux(identity);
    }

    return false;
  }

  // ============================================================
  // USB DEVICE SNAPSHOT
  //
  // macOSでSerialポートから物理USBを一意に引けない場合の
  // フォールバックにも使用する。
  // ============================================================

  static Future<Map<String, PhysicalUsbDeviceIdentity>> listDevices() async {
    if (Platform.isWindows) {
      return _listWindowsDevices();
    }

    if (Platform.isMacOS) {
      return _listMacDevices();
    }

    if (Platform.isLinux) {
      return _listLinuxDevices();
    }

    return <String, PhysicalUsbDeviceIdentity>{};
  }

  // ============================================================
  // WINDOWS
  // ============================================================

  static Future<PhysicalUsbDeviceIdentity?> _identifyWindowsForSerialPort(
    String portName,
  ) async {
    final escapedPort = portName.replaceAll("'", "''");

    final script =
        r'''
$ErrorActionPreference = 'Stop'
$portName = '__PORT__'
$dev = Get-PnpDevice -PresentOnly | Where-Object {
  $_.FriendlyName -like "*($portName)*" -or $_.Name -like "*($portName)*"
} | Select-Object -First 1

if ($null -eq $dev) {
  exit 0
}

$container = $null
try {
  $container = (Get-PnpDeviceProperty -InstanceId $dev.InstanceId -KeyName 'DEVPKEY_Device_ContainerId' -ErrorAction Stop).Data
} catch {}

$vid = $null
$usbPid = $null
if ($dev.InstanceId -match 'VID_([0-9A-Fa-f]{4})') { $vid = $Matches[1].ToUpper() }
if ($dev.InstanceId -match 'PID_([0-9A-Fa-f]{4})') { $usbPid = $Matches[1].ToUpper() }

[pscustomobject]@{
  InstanceId = $dev.InstanceId
  FriendlyName = $dev.FriendlyName
  ContainerId = if ($null -ne $container) { $container.ToString() } else { $null }
  VID = $vid
  PID = $usbPid
} | ConvertTo-Json -Compress
'''
            .replaceFirst('__PORT__', escapedPort);

    final result = await Process.run('powershell', [
      '-NoProfile',
      '-NonInteractive',
      '-ExecutionPolicy',
      'Bypass',
      '-Command',
      script,
    ]);

    if (result.exitCode != 0) {
      debugPrint('[USB DEVICE] Windows identify failed: ${result.stderr}');
      return null;
    }

    final output = result.stdout.toString().trim();
    if (output.isEmpty) {
      return null;
    }

    try {
      final json = jsonDecode(output) as Map<String, dynamic>;
      final instanceId = json['InstanceId']?.toString();
      final containerId = json['ContainerId']?.toString();

      if (instanceId == null) {
        return null;
      }

      final upperInstanceId = instanceId.toUpperCase();
      final looksLikeUsb =
          upperInstanceId.startsWith('USB\\') ||
          upperInstanceId.startsWith('FTDIBUS\\') ||
          upperInstanceId.contains('VID_');

      if (!looksLikeUsb) {
        return null;
      }

      final key = (containerId != null && containerId.isNotEmpty)
          ? 'container:$containerId'
          : 'instance:$instanceId';

      return PhysicalUsbDeviceIdentity(
        platform: 'windows',
        key: key,
        label: json['FriendlyName']?.toString(),
        vendorId: json['VID']?.toString(),
        productId: json['PID']?.toString(),
        containerId: containerId,
      );
    } catch (e) {
      debugPrint('[USB DEVICE] Windows JSON parse failed: $e');
      return null;
    }
  }

  static Future<bool> _isPresentWindows(
    PhysicalUsbDeviceIdentity identity,
  ) async {
    final containerId = identity.containerId;

    if (containerId != null && containerId.isNotEmpty) {
      final escaped = containerId.replaceAll("'", "''");
      final script =
          r'''
$ErrorActionPreference = 'SilentlyContinue'
$target = '__CONTAINER__'
$present = Get-PnpDevice -PresentOnly | ForEach-Object {
  try {
    $c = (Get-PnpDeviceProperty -InstanceId $_.InstanceId -KeyName 'DEVPKEY_Device_ContainerId' -ErrorAction Stop).Data
    if ($null -ne $c -and $c.ToString() -eq $target) { $_ }
  } catch {}
} | Select-Object -First 1
if ($null -ne $present) { '1' } else { '0' }
'''
              .replaceFirst('__CONTAINER__', escaped);

      final result = await Process.run('powershell', [
        '-NoProfile',
        '-NonInteractive',
        '-ExecutionPolicy',
        'Bypass',
        '-Command',
        script,
      ]);

      return result.exitCode == 0 && result.stdout.toString().trim() == '1';
    }

    final instanceKey = identity.key.startsWith('instance:')
        ? identity.key.substring('instance:'.length)
        : identity.key;
    final escaped = instanceKey.replaceAll("'", "''");

    final script =
        r'''
$dev = Get-PnpDevice -PresentOnly -InstanceId '__ID__' -ErrorAction SilentlyContinue
if ($null -ne $dev) { '1' } else { '0' }
'''
            .replaceFirst('__ID__', escaped);

    final result = await Process.run('powershell', [
      '-NoProfile',
      '-NonInteractive',
      '-ExecutionPolicy',
      'Bypass',
      '-Command',
      script,
    ]);

    return result.exitCode == 0 && result.stdout.toString().trim() == '1';
  }

  static Future<Map<String, PhysicalUsbDeviceIdentity>>
  _listWindowsDevices() async {
    final script = r'''
$ErrorActionPreference = 'SilentlyContinue'
$rows = @()
Get-PnpDevice -PresentOnly | Where-Object {
  $_.InstanceId -like 'USB\*' -or $_.InstanceId -like 'FTDIBUS\*'
} | ForEach-Object {
  $container = $null
  try {
    $container = (Get-PnpDeviceProperty -InstanceId $_.InstanceId -KeyName 'DEVPKEY_Device_ContainerId' -ErrorAction Stop).Data
  } catch {}

  $vid = $null
  $usbPid = $null
  if ($_.InstanceId -match 'VID_([0-9A-Fa-f]{4})') { $vid = $Matches[1].ToUpper() }
  if ($_.InstanceId -match 'PID_([0-9A-Fa-f]{4})') { $usbPid = $Matches[1].ToUpper() }

  $rows += [pscustomobject]@{
    InstanceId = $_.InstanceId
    FriendlyName = $_.FriendlyName
    ContainerId = if ($null -ne $container) { $container.ToString() } else { $null }
    VID = $vid
    PID = $usbPid
  }
}
$rows | ConvertTo-Json -Compress
''';

    final result = await Process.run('powershell', [
      '-NoProfile',
      '-NonInteractive',
      '-ExecutionPolicy',
      'Bypass',
      '-Command',
      script,
    ]);

    final map = <String, PhysicalUsbDeviceIdentity>{};
    if (result.exitCode != 0) {
      return map;
    }

    final output = result.stdout.toString().trim();
    if (output.isEmpty) {
      return map;
    }

    try {
      final decoded = jsonDecode(output);
      final rows = decoded is List ? decoded : [decoded];

      for (final raw in rows) {
        if (raw is! Map) continue;
        final row = Map<String, dynamic>.from(raw);
        final instanceId = row['InstanceId']?.toString();
        final containerId = row['ContainerId']?.toString();
        if (instanceId == null) continue;

        final key = (containerId != null && containerId.isNotEmpty)
            ? 'container:$containerId'
            : 'instance:$instanceId';

        map.putIfAbsent(
          key,
          () => PhysicalUsbDeviceIdentity(
            platform: 'windows',
            key: key,
            label: row['FriendlyName']?.toString(),
            vendorId: row['VID']?.toString(),
            productId: row['PID']?.toString(),
            containerId: containerId,
          ),
        );
      }
    } catch (e) {
      debugPrint('[USB DEVICE] Windows list parse failed: $e');
    }

    return map;
  }

  // ============================================================
  // macOS
  //
  // macOSにはWindowsのPnP ContainerId相当のAPIがないため、
  // IORegistryのUSBデバイス情報を用いて
  // VID/PID/Serial/Locationの組み合わせを物理デバイスIDとして扱う。
  // ============================================================

  static Future<PhysicalUsbDeviceIdentity?> _identifyMacForSerialPort(
    String portName,
  ) async {
    // まずIORegistryのSerialノードからUSB Serial Number等を探す。
    final result = await Process.run('ioreg', [
      '-r',
      '-c',
      'IOSerialBSDClient',
      '-l',
      '-w',
      '0',
    ]);

    if (result.exitCode == 0) {
      final blocks = _splitIoregBlocks(result.stdout.toString());
      for (final block in blocks) {
        if (!block.contains(portName)) continue;

        final serial =
            _extractQuotedProperty(block, 'USB Serial Number') ??
            _extractQuotedProperty(block, 'USB SerialNumber');
        final vid = _extractNumericProperty(block, 'idVendor');
        final pid = _extractNumericProperty(block, 'idProduct');
        final location = _extractNumericProperty(block, 'locationID');

        if (serial != null || vid != null || pid != null || location != null) {
          final key = _macKey(
            vendorId: vid,
            productId: pid,
            serialNumber: serial,
            locationId: location,
          );

          return PhysicalUsbDeviceIdentity(
            platform: 'macos',
            key: key,
            label: portName,
            vendorId: vid,
            productId: pid,
            serialNumber: serial,
          );
        }
      }
    }

    // Serialノードから親USB情報が得られない場合はnull。
    // UsbMonitorService側で「直前snapshotとの差分」を使って補完する。
    return null;
  }

  static Future<bool> _isPresentMac(PhysicalUsbDeviceIdentity identity) async {
    final devices = await _listMacDevices();
    return devices.containsKey(identity.key);
  }

  static Future<Map<String, PhysicalUsbDeviceIdentity>>
  _listMacDevices() async {
    final result = await Process.run('system_profiler', [
      'SPUSBDataType',
      '-json',
    ]);

    final map = <String, PhysicalUsbDeviceIdentity>{};
    if (result.exitCode != 0) {
      return map;
    }

    try {
      final decoded = jsonDecode(result.stdout.toString());
      if (decoded is! Map) return map;
      final roots = decoded['SPUSBDataType'];
      if (roots is! List) return map;

      void walk(dynamic node) {
        if (node is! Map) return;
        final row = Map<String, dynamic>.from(node);

        final vid = _normalizeHexString(row['vendor_id']?.toString());
        final pid = _normalizeHexString(row['product_id']?.toString());
        final serial = row['serial_num']?.toString();
        final location = row['location_id']?.toString();
        final name = row['_name']?.toString();

        if (vid != null || pid != null || serial != null) {
          final key = _macKey(
            vendorId: vid,
            productId: pid,
            serialNumber: serial,
            locationId: location,
          );

          map[key] = PhysicalUsbDeviceIdentity(
            platform: 'macos',
            key: key,
            label: name,
            vendorId: vid,
            productId: pid,
            serialNumber: serial,
          );
        }

        final items = row['_items'];
        if (items is List) {
          for (final child in items) {
            walk(child);
          }
        }
      }

      for (final root in roots) {
        walk(root);
      }
    } catch (e) {
      debugPrint('[USB DEVICE] macOS list parse failed: $e');
    }

    return map;
  }

  // ============================================================
  // LINUX FALLBACK
  // ============================================================

  static Future<PhysicalUsbDeviceIdentity?> _identifyLinuxForSerialPort(
    String portName,
  ) async {
    final result = await Process.run('udevadm', [
      'info',
      '--query=property',
      '--name=$portName',
    ]);

    if (result.exitCode != 0) return null;

    final props = <String, String>{};
    for (final line in result.stdout.toString().split('\n')) {
      final index = line.indexOf('=');
      if (index <= 0) continue;
      props[line.substring(0, index)] = line.substring(index + 1);
    }

    final vid = props['ID_VENDOR_ID'];
    final pid = props['ID_MODEL_ID'];
    final serial = props['ID_SERIAL_SHORT'];

    if (vid == null && pid == null && serial == null) return null;

    final key = 'linux:${vid ?? ''}:${pid ?? ''}:${serial ?? ''}';
    return PhysicalUsbDeviceIdentity(
      platform: 'linux',
      key: key,
      label: props['ID_MODEL'],
      vendorId: vid,
      productId: pid,
      serialNumber: serial,
    );
  }

  static Future<bool> _isPresentLinux(
    PhysicalUsbDeviceIdentity identity,
  ) async {
    final devices = await _listLinuxDevices();
    return devices.containsKey(identity.key);
  }

  static Future<Map<String, PhysicalUsbDeviceIdentity>>
  _listLinuxDevices() async {
    final map = <String, PhysicalUsbDeviceIdentity>{};
    final usbRoot = Directory('/sys/bus/usb/devices');
    if (!await usbRoot.exists()) return map;

    await for (final entity in usbRoot.list(followLinks: false)) {
      if (entity is! Directory) continue;
      try {
        final vidFile = File('${entity.path}/idVendor');
        final pidFile = File('${entity.path}/idProduct');
        if (!await vidFile.exists() || !await pidFile.exists()) continue;

        final vid = (await vidFile.readAsString()).trim();
        final pid = (await pidFile.readAsString()).trim();
        final serialFile = File('${entity.path}/serial');
        final serial = await serialFile.exists()
            ? (await serialFile.readAsString()).trim()
            : null;

        final key = 'linux:$vid:$pid:${serial ?? entity.path}';
        map[key] = PhysicalUsbDeviceIdentity(
          platform: 'linux',
          key: key,
          vendorId: vid,
          productId: pid,
          serialNumber: serial,
        );
      } catch (_) {}
    }

    return map;
  }

  // ============================================================
  // HELPERS
  // ============================================================

  static List<String> _splitIoregBlocks(String text) {
    final lines = text.split('\n');
    final blocks = <String>[];
    final buffer = StringBuffer();

    for (final line in lines) {
      if (line.trimLeft().startsWith('+-o ') && buffer.isNotEmpty) {
        blocks.add(buffer.toString());
        buffer.clear();
      }
      buffer.writeln(line);
    }

    if (buffer.isNotEmpty) {
      blocks.add(buffer.toString());
    }

    return blocks;
  }

  static String? _extractQuotedProperty(String block, String key) {
    final regex = RegExp('"${RegExp.escape(key)}"\\s*=\\s*"([^"]+)"');
    return regex.firstMatch(block)?.group(1);
  }

  static String? _extractNumericProperty(String block, String key) {
    final regex = RegExp(
      '"${RegExp.escape(key)}"\\s*=\\s*(0x[0-9A-Fa-f]+|[0-9]+)',
    );
    final value = regex.firstMatch(block)?.group(1);
    return _normalizeHexString(value);
  }

  static String? _normalizeHexString(String? value) {
    if (value == null || value.isEmpty) return null;
    final match = RegExp(r'0x([0-9A-Fa-f]+)').firstMatch(value);
    if (match != null) {
      return match.group(1)!.toUpperCase();
    }
    final clean = value.replaceAll(RegExp(r'[^0-9A-Fa-f]'), '');
    return clean.isEmpty ? null : clean.toUpperCase();
  }

  static String _macKey({
    required String? vendorId,
    required String? productId,
    required String? serialNumber,
    required String? locationId,
  }) {
    return 'macos:${vendorId ?? ''}:${productId ?? ''}:'
        '${serialNumber ?? ''}:${locationId ?? ''}';
  }
}
