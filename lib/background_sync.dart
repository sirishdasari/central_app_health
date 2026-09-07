import 'package:workmanager/workmanager.dart';

import 'appwrite_health_service.dart';
import 'health/health_service.dart';

const healthSyncTask = 'mydaily_health_sync';

@pragma('vm:entry-point')
void healthCallbackDispatcher() {
  Workmanager().executeTask((task, inputData) async {
    if (task != healthSyncTask) return true;
    try {
      final health = HealthService();
      final authorized = await health.ensurePermissions();
      if (!authorized) return false;
      final summary = await health.readToday();
      await AppwriteHealthService().upsertDailyHealth(summary);
      return true;
    } catch (_) {
      return false;
    }
  });
}

Future<void> initializeHealthBackgroundSync() async {
  await Workmanager().initialize(healthCallbackDispatcher);
  await Workmanager().registerPeriodicTask(
    healthSyncTask,
    healthSyncTask,
    frequency: const Duration(hours: 1),
    constraints: Constraints(networkType: NetworkType.connected),
  );
}
