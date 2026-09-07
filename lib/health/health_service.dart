import 'package:health/health.dart';

class HealthSummary {
  const HealthSummary({
    required this.dateKey,
    required this.steps,
    required this.heartRateAvg,
    required this.sleepMinutes,
    required this.activeCalories,
    required this.bloodOxygenAvg,
  });

  final String dateKey;
  final int steps;
  final double? heartRateAvg;
  final int sleepMinutes;
  final double? activeCalories;
  final double? bloodOxygenAvg;
}

class HealthService {
  final Health _health = Health();

  static const types = <HealthDataType>[
    HealthDataType.STEPS,
    HealthDataType.HEART_RATE,
    HealthDataType.SLEEP_ASLEEP,
    HealthDataType.ACTIVE_ENERGY_BURNED,
    HealthDataType.BLOOD_OXYGEN,
  ];

  Future<bool> ensurePermissions() async {
    await _health.configure();

    if (!await _health.isHealthConnectAvailable()) return false;

    const permissions = <HealthDataAccess>[
      HealthDataAccess.READ,
      HealthDataAccess.READ,
      HealthDataAccess.READ,
      HealthDataAccess.READ,
      HealthDataAccess.READ,
    ];

    var granted = await _health.hasPermissions(
          types,
          permissions: permissions,
        ) ??
        false;

    if (!granted) {
      granted = await _health.requestAuthorization(
        types,
        permissions: permissions,
      );
    }

    if (await _health.isHealthDataHistoryAvailable() &&
        !await _health.isHealthDataHistoryAuthorized()) {
      await _health.requestHealthDataHistoryAuthorization();
    }

    if (await _health.isHealthDataInBackgroundAvailable() &&
        !await _health.isHealthDataInBackgroundAuthorized()) {
      await _health.requestHealthDataInBackgroundAuthorization();
    }

    return granted;
  }

  Future<HealthSummary> readToday() async {
    await _health.configure();

    final now = DateTime.now();
    final start = DateTime(now.year, now.month, now.day);
    final steps = await _health.getTotalStepsInInterval(start, now) ?? 0;

    final data = await _health.getHealthDataFromTypes(
      startTime: start,
      endTime: now,
      types: types.where((type) => type != HealthDataType.STEPS).toList(),
    );

    final heartRates = <double>[];
    final oxygens = <double>[];
    double? calories;
    var sleepMinutes = 0;

    for (final point in data) {
      if (point.value is! NumericHealthValue) continue;
      final value = (point.value as NumericHealthValue).numericValue.toDouble();

      switch (point.type) {
        case HealthDataType.HEART_RATE:
          heartRates.add(value);
          break;
        case HealthDataType.ACTIVE_ENERGY_BURNED:
          calories = (calories ?? 0) + value;
          break;
        case HealthDataType.BLOOD_OXYGEN:
          oxygens.add(value);
          break;
        case HealthDataType.SLEEP_ASLEEP:
          final from = point.dateFrom.isBefore(start) ? start : point.dateFrom;
          final to = point.dateTo.isAfter(now) ? now : point.dateTo;
          if (to.isAfter(from)) sleepMinutes += to.difference(from).inMinutes;
          break;
        default:
          break;
      }
    }

    final dateKey = start.year.toString().padLeft(4, '0') +
        '-' +
        start.month.toString().padLeft(2, '0') +
        '-' +
        start.day.toString().padLeft(2, '0');

    return HealthSummary(
      dateKey: dateKey,
      steps: steps,
      heartRateAvg: heartRates.isEmpty
          ? null
          : heartRates.reduce((a, b) => a + b) / heartRates.length,
      sleepMinutes: sleepMinutes,
      activeCalories: calories,
      bloodOxygenAvg: oxygens.isEmpty
          ? null
          : oxygens.reduce((a, b) => a + b) / oxygens.length,
    );
  }
}
