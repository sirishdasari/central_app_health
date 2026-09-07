import 'package:flutter/material.dart';

import 'background_sync.dart';
import 'auth_screen.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await initializeHealthBackgroundSync();
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
