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

    // Do not filter tasks by their creation date. A guitar practice task
    // remains visible regardless of when it was created.
    //
    // Appwrite limits a single query page, so fetch all pages in batches of
    // 100. This keeps the phone screen in sync even when there are many tasks.
    const pageSize = 100;
    final documents = <Document>[];
    var offset = 0;

    while (true) {
      final result = await _databases.listDocuments(
        databaseId: AppwriteConfig.databaseId,
        collectionId: collectionId,
        queries: [
          Query.orderDesc(r'\$createdAt'),
          Query.limit(pageSize),
          Query.offset(offset),
        ],
      );

      documents.addAll(result.documents);

      if (result.documents.length < pageSize) break;
      offset += pageSize;
    }

    if (documents.isEmpty) {
      return GuitarPracticeResponse(
        date: _dateString(DateTime.now()),
        dailyPracticeTime: 0,
        practices: const [],
      );
    }

    final practices = documents
        .map(GuitarPractice.fromDocument)
        .toList(growable: false);

    return GuitarPracticeResponse(
      date: _dateString(DateTime.now()),
      dailyPracticeTime: practices.first.dailyPracticeTime,
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
