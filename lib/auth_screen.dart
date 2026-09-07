import 'package:flutter/material.dart';
import 'auth_service.dart';
import 'health/health_screen.dart';

class AuthGate extends StatefulWidget {
  const AuthGate({super.key});
  @override State<AuthGate> createState() => _AuthGateState();
}

class _AuthGateState extends State<AuthGate> {
  final auth = AppwriteAuthService();
  bool loading = true;
  bool signedIn = false;
  String? error;

  @override void initState() { super.initState(); _check(); }

  Future<void> _check() async {
    try {
      final user = await auth.currentUser();
      if (!mounted) return;
      setState(() { signedIn = user != null; loading = false; });
    } catch (e) {
      if (!mounted) return;
      setState(() { error = e.toString().replaceFirst('Exception: ', ''); loading = false; });
    }
  }

  @override
  Widget build(BuildContext context) {
    if (loading) return const Scaffold(body: Center(child: CircularProgressIndicator()));
    if (signedIn) return const HealthScreen();
    return LoginScreen(onLoggedIn: () => setState(() => signedIn = true), initialError: error);
  }
}

class LoginScreen extends StatefulWidget {
  const LoginScreen({super.key, required this.onLoggedIn, this.initialError});
  final VoidCallback onLoggedIn;
  final String? initialError;
  @override State<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends State<LoginScreen> {
  final email = TextEditingController();
  final password = TextEditingController();
  final auth = AppwriteAuthService();
  bool busy = false;
  String? error;

  @override void dispose() { email.dispose(); password.dispose(); super.dispose(); }

  Future<void> _login() async {
    if (email.text.trim().isEmpty || password.text.isEmpty) {
      setState(() => error = 'Enter your MyDaily email and password.');
      return;
    }
    setState(() { busy = true; error = null; });
    try {
      await auth.login(email.text, password.text);
      if (mounted) widget.onLoggedIn();
    } catch (e) {
      if (!mounted) return;
      setState(() => error = e.toString().replaceFirst('AppwriteException: ', '').replaceFirst('Exception: ', ''));
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    backgroundColor: const Color(0xFF06131A),
    body: SafeArea(
      child: Center(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(28),
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 430),
            child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              const Icon(Icons.favorite_rounded, color: Color(0xFF45E88F), size: 64),
              const SizedBox(height: 20),
              const Text('MyDaily Health', textAlign: TextAlign.center, style: TextStyle(color: Colors.white, fontSize: 30, fontWeight: FontWeight.w800)),
              const SizedBox(height: 8),
              const Text('Sign in with your MyDaily account to sync health activity.', textAlign: TextAlign.center, style: TextStyle(color: Colors.white60, height: 1.4)),
              const SizedBox(height: 32),
              TextField(controller: email, keyboardType: TextInputType.emailAddress, style: const TextStyle(color: Colors.white), decoration: _dec('Email', Icons.email_outlined)),
              const SizedBox(height: 12),
              TextField(controller: password, obscureText: true, style: const TextStyle(color: Colors.white), decoration: _dec('Password', Icons.lock_outline)),
              if (error != null || widget.initialError != null) ...[
                const SizedBox(height: 12),
                Text(error ?? widget.initialError!, style: const TextStyle(color: Colors.redAccent)),
              ],
              const SizedBox(height: 20),
              FilledButton(
                onPressed: busy ? null : _login,
                child: Padding(padding: const EdgeInsets.symmetric(vertical: 14), child: busy ? const SizedBox(width:20,height:20,child:CircularProgressIndicator(strokeWidth:2)) : const Text('Sign in')),
              ),
              const SizedBox(height: 14),
              const Text('Your health data stays associated with your authenticated MyDaily account.', textAlign: TextAlign.center, style: TextStyle(color: Colors.white38, fontSize: 12)),
            ]),
          ),
        ),
      ),
    ),
  );

  InputDecoration _dec(String label, IconData icon) => InputDecoration(
    labelText: label,
    labelStyle: const TextStyle(color: Colors.white60),
    prefixIcon: Icon(icon, color: Colors.white54),
    filled: true,
    fillColor: const Color(0xFF0D202A),
    border: OutlineInputBorder(borderRadius: BorderRadius.circular(16), borderSide: BorderSide.none),
  );
}
