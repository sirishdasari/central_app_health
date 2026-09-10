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
    required this.link,
    required this.category,
    required this.level,
  });

  final String id;
  final String title;
  final bool completed;
  final String suggestedTime;
  final int duration;
  final String description;
  final int dailyPracticeTime;
  final String link;
  final String category;
  final String level;

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
      link: data['link']?.toString() ?? '',
      category: data['category']?.toString() ?? '',
      level: data['level']?.toString() ?? '',
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
    const pageSize = 100;
    final documents = <Document>[];
    var offset = 0;

    while (true) {
      final result = await _databases.listDocuments(
        databaseId: AppwriteConfig.databaseId,
        collectionId: collectionId,
        queries: [Query.limit(pageSize), Query.offset(offset)],
      );
      documents.addAll(result.documents);
      if (result.documents.length < pageSize) break;
      offset += pageSize;
    }

    final practices = documents
        .map(GuitarPractice.fromDocument)
        .toList(growable: false);

    return GuitarPracticeResponse(
      date: _dateString(DateTime.now()),
      dailyPracticeTime:
          practices.isEmpty ? 0 : practices.first.dailyPracticeTime,
      practices: practices,
    );
  }

  Future<void> recordPractice(
    String id, {
    required int practicedSeconds,
    required DateTime practiceDate,
  }) async {
    _validateConfig();
    if (id.trim().isEmpty) throw Exception('Practice id is empty');
    if (practicedSeconds <= 0) throw Exception('No practice time to record');

    await _databases.updateDocument(
      databaseId: AppwriteConfig.databaseId,
      collectionId: collectionId,
      documentId: id,
      data: {'completed': true},
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
    if (value.containsKey('duration') && value['duration'] is num) {
      data['duration'] = (value['duration'] as num).toInt();
    }
    if (value.containsKey('description')) {
      data['description'] = value['description']?.toString() ?? '';
    }
    if (value.containsKey('dailyPracticeTime') &&
        value['dailyPracticeTime'] is num) {
      data['dailyPracticeTime'] =
          (value['dailyPracticeTime'] as num).toInt();
    }
    if (value.containsKey('link')) {
      data['link'] = value['link']?.toString().trim() ?? '';
    }
    if (value.containsKey('category')) {
      data['category'] = value['category']?.toString().trim() ?? '';
    }
    if (value.containsKey('level')) {
      final level = value['level']?.toString().trim() ?? '';
      if (level.isNotEmpty) data['level'] = level;
    }

    return data;
  }

  String _dateString(DateTime value) =>
      '${value.year.toString().padLeft(4, '0')}-'
      '${value.month.toString().padLeft(2, '0')}-'
      '${value.day.toString().padLeft(2, '0')}';
}
