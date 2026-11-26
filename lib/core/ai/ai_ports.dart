import 'ai_models.dart';

abstract interface class AiCredentialStore {
  Future<AiCredentialCatalog> read();
  Future<void> save(AiCredentialCatalog catalog);
  Future<void> delete();
}

abstract interface class AiDocumentStore {
  Future<AiDocument> read(String sessionId);
  Future<void> save(AiDocument document);
}
