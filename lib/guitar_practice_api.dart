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

  factory GuitarPractice.fromDocument(Document document) {
    final data = document.data;
    return GuitarPractice(
      id: document.$id,
      title: data['sessionName']?.toString() ?? data['title']?.toString() ?? '',
      completed: data['completed'] == true,
      suggestedTime: data['suggestedTime']?.toString() ?? '',
      duration: (data['duration'] as num?)?.toInt() ?? 0,
      description: data['description']?.toString() ?? '',
      dailyPracticeTime: (data['dailyPracticeTime'] as num?)?.toInt() ?? 0,
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

class GuitarPracticeApi {
  static const String collectionId = 'guitarPractice';

  final Client _client = Client()
      .setEndpoint(AppwriteConfig.endpoint)
      .setProject(AppwriteConfig.projectId);

  late final Databases _databases = Databases(_client);

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

    // Appwrite 17.1 Databases API uses the system attribute
    // literally as '$createdAt'. Do NOT escape the '$' in a raw string.
    final result = await _databases.listDocuments(
      databaseId: AppwriteConfig.databaseId,
      collectionId: collectionId,
      queries: [
        Query.orderDesc(r'$createdAt'),
        Query.limit(100),
      ],
    );

    final documents = result.documents;
    if (documents.isEmpty) {
      return GuitarPracticeResponse(
        date: _dateString(DateTime.now()),
        dailyPracticeTime: 0,
        practices: const [],
      );
    }

    final today = _dateString(DateTime.now());
    final dated = <_DatedDocument>[];

    for (final document in documents) {
      final createdAt = document.$createdAt;
      if (createdAt.isEmpty) continue;

      final parsed = DateTime.tryParse(createdAt);
      if (parsed == null) continue;

      dated.add(_DatedDocument(
        document: document,
        date: _dateString(parsed.toLocal()),
        createdAt: parsed,
      ));
    }

    if (dated.isEmpty) {
      final practices = documents
          .map(GuitarPractice.fromDocument)
          .toList(growable: false);
      return GuitarPracticeResponse(
        date: today,
        dailyPracticeTime:
            practices.isEmpty ? 0 : practices.first.dailyPracticeTime,
        practices: practices,
      );
    }

    final hasToday = dated.any((item) => item.date == today);
    final selectedDate = hasToday
        ? today
        : dated.map((item) => item.date).reduce(
            (a, b) => a.compareTo(b) > 0 ? a : b,
          );

    final selected = dated.where((item) => item.date == selectedDate).toList()
      ..sort((a, b) => a.createdAt.compareTo(b.createdAt));

    final practices = selected
        .map((item) => GuitarPractice.fromDocument(item.document))
        .toList(growable: false);

    return GuitarPracticeResponse(
      date: selectedDate,
      dailyPracticeTime:
          practices.isEmpty ? 0 : practices.first.dailyPracticeTime,
      practices: practices,
    );
  }

  Future<void> create(Map<String, dynamic> value) async {
    _validateConfig();
    await _databases.createDocument(
      databaseId: AppwriteConfig.databaseId,
      collectionId: collectionId,
      documentId: ID.unique(),
      data: _toAppwriteData(value),
    );
  }

  Future<void> update(String id, Map<String, dynamic> value) async {
    _validateConfig();
    if (id.trim().isEmpty) throw Exception('Practice id is empty');

    final data = _toAppwriteData(value);
    if (data.isEmpty) return;

    await _databases.updateDocument(
      databaseId: AppwriteConfig.databaseId,
      collectionId: collectionId,
      documentId: id,
      data: data,
    );
  }

  Future<void> delete(String id) async {
    _validateConfig();
    if (id.trim().isEmpty) throw Exception('Practice id is empty');

    await _databases.deleteDocument(
      databaseId: AppwriteConfig.databaseId,
      collectionId: collectionId,
      documentId: id,
    );
  }

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
      if (practiceTime is num) data['dailyPracticeTime'] = practiceTime.toInt();
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

class _DatedDocument {
  const _DatedDocument({
    required this.document,
    required this.date,
    required this.createdAt,
  });

  final Document document;
  final String date;
  final DateTime createdAt;
}
