import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:permission_handler/permission_handler.dart';

class SmartGuitarBle {
  static final SmartGuitarBle instance=SmartGuitarBle._();
  SmartGuitarBle._();

  static final Guid serviceUuid=Guid('7b6a0001-8f31-4a1e-9f7a-6d9b1c5a0001');
  static final Guid controlUuid=Guid('7b6a0002-8f31-4a1e-9f7a-6d9b1c5a0001');
  static final Guid dataUuid=Guid('7b6a0003-8f31-4a1e-9f7a-6d9b1c5a0001');

  BluetoothDevice? device;
  BluetoothCharacteristic? control;
  BluetoothCharacteristic? data;
  final _status=StreamController<String>.broadcast();
  Stream<String> get statusStream=>_status.stream;
  bool get connected=>device?.isConnected==true;

  Future<List<ScanResult>> scan({Duration timeout=const Duration(seconds:5)}) async {
    final permissions = await [Permission.bluetoothScan, Permission.bluetoothConnect].request();
    if (permissions.values.any((p)=>!p.isGranted)) throw Exception('Bluetooth permission was not granted');
    final results=<ScanResult>[];
    final sub=FlutterBluePlus.onScanResults.listen((items){for(final r in items){if(r.device.platformName=='Smart Guitar'||r.advertisementData.advName=='Smart Guitar'){results.removeWhere((x)=>x.device.remoteId==r.device.remoteId);results.add(r);}}});
    await FlutterBluePlus.startScan(timeout:timeout,withServices:[serviceUuid]);
    await FlutterBluePlus.isScanning.where((v)=>!v).first;
    await sub.cancel();
    return results;
  }

  Future<void> connect(BluetoothDevice d) async {
    await d.connect(license: License.nonprofit, timeout: const Duration(seconds:10), autoConnect:false);
    device=d;
    final services=await d.discoverServices();
    final service=services.firstWhere((s)=>s.uuid==serviceUuid);
    control=service.characteristics.firstWhere((c)=>c.uuid==controlUuid);
    data=service.characteristics.firstWhere((c)=>c.uuid==dataUuid);
    await data!.setNotifyValue(true);
    _status.add('connected');
  }

  Future<void> disconnect() async { final d=device; if(d!=null) await d.disconnect(); device=null;control=null;data=null;_status.add('disconnected'); }

  Future<String> requestTasks() => _request('GET_TASKS');

  Future<Map<String,dynamic>> getProgress() async {
    final raw = await _request('GET_PROGRESS');
    return Map<String,dynamic>.from(jsonDecode(raw));
  }

  Future<String> _request(String command) async {
    final c=data; final w=control;
    if(c==null||w==null) throw Exception('Smart Guitar is not connected');
    final done=Completer<String>(); final buffer=StringBuffer();
    late StreamSubscription<List<int>> sub;
    sub=c.onValueReceived.listen((bytes){final s=utf8.decode(bytes,allowMalformed:true); if(s=='\\n'){if(!done.isCompleted)done.complete(buffer.toString());}else{buffer.write(s);}});
    await w.write(utf8.encode(command),withoutResponse:false);
    try { return await done.future.timeout(const Duration(seconds:8)); }
    finally { await sub.cancel(); }
  }

  Future<void> syncTasks(Map<String,dynamic> apiPayload) async {
    final w=control;if(w==null)throw Exception('Smart Guitar is not connected');
    await w.write(utf8.encode('SYNC_BEGIN'),withoutResponse:false);
    final json=jsonEncode(apiPayload);
    const size=170;
    for(var i=0;i<json.length;i+=size){
      final part=json.substring(i,(i+size>json.length)?json.length:i+size);
      await w.write(utf8.encode('SYNC_CHUNK:$part'),withoutResponse:false);
    }
    await w.write(utf8.encode('SYNC_END'),withoutResponse:false);
  }
}
