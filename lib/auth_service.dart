import 'package:appwrite/appwrite.dart';
import 'appwrite_config.dart';

class AppwriteAuthService {
  final Client _client = Client()
      .setEndpoint(AppwriteConfig.endpoint)
      .setProject(AppwriteConfig.projectId);

  late final Account _account = Account(_client);

  Future<User?> currentUser() async {
    if (AppwriteConfig.projectId.isEmpty) {
      throw Exception('APPWRITE_PROJECT_ID is not configured');
    }
    try {
      return await _account.get();
    } on AppwriteException catch (e) {
      if (e.code == 401) return null;
      rethrow;
    }
  }

  Future<User> login(String email, String password) async {
    if (AppwriteConfig.projectId.isEmpty) {
      throw Exception('APPWRITE_PROJECT_ID is not configured');
    }
    await _account.createEmailPasswordSession(email: email.trim(), password: password);
    return await _account.get();
  }

  Future<void> logout() async {
    await _account.deleteSession(sessionId: 'current');
  }
}
