import 'package:appwrite/appwrite.dart';
import 'package:appwrite/models.dart';
import 'appwrite_config.dart';

class GuitarPractice {
  const GuitarPractice({
    required this.id,
    required this.title,
    required this.completed,
    required this.suggestedTime,
    required this.duration,
    required this.description,
    required this.dailyPracticeTime,
  });

  final String id;
  final String title;
  final bool completed;
  final String suggestedTime;
  final int duration;
  final String description;
  final int dailyPracticeTime;

  factory GuitarPractice.fromRow(Row row) {
    final data = row.data;

    return GuitarPractice(
      id: row.$id,
      title: data['sessionName']?.toString() ?? '',
      completed: data['completed'] == true,
      suggestedTime: data['suggestedTime']?.toString() ?? '',
      duration: (data['duration'] as num?)?.toInt() ?? 0,
      description: data['description']?.toString() ?? '',
      dailyPracticeTime:
          (data['dailyPracticeTime'] as num?)?.toInt() ?? 0,
    );
  }
}

class GuitarPracticeResponse {
  const GuitarPracticeResponse({
    required this.date,
    required this.dailyPracticeTime,
    required this.practices,
  });

  final String date;
  final int dailyPracticeTime;
  final List<GuitarPractice> practices;
}

/// Direct Appwrite Cloud access for the guitarPractice table.
///
/// The table ID is intentionally hardcoded as requested.
/// Define the Appwrite endpoint, project ID and database ID through
/// AppwriteConfig / --dart-define.
class GuitarPracticeApi {
  static const String tableId = 'guitarPractice';

  final Client _client = Client()
      .setEndpoint(AppwriteConfig.endpoint)
      .setProject(AppwriteConfig.projectId);

  late final TablesDB _tablesDB = TablesDB(_client);

  void _validateConfig() {
    if (AppwriteConfig.projectId.isEmpty) {
      throw Exception('APPWRITE_PROJECT_ID is not configured');
    }
    if (AppwriteConfig.databaseId.isEmpty) {
      throw Exception('APPWRITE_DATABASE_ID is not configured');
    }
  }

  Future<GuitarPracticeResponse> list() async {
    _validateConfig();

    final result = await _tablesDB.listRows(
      databaseId: AppwriteConfig.databaseId,
      tableId: tableId,
      queries: [
        Query.orderDesc('\$createdAt'),
        Query.limit(100),
      ],
      total: false,
    );

    final rows = result.rows;
    if (rows.isEmpty) {
      return GuitarPracticeResponse(
        date: _dateString(DateTime.now()),
        dailyPracticeTime: 0,
        practices: const [],
      );
    }

    // Keep the same behaviour as the existing Python endpoint:
    // use today's rows when available; otherwise use the newest
    // practice date in the table.
    final localToday = _dateString(DateTime.now());

    final datedRows = <_DatedRow>[];
    for (final row in rows) {
      final createdAt = row.\$createdAt;
      if (createdAt.isEmpty) continue;

      final parsed = DateTime.tryParse(createdAt);
      if (parsed == null) continue;

      datedRows.add(
        _DatedRow(
          row: row,
          date: _dateString(parsed.toLocal()),
          createdAt: parsed,
        ),
      );
    }

    if (datedRows.isEmpty) {
      final practices = rows.map(GuitarPractice.fromRow).toList();
      return GuitarPracticeResponse(
        date: localToday,
        dailyPracticeTime:
            practices.isEmpty ? 0 : practices.first.dailyPracticeTime,
        practices: practices,
      );
    }

    final hasToday = datedRows.any((item) => item.date == localToday);
    final selectedDate = hasToday
        ? localToday
        : datedRows.map((item) => item.date).reduce(
            (a, b) => a.compareTo(b) > 0 ? a : b,
          );

    final selected = datedRows
        .where((item) => item.date == selectedDate)
        .toList()
      ..sort((a, b) => a.createdAt.compareTo(b.createdAt));

    final practices =
        selected.map((item) => GuitarPractice.fromRow(item.row)).toList();

    return GuitarPracticeResponse(
      date: selectedDate,
      dailyPracticeTime:
          practices.isEmpty ? 0 : practices.first.dailyPracticeTime,
      practices: practices,
    );
  }

  Future<void> create(Map<String, dynamic> value) async {
    _validateConfig();

    await _tablesDB.createRow(
      databaseId: AppwriteConfig.databaseId,
      tableId: tableId,
      rowId: ID.unique(),
      data: _toAppwriteData(value),
    );
  }

  Future<void> update(String id, Map<String, dynamic> value) async {
    _validateConfig();

    if (id.trim().isEmpty) {
      throw Exception('Practice id is empty');
    }

    final data = _toAppwriteData(value);
    if (data.isEmpty) return;

    await _tablesDB.updateRow(
      databaseId: AppwriteConfig.databaseId,
      tableId: tableId,
      rowId: id,
      data: data,
    );
  }

  Future<void> delete(String id) async {
    _validateConfig();

    if (id.trim().isEmpty) {
      throw Exception('Practice id is empty');
    }

    await _tablesDB.deleteRow(
      databaseId: AppwriteConfig.databaseId,
      tableId: tableId,
      rowId: id,
    );
  }

  /// Converts the public app model names to the actual guitarPractice
  /// table column names. Unknown fields are intentionally ignored.
  ///
  /// This is important for Bluetooth progress payloads: fields such as
  /// practicedSeconds are not sent to Appwrite unless they are explicitly
  /// represented by a guitarPractice column.
  Map<String, dynamic> _toAppwriteData(Map<String, dynamic> value) {
    final data = <String, dynamic>{};

    if (value.containsKey('title')) {
      data['sessionName'] = value['title']?.toString() ?? '';
    }
    if (value.containsKey('completed')) {
      data['completed'] = value['completed'] == true;
    }
    if (value.containsKey('suggestedTime')) {
      data['suggestedTime'] = value['suggestedTime']?.toString() ?? '';
    }
    if (value.containsKey('duration')) {
      final duration = value['duration'];
      if (duration is num) data['duration'] = duration.toInt();
    }
    if (value.containsKey('description')) {
      data['description'] = value['description']?.toString() ?? '';
    }
    if (value.containsKey('dailyPracticeTime')) {
      final practiceTime = value['dailyPracticeTime'];
      if (practiceTime is num) {
        data['dailyPracticeTime'] = practiceTime.toInt();
      }
    }

    return data;
  }

  String _dateString(DateTime value) {
    final y = value.year.toString().padLeft(4, '0');
    final m = value.month.toString().padLeft(2, '0');
    final d = value.day.toString().padLeft(2, '0');
    return '$y-$m-$d';
  }
}

class _DatedRow {
  const _DatedRow({
    required this.row,
    required this.date,
    required this.createdAt,
  });

  final Row row;
  final String date;
  final DateTime createdAt;
}
