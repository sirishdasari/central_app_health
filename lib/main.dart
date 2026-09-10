import 'package:flutter/material.dart';

import 'background_sync.dart';
import 'auth_screen.dart';
import 'smart_guitar_ble.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await initializeHealthBackgroundSync();

  // Start phone-side Smart Guitar auto-reconnect as soon as the app starts.
  // If Android already has a bond for the guitar, no scan or re-pairing is
  // required after the guitar is powered off and on again.
  await SmartGuitarBle.instance.initializeAutoReconnect();

  runApp(const MyApp());
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      title: 'MyDaily Health',
      theme: ThemeData.dark(useMaterial3: true),
      home: const AuthGate(),
    );
  }
}
