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

  StreamSubscription<BluetoothConnectionState>? _connectionSubscription;
  StreamSubscription<BluetoothAdapterState>? _adapterSubscription;
  bool _autoReconnectEnabled = false;
  bool _autoReconnectStarting = false;
  bool _initialised = false;
  bool _userDisconnectRequested = false;
  bool _configuring = false;

  bool get connected => device?.isConnected == true;

  /// Start the phone-side automatic reconnect service.
  /// Android keeps the BLE bond, so the app can find the previously paired
  /// Smart Guitar without asking the user to scan or pair again.
  Future<void> initializeAutoReconnect() async {
    if (_initialised) return;
    _initialised = true;

    _adapterSubscription = FlutterBluePlus.adapterState.listen((state) {
      if (state == BluetoothAdapterState.on) {
        unawaited(_startAutoReconnect());
      }
    });

    if (FlutterBluePlus.adapterStateNow == BluetoothAdapterState.on) {
      await _startAutoReconnect();
    }
  }

  Future<void> _startAutoReconnect() async {
    if (_autoReconnectStarting) return;
    if (FlutterBluePlus.adapterStateNow != BluetoothAdapterState.on) return;

    _autoReconnectStarting = true;
    try {
      final permissions = await [
        Permission.bluetoothScan,
        Permission.bluetoothConnect,
      ].request();

      if (permissions.values.any((p) => !p.isGranted)) return;

      BluetoothDevice? candidate = device;

      // Android retains bonded devices across app restarts and guitar power
      // cycles. Use that list instead of requiring another scan/pair action.
      if (candidate == null) {
        try {
          final bonded = await FlutterBluePlus.bondedDevices;
          for (final d in bonded) {
            final name = d.platformName.trim().toLowerCase();
            if (name == 'smart guitar' || name.contains('smart guitar')) {
              candidate = d;
              break;
            }
          }
        } catch (_) {
          // If bondedDevices is unavailable, the normal manual scan remains
          // available from the UI.
        }
      }

      if (candidate == null) return;

      _autoReconnectEnabled = true;
      _userDisconnectRequested = false;
      device = candidate;
      _watchConnection(candidate);

      if (candidate.isConnected) {
        await _setupConnectedDevice(candidate);
        return;
      }

      _status.add('reconnecting');

      // autoConnect deliberately has no short timeout and no MTU argument.
      // Android keeps trying when the guitar is temporarily powered off.
      try {
        await candidate.connect(
          license: License.nonprofit,
          autoConnect: true,
          mtu: null,
        );
      } catch (_) {
        // The connectionState stream reports the actual result. Background
        // reconnect must not surface a one-shot exception to the UI.
      }
    } finally {
      _autoReconnectStarting = false;
    }
  }

  void _watchConnection(BluetoothDevice d) {
    _connectionSubscription?.cancel();
    _connectionSubscription = d.connectionState.listen((state) {
      if (state == BluetoothConnectionState.connected) {
        unawaited(_setupConnectedDevice(d));
      } else if (state == BluetoothConnectionState.disconnected) {
        control = null;
        data = null;
        _status.add('disconnected');

        if (_autoReconnectEnabled && !_userDisconnectRequested) {
          _status.add('reconnecting');
        }
      }
    });
  }

  Future<void> _setupConnectedDevice(BluetoothDevice d) async {
    if (_configuring) return;
    _configuring = true;

    try {
      device = d;

      // autoConnect cannot take an MTU argument. Explicitly negotiate one
      // after the connection is established so sync is not stuck at MTU 23
      // (20-byte ATT payload).
      if (d.mtuNow < 247) {
        try {
          await d.requestMtu(247);
        } catch (_) {
          // Keep going. Sync code below dynamically falls back to the
          // currently negotiated MTU if the request is rejected.
        }
      }

      // FlutterBluePlus requires service discovery again after every BLE
      // reconnection.
      final services = await d.discoverServices();
      final service = services.firstWhere(
        (s) => s.uuid == serviceUuid,
        orElse: () => throw Exception(
          'Smart Guitar connected, but its practice service was not found.',
        ),
      );

      final newControl = service.characteristics.firstWhere(
        (c) => c.uuid == controlUuid,
        orElse: () => throw Exception('Smart Guitar control channel not found.'),
      );

      final newData = service.characteristics.firstWhere(
        (c) => c.uuid == dataUuid,
        orElse: () => throw Exception('Smart Guitar data channel not found.'),
      );

      control = newControl;
      data = newData;
      await newData.setNotifyValue(true);

      _status.add('connected');
    } catch (e) {
      control = null;
      data = null;
      _status.add('connection_error: $e');
    } finally {
      _configuring = false;
    }
  }

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
    _autoReconnectEnabled = true;
    _userDisconnectRequested = false;
    device = d;
    _watchConnection(d);

    try {
      await d.connect(
        license: License.nonprofit,
        timeout: const Duration(seconds: 10),
        autoConnect: false,
      );
    } catch (e) {
      if (!d.isConnected) rethrow;
    }

    await _setupConnectedDevice(d);
  }

  Future<void> disconnect() async {
    _userDisconnectRequested = true;
    _autoReconnectEnabled = false;

    final d = device;
    await _connectionSubscription?.cancel();
    _connectionSubscription = null;

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

      if (s == '\n') {
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

  List<String> _chunkUtf8(String value, int maxBytes) {
    final chunks = <String>[];
    final current = StringBuffer();
    var currentBytes = 0;

    for (final rune in value.runes) {
      final char = String.fromCharCode(rune);
      final bytes = utf8.encode(char);

      if (current.isNotEmpty && currentBytes + bytes.length > maxBytes) {
        chunks.add(current.toString());
        current.clear();
        currentBytes = 0;
      }

      current.write(char);
      currentBytes += bytes.length;
    }

    if (current.isNotEmpty) {
      chunks.add(current.toString());
    }

    return chunks;
  }

  Future<void> syncTasks(Map<String, dynamic> apiPayload) async {
    final w = control;
    final d = device;

    if (w == null || d == null || !d.isConnected) {
      throw Exception('Smart Guitar is not connected');
    }

    // The ESP32 control characteristic supports both write modes. Use
    // Write Without Response for bulk chunks; this avoids the 20-byte
    // response-write limit and is safe because each chunk is appended in
    // order on the ESP32.
    await w.write(
      utf8.encode('SYNC_BEGIN'),
      withoutResponse: true,
    );

    final json = jsonEncode(apiPayload);
    final mtuPayload = d.mtuNow > 3 ? d.mtuNow - 3 : 20;
    final maxWritePayload = mtuPayload.clamp(1, 180).toInt();
    const prefix = 'SYNC_CHUNK:';
    final prefixBytes = utf8.encode(prefix).length;
    final chunkDataBytes = (maxWritePayload - prefixBytes).clamp(1, 180).toInt();

    for (final part in _chunkUtf8(json, chunkDataBytes)) {
      await w.write(
        utf8.encode('$prefix$part'),
        withoutResponse: true,
      );
    }

    await w.write(
      utf8.encode('SYNC_END'),
      withoutResponse: true,
    );
  }
}
