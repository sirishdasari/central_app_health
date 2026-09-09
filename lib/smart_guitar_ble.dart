import 'dart:async';
import 'dart:convert';

import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:permission_handler/permission_handler.dart';

class SmartGuitarBle {
  static final SmartGuitarBle instance = SmartGuitarBle._();
  SmartGuitarBle._();

  static final Guid serviceUuid =
      Guid('7b6a0001-8f31-4a1e-9f7a-6d9b1c5a0001');
  static final Guid controlUuid =
      Guid('7b6a0002-8f31-4a1e-9f7a-6d9b1c5a0001');
  static final Guid dataUuid =
      Guid('7b6a0003-8f31-4a1e-9f7a-6d9b1c5a0001');

  BluetoothDevice? device;
  BluetoothCharacteristic? control;
  BluetoothCharacteristic? data;

  final _status = StreamController<String>.broadcast();
  Stream<String> get statusStream => _status.stream;

  bool get connected => device?.isConnected == true;

  Future<List<ScanResult>> scan({
    Duration timeout = const Duration(seconds: 8),
  }) async {
    final permissions = await [
      Permission.bluetoothScan,
      Permission.bluetoothConnect,
    ].request();

    if (permissions.values.any((p) => !p.isGranted)) {
      throw Exception('Bluetooth permission was not granted');
    }

    if (await Permission.bluetoothScan.isPermanentlyDenied ||
        await Permission.bluetoothConnect.isPermanentlyDenied) {
      throw Exception(
        'Bluetooth permission is permanently denied. Enable Nearby devices permission in Android Settings.',
      );
    }

    // The Android radio itself must be ON. Do not confuse this with the
    // Smart Guitar BLE connection state.
    final adapter = await FlutterBluePlus.adapterState.first;
    if (adapter != BluetoothAdapterState.on) {
      throw Exception('Phone Bluetooth is turned off.');
    }

    final results = <String, ScanResult>{};

    late final StreamSubscription<List<ScanResult>> sub;
    sub = FlutterBluePlus.onScanResults.listen((items) {
      for (final item in items) {
        results[item.device.remoteId.str] = item;
      }
    }, onError: (_) {});

    try {
      // Unfiltered scan. We identify the guitar by its advertised name,
      // then verify the custom GATT service after connecting.
      await FlutterBluePlus.startScan(
        timeout: timeout,
        androidScanMode: AndroidScanMode.lowLatency,
        androidCheckLocationServices: false,
      );
      await FlutterBluePlus.isScanning.where((v) => !v).first;
    } finally {
      await sub.cancel();
      if (FlutterBluePlus.isScanningNow) {
        await FlutterBluePlus.stopScan();
      }
    }

    // Include anything retained by FlutterBluePlus after the scan.
    for (final item in FlutterBluePlus.lastScanResults) {
      results[item.device.remoteId.str] = item;
    }

    final matches = results.values.where(_isSmartGuitar).toList();
    if (matches.isEmpty) {
      final seen = results.values.map((item) {
        final adv = item.advertisementData.advName.trim();
        final platform = item.device.platformName.trim();
        final name = adv.isNotEmpty ? adv : platform;
        return name.isEmpty
            ? '${item.device.remoteId.str} (unnamed)'
            : '$name (${item.device.remoteId.str})';
      }).take(12).join(', ');

      throw Exception(
        seen.isEmpty
            ? 'No BLE devices were detected. Check that BLE is enabled on the guitar and try again.'
            : 'Smart Guitar was not detected. BLE devices seen: $seen',
      );
    }

    return matches;
  }

  bool _isSmartGuitar(ScanResult item) {
    final advName = item.advertisementData.advName.trim().toLowerCase();
    final platformName = item.device.platformName.trim().toLowerCase();

    return advName == 'smart guitar' ||
        platformName == 'smart guitar' ||
        advName.contains('smart guitar') ||
        platformName.contains('smart guitar') ||
        item.advertisementData.serviceUuids.any(
          (uuid) => uuid == serviceUuid,
        );
  }

  Future<void> connect(BluetoothDevice d) async {
    try {
      await d.connect(
        license: License.nonprofit,
        timeout: const Duration(seconds: 10),
        autoConnect: false,
      );
    } catch (e) {
      // flutter_blue_plus can report an "already connected" error when
      // Android restored a previous BLE connection.
      if (!d.isConnected) rethrow;
    }

    device = d;

    final services = await d.discoverServices();

    final service = services.firstWhere(
      (s) => s.uuid == serviceUuid,
      orElse: () => throw Exception(
        'Smart Guitar connected, but its practice service was not found.',
      ),
    );

    control = service.characteristics.firstWhere(
      (c) => c.uuid == controlUuid,
      orElse: () => throw Exception('Smart Guitar control channel not found.'),
    );

    data = service.characteristics.firstWhere(
      (c) => c.uuid == dataUuid,
      orElse: () => throw Exception('Smart Guitar data channel not found.'),
    );

    await data!.setNotifyValue(true);
    _status.add('connected');
  }

  Future<void> disconnect() async {
    final d = device;

    try {
      if (d != null && d.isConnected) {
        await d.disconnect();
      }
    } finally {
      device = null;
      control = null;
      data = null;
      _status.add('disconnected');
    }
  }

  Future<String> requestTasks() => _request('GET_TASKS');

  Future<Map<String, dynamic>> getProgress() async {
    final raw = await _request('GET_PROGRESS');
    return Map<String, dynamic>.from(jsonDecode(raw));
  }

  Future<String> _request(String command) async {
    final c = data;
    final w = control;

    if (c == null || w == null) {
      throw Exception('Smart Guitar is not connected');
    }

    final done = Completer<String>();
    final buffer = StringBuffer();

    late StreamSubscription<List<int>> sub;

    sub = c.onValueReceived.listen((bytes) {
      final s = utf8.decode(bytes, allowMalformed: true);

      if (s == '\\n') {
        if (!done.isCompleted) {
          done.complete(buffer.toString());
        }
      } else {
        buffer.write(s);
      }
    });

    try {
      await w.write(
        utf8.encode(command),
        withoutResponse: false,
      );

      return await done.future.timeout(const Duration(seconds: 8));
    } finally {
      await sub.cancel();
    }
  }

  Future<void> syncTasks(Map<String, dynamic> apiPayload) async {
    final w = control;

    if (w == null) {
      throw Exception('Smart Guitar is not connected');
    }

    await w.write(
      utf8.encode('SYNC_BEGIN'),
      withoutResponse: false,
    );

    final json = jsonEncode(apiPayload);

    // Keep this below the ESP32 RX chunk size.
    const size = 170;

    for (var i = 0; i < json.length; i += size) {
      final end = (i + size > json.length) ? json.length : i + size;
      final part = json.substring(i, end);

      await w.write(
        utf8.encode('SYNC_CHUNK:$part'),
        withoutResponse: false,
      );
    }

    await w.write(
      utf8.encode('SYNC_END'),
      withoutResponse: false,
    );
  }
}
