import 'dart:async';
import 'dart:convert';

import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:permission_handler/permission_handler.dart';

class SmartGuitarBle {
  static final SmartGuitarBle instance = SmartGuitarBle._();
  SmartGuitarBle._();

  static final Guid serviceUuid = Guid('7b6a0001-8f31-4a1e-9f7a-6d9b1c5a0001');
  static final Guid controlUuid = Guid('7b6a0002-8f31-4a1e-9f7a-6d9b1c5a0001');
  static final Guid dataUuid = Guid('7b6a0003-8f31-4a1e-9f7a-6d9b1c5a0001');

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
  bool _ready = false;

  // Do not expose the connection as ready until service discovery, notifications,
  // and SET_TIME have completed. Task sync starts only after this point.
  bool get connected => _ready && device?.isConnected == true;

  Future<void> initializeAutoReconnect() async {
    if (_initialised) return;
    _initialised = true;

    _adapterSubscription = FlutterBluePlus.adapterState.listen((state) {
      if (state == BluetoothAdapterState.on) unawaited(_startAutoReconnect());
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
        } catch (_) {}
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
      try {
        await candidate.connect(
          license: License.nonprofit,
          autoConnect: true,
          mtu: null,
        );
      } catch (_) {}
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
        _ready = false;
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
    _ready = false;

    try {
      device = d;
      if (d.mtuNow < 247) {
        try {
          await d.requestMtu(247);
        } catch (_) {}
      }

      final services = await d.discoverServices();
      final service = services.firstWhere(
        (s) => s.uuid == serviceUuid,
        orElse: () => throw Exception('Smart Guitar connected, but its practice service was not found.'),
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

      // Wait for the ESP32's TIME_OK before advertising BLE readiness.
      await syncTime();
      _ready = true;
      _status.add('connected');
      _status.add('time_synced');
    } catch (e) {
      _ready = false;
      control = null;
      data = null;
      _status.add('connection_error: $e');
    } finally {
      _configuring = false;
    }
  }

  Future<List<ScanResult>> scan({Duration timeout = const Duration(seconds: 8)}) async {
    final permissions = await [
      Permission.bluetoothScan,
      Permission.bluetoothConnect,
    ].request();
    if (permissions.values.any((p) => !p.isGranted)) {
      throw Exception('Bluetooth permission was not granted');
    }
    if (await Permission.bluetoothScan.isPermanentlyDenied ||
        await Permission.bluetoothConnect.isPermanentlyDenied) {
      throw Exception('Bluetooth permission is permanently denied. Enable Nearby devices permission in Android Settings.');
    }

    final adapter = await FlutterBluePlus.adapterState.first;
    if (adapter != BluetoothAdapterState.on) throw Exception('Phone Bluetooth is turned off.');

    final results = <String, ScanResult>{};
    late final StreamSubscription<List<ScanResult>> sub;
    sub = FlutterBluePlus.onScanResults.listen((items) {
      for (final item in items) results[item.device.remoteId.str] = item;
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
      if (FlutterBluePlus.isScanningNow) await FlutterBluePlus.stopScan();
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
        return name.isEmpty ? '${item.device.remoteId.str} (unnamed)' : '$name (${item.device.remoteId.str})';
      }).take(12).join(', ');
      throw Exception(seen.isEmpty
          ? 'No BLE devices were detected. Check that BLE is enabled on the guitar and try again.'
          : 'Smart Guitar was not detected. BLE devices seen: $seen');
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
        item.advertisementData.serviceUuids.any((uuid) => uuid == serviceUuid);
  }

  Future<void> connect(BluetoothDevice d) async {
    _autoReconnectEnabled = true;
    _userDisconnectRequested = false;
    device = d;
    _ready = false;
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
    _ready = false;
    final d = device;
    await _connectionSubscription?.cancel();
    _connectionSubscription = null;
    try {
      if (d != null && d.isConnected) await d.disconnect();
    } finally {
      device = null;
      control = null;
      data = null;
      _status.add('disconnected');
    }
  }

  /// Send phone UTC Unix time and wait for the ESP32 acknowledgement.
  Future<void> syncTime() async {
    final w = control;
    final c = data;
    final d = device;
    if (w == null || c == null || d == null || !d.isConnected) {
      throw Exception('Smart Guitar is not connected');
    }

    final done = Completer<void>();
    late StreamSubscription<List<int>> sub;
    sub = c.onValueReceived.listen((bytes) {
      final value = utf8.decode(bytes, allowMalformed: true).trim();
      if (value == 'TIME_OK' && !done.isCompleted) {
        done.complete();
      } else if (value == 'TIME_FAILED' && !done.isCompleted) {
        done.completeError(Exception('Smart Guitar rejected phone time'));
      }
    });

    try {
      final epochSeconds = DateTime.now().toUtc().millisecondsSinceEpoch ~/ 1000;
      await w.write(utf8.encode('SET_TIME:$epochSeconds'), withoutResponse: false);
      await done.future.timeout(const Duration(seconds: 5));
    } finally {
      await sub.cancel();
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
    if (c == null || w == null) throw Exception('Smart Guitar is not connected');

    final done = Completer<String>();
    final buffer = StringBuffer();
    late StreamSubscription<List<int>> sub;
    sub = c.onValueReceived.listen((bytes) {
      final s = utf8.decode(bytes, allowMalformed: true);
      if (s == '\n') {
        if (!done.isCompleted) done.complete(buffer.toString());
      } else {
        buffer.write(s);
      }
    });
    try {
      await w.write(utf8.encode(command), withoutResponse: false);
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
    if (current.isNotEmpty) chunks.add(current.toString());
    return chunks;
  }

  Future<void> syncTasks(Map<String, dynamic> apiPayload) async {
    final w = control;
    final d = device;
    if (!_ready || w == null || d == null || !d.isConnected) {
      throw Exception('Smart Guitar is not connected and ready');
    }

    Object? lastError;
    for (var attempt = 1; attempt <= 2; attempt++) {
      try {
        final ready = Completer<void>();
        final complete = Completer<void>();
        late StreamSubscription<List<int>> sub;
        sub = data!.onValueReceived.listen((bytes) {
          final value = utf8.decode(bytes, allowMalformed: true).trim();
          if (value == 'SYNC_READY' && !ready.isCompleted) {
            ready.complete();
          } else if (value == 'SYNC_OK' && !complete.isCompleted) {
            complete.complete();
          } else if (value == 'SYNC_FAILED' && !complete.isCompleted) {
            complete.completeError(Exception('Smart Guitar rejected task snapshot'));
          }
        });

        try {
          await w.write(utf8.encode('SYNC_BEGIN'), withoutResponse: false);
          await ready.future.timeout(const Duration(seconds: 3));

          final json = jsonEncode(apiPayload);
          final mtuPayload = d.mtuNow > 3 ? d.mtuNow - 3 : 20;
          final maxWritePayload = mtuPayload.clamp(1, 180).toInt();
          const prefix = 'SYNC_CHUNK:';
          final prefixBytes = utf8.encode(prefix).length;
          final chunkDataBytes = (maxWritePayload - prefixBytes).clamp(1, 180).toInt();

          for (final part in _chunkUtf8(json, chunkDataBytes)) {
            await w.write(utf8.encode('$prefix$part'), withoutResponse: true);
          }

          await w.write(utf8.encode('SYNC_END'), withoutResponse: false);
          await complete.future.timeout(const Duration(seconds: 8));
        } finally {
          await sub.cancel();
        }
        return;
      } catch (e) {
        lastError = e;
        if (attempt < 2) await Future<void>.delayed(const Duration(milliseconds: 250));
      }
    }

    throw Exception('Smart Guitar task sync failed: $lastError');
  }
}
