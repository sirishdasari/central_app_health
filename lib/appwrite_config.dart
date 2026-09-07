class AppwriteConfig {
  static const endpoint = String.fromEnvironment('APPWRITE_ENDPOINT', defaultValue: 'https://cloud.appwrite.io/v1');
  static const projectId = String.fromEnvironment('APPWRITE_PROJECT_ID');
  static const databaseId = String.fromEnvironment('APPWRITE_DATABASE_ID', defaultValue: 'main');
  static const activitiesCollectionId = String.fromEnvironment('APPWRITE_ACTIVITIES_COLLECTION_ID', defaultValue: 'activities');
}
