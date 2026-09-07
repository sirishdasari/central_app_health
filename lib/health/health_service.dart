import 'package:health/health.dart';

class HealthService {
  final Health _health = Health();

  Future<bool> requestPermissions() async {
    final types = <HealthDataType>[
      HealthDataType.STEPS,
      HealthDataType.HEART_RATE,
      HealthDataType.SLEEP_ASLEEP,
      HealthDataType.ACTIVE_ENERGY_BURNED,
      HealthDataType.BLOOD_OXYGEN,
    ];

    try {
      await _health.configure();
      return await _health.requestAuthorization(types);
    } catch (e) {
      print('Health permission error: $e');
      return false;
    }
  }

  Future<List<HealthDataPoint>> getTodayHealthData() async {
    final now = DateTime.now();

    final start = DateTime(
      now.year,
      now.month,
      now.day,
    );

    final types = <HealthDataType>[
      HealthDataType.STEPS,
      HealthDataType.HEART_RATE,
      HealthDataType.SLEEP_ASLEEP,
      HealthDataType.ACTIVE_ENERGY_BURNED,
      HealthDataType.BLOOD_OXYGEN,
    ];

    try {
      final data = await _health.getHealthDataFromTypes(
        startTime: start,
        endTime: now,
        types: types,
      );

      return data;
    } catch (e) {
      print('Health data error: $e');
      return [];
    }
  }
}
