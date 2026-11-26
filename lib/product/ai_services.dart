import '../core/ai/ai_ports.dart';
import '../core/ai/ai_provider.dart';
import '../core/ai/ai_storage.dart';

class AiServices {
  AiServices({
    required this.credentials,
    required this.provider,
    required this.documentStore,
  });
  factory AiServices.platform() => AiServices(
    credentials: SecureAiCredentialStore(),
    provider: RoutingAiProvider(),
    documentStore: FileAiDocumentStore.new,
  );
  final AiCredentialStore credentials;
  final AiProvider provider;
  final AiDocumentStore Function(String directory) documentStore;
}
