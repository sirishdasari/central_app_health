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

  static const List<HealthDataType> _types = [
    HealthDataType.STEPS,
    HealthDataType.HEART_RATE,
    HealthDataType.SLEEP_ASLEEP,
    HealthDataType.ACTIVE_ENERGY_BURNED,
    HealthDataType.TOTAL_CALORIES_BURNED,
    HealthDataType.BLOOD_OXYGEN,
  ];

  Future<bool> requestPermissions() async {
    try {
      await _health.configure();
      final granted = await _health.requestAuthorization(_types);
      if (!granted) return false;

      if (await _health.isHealthDataInBackgroundAvailable()) {
        await _health.requestHealthDataInBackgroundAuthorization();
      }
      return true;
    } catch (e) {
      print('Health permission error: $e');
      return false;
    }
  }

  Future<bool> ensurePermissions() async {
    try {
      await _health.configure();
      final granted = await _health.hasPermissions(
        _types,
        permissions: _types.map((_) => HealthDataAccess.READ).toList(),
      );
      if (granted != true) return false;

      if (await _health.isHealthDataInBackgroundAvailable()) {
        return await _health.isHealthDataInBackgroundAuthorized();
      }
      return true;
    } catch (e) {
      print('Background health permission check error: $e');
      return false;
    }
  }

  Future<bool> isHistoryAuthorized() async {
    await _health.configure();
    return await _health.isHealthDataHistoryAuthorized();
  }

  Future<bool> requestHistoryAccess() async {
    await _health.configure();
    return await _health.requestHealthDataHistoryAuthorization();
  }

  Future<bool> isBackgroundAuthorized() async {
    await _health.configure();
    if (!await _health.isHealthDataInBackgroundAvailable()) return false;
    return await _health.isHealthDataInBackgroundAuthorized();
  }

  Future<bool> requestBackgroundAccess() async {
    await _health.configure();
    if (!await _health.isHealthDataInBackgroundAvailable()) return false;
    return await _health.requestHealthDataInBackgroundAuthorization();
  }

  Future<List<HealthDataPoint>> getTodayHealthData() async {
    final now = DateTime.now();
    final start = DateTime(now.year, now.month, now.day);
    final types = <HealthDataType>[
      HealthDataType.STEPS,
      HealthDataType.HEART_RATE,
      HealthDataType.SLEEP_ASLEEP,
      HealthDataType.ACTIVE_ENERGY_BURNED,
      HealthDataType.TOTAL_CALORIES_BURNED,
      HealthDataType.BLOOD_OXYGEN,
    ];
    try {
      final data = await _health.getHealthDataFromTypes(
        startTime: start,
        endTime: now,
        types: types,
      );

      // Health Connect is a hub. Only use records whose origin is Samsung Health.
      // Samsung Health normally reports this as sourceId com.sec.android.app.shealth
      // and/or sourceName "Samsung Health".
      return data.where((point) {
        final sourceId = point.sourceId.toLowerCase();
        final sourceName = point.sourceName.toLowerCase();
        return sourceId == _samsungHealthSourceId ||
            sourceName.contains('samsung health') ||
            sourceName.contains('s health') ||
            sourceName.contains('com.sec.android.app.shealth');
      }).toList();
    } catch (e) {
      print('Health data error: $e');
      return [];
    }
  }

  Future<List<HealthDataPoint>> _readSleep(DateTime start, DateTime end) async {
    try {
      final data = await _health.getHealthDataFromTypes(
        startTime: start,
        endTime: end,
        types: [HealthDataType.SLEEP_ASLEEP],
      );
      return data.where((point) {
        final sourceId = point.sourceId.toLowerCase();
        final sourceName = point.sourceName.toLowerCase();
        return sourceId == _samsungHealthSourceId ||
            sourceName.contains('samsung health') ||
            sourceName.contains('s health') ||
            sourceName.contains('com.sec.android.app.shealth');
      }).toList();
    } catch (e) {
      print('Sleep data error: $e');
      return [];
    }
  }

  Future<HealthSummary> readToday() async {
    final now = DateTime.now();
    final start = DateTime(now.year, now.month, now.day);
    final data = await getTodayHealthData();
    final sleepData = await _readSleep(start.subtract(const Duration(hours: 18)), now);

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
        case HealthDataType.TOTAL_CALORIES_BURNED:
          calories.add(number);
          break;
        case HealthDataType.BLOOD_OXYGEN:
          oxygen.add(number);
          break;
        default:
          break;
      }
    }

    for (final point in sleepData.where((p) => p.type == HealthDataType.SLEEP_ASLEEP)) {
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
