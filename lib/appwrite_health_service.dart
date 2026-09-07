import 'package:appwrite/appwrite.dart';
import 'appwrite_config.dart';
import 'health/health_service.dart';

class AppwriteHealthService {
  final Client _client = Client()
      .setEndpoint(AppwriteConfig.endpoint)
      .setProject(AppwriteConfig.projectId);

  late final Account _account = Account(_client);
  late final Databases _databases = Databases(_client);

  Future<String> currentUserId() async => (await _account.get()).$id;

  Future<void> upsertDailyHealth(HealthSummary summary) async {
    if (AppwriteConfig.projectId.isEmpty) {
      throw Exception('APPWRITE_PROJECT_ID is not configured');
    }

    final userId = await currentUserId();
    final data = {
      'userId': userId,
      'date': summary.dateKey,
      'steps': summary.steps,
      'heartRateAvg': summary.heartRateAvg,
      'sleepMinutes': summary.sleepMinutes,
      'activeCalories': summary.activeCalories,
      'bloodOxygenAvg': summary.bloodOxygenAvg,
      'source': 'health_connect',
      'syncedAt': DateTime.now().toUtc().toIso8601String(),
    };

    final existing = await _databases.listDocuments(
      databaseId: AppwriteConfig.databaseId,
      collectionId: AppwriteConfig.activitiesCollectionId,
      queries: [
        Query.equal('userId', [userId]),
        Query.equal('date', [summary.dateKey]),
        Query.limit(1),
      ],
    );

    final permissions = [
      Permission.read(Role.user(userId)),
      Permission.update(Role.user(userId)),
      Permission.delete(Role.user(userId)),
    ];

    if (existing.documents.isEmpty) {
      await _databases.createDocument(
        databaseId: AppwriteConfig.databaseId,
        collectionId: AppwriteConfig.activitiesCollectionId,
        documentId: ID.unique(),
        data: data,
        permissions: permissions,
      );
    } else {
      await _databases.updateDocument(
        databaseId: AppwriteConfig.databaseId,
        collectionId: AppwriteConfig.activitiesCollectionId,
        documentId: existing.documents.first.$id,
        data: data,
        permissions: permissions,
      );
    }
  }
}
