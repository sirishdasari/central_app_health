import 'package:shared_preferences/shared_preferences.dart';

class GuitarPracticeStreak {
  static const _qualifiedDatesKey = 'guitar_qualified_practice_dates';
  static const targetMinutes = 15;

  Future<int> updateForToday(int todayMinutes) async {
    final prefs = await SharedPreferences.getInstance();
    final today = _date(DateTime.now());
    final dates = (prefs.getStringList(_qualifiedDatesKey) ?? <String>[]).toSet();

    if (todayMinutes >= targetMinutes) {
      dates.add(today);
    }

    // Keep a bounded history while retaining enough dates for streaks.
    final sorted = dates.toList()..sort();
    final kept = sorted.length > 730 ? sorted.sublist(sorted.length - 730) : sorted;
    await prefs.setStringList(_qualifiedDatesKey, kept);

    return _currentStreak(kept, DateTime.now());
  }

  Future<int> current() async {
    final prefs = await SharedPreferences.getInstance();
    return _currentStreak(prefs.getStringList(_qualifiedDatesKey) ?? const <String>[], DateTime.now());
  }

  int _currentStreak(List<String> qualifiedDates, DateTime now) {
    final dates = qualifiedDates.toSet();
    var day = DateTime(now.year, now.month, now.day);

    // During today, the existing streak remains visible until the day ends.
    if (!dates.contains(_date(day))) {
      day = day.subtract(const Duration(days: 1));
      if (!dates.contains(_date(day))) return 0;
    }

    var streak = 0;
    while (dates.contains(_date(day))) {
      streak++;
      day = day.subtract(const Duration(days: 1));
    }
    return streak;
  }

  String _date(DateTime value) =>
      '${value.year.toString().padLeft(4, '0')}-'
      '${value.month.toString().padLeft(2, '0')}-'
      '${value.day.toString().padLeft(2, '0')}';
}
