import 'package:health/health.dart';

class HealthSummary {
  final String dateKey;
  final int steps;
  final double? heartRateAvg;
  final int sleepMinutes;
  final double? activeCalories;
  final double? bloodOxygenAvg;

  const HealthSummary({required this.dateKey, required this.steps, required this.heartRateAvg, required this.sleepMinutes, required this.activeCalories, required this.bloodOxygenAvg});
}

class HealthService {
  final Health _health = Health();

  // Health Connect data origin for Samsung Health.
  static const String _samsungHealthSourceId = 'com.sec.android.app.shealth';

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

  Future<bool> ensurePermissions() => requestPermissions();

  Future<List<HealthDataPoint>> getTodayHealthData() async {
    final now = DateTime.now();
    final start = DateTime(now.year, now.month, now.day);
    final types = <HealthDataType>[
      HealthDataType.STEPS,
      HealthDataType.HEART_RATE,
      HealthDataType.SLEEP_ASLEEP,
      HealthDataType.ACTIVE_ENERGY_BURNED,
      HealthDataType.BLOOD_OXYGEN,
    ];
    try {
      return await _health.getHealthDataFromTypes(startTime: start, endTime: now, types: types);
    } catch (e) {
      print('Health data error: $e');
      return [];
    }
  }

  Future<HealthSummary> readToday() async {
    final now = DateTime.now();
    final start = DateTime(now.year, now.month, now.day);
    final data = await getTodayHealthData();

    var steps = 0;
    final heartRates = <double>[];
    final calories = <double>[];
    final oxygen = <double>[];
    var sleepMinutes = 0;

    for (final point in data) {
      final value = point.value;
      final number = value is NumericHealthValue ? value.numericValue.toDouble() : null;
      if (number == null) continue;
      switch (point.type) {
        case HealthDataType.STEPS:
          steps += number.round();
          break;
        case HealthDataType.HEART_RATE:
          heartRates.add(number);
          break;
        case HealthDataType.ACTIVE_ENERGY_BURNED:
          calories.add(number);
          break;
        case HealthDataType.BLOOD_OXYGEN:
          oxygen.add(number);
          break;
        default:
          break;
      }
    }

    for (final point in data.where((p) => p.type == HealthDataType.SLEEP_ASLEEP)) {
      final from = point.dateFrom.isBefore(start) ? start : point.dateFrom;
      final to = point.dateTo.isAfter(now) ? now : point.dateTo;
      if (to.isAfter(from)) sleepMinutes += to.difference(from).inMinutes;
    }

    double? average(List<double> values) => values.isEmpty ? null : values.reduce((a, b) => a + b) / values.length;
    final dateKey = '${start.year.toString().padLeft(4, '0')}-${start.month.toString().padLeft(2, '0')}-${start.day.toString().padLeft(2, '0')}';

    return HealthSummary(
      dateKey: dateKey,
      steps: steps,
      heartRateAvg: average(heartRates),
      sleepMinutes: sleepMinutes,
      activeCalories: calories.isEmpty ? null : calories.reduce((a, b) => a + b),
      bloodOxygenAvg: average(oxygen),
    );
  }
}
