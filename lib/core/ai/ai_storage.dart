import 'dart:convert';
import 'dart:io';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:momentai/l10n/app_localization.dart';

import 'ai_models.dart';
import 'ai_ports.dart';

/// Credentials stay in OS secure storage, never in Session data or exports.
class SecureAiCredentialStore implements AiCredentialStore {
  SecureAiCredentialStore({FlutterSecureStorage? storage})
    : _storage =
          storage ??
          const FlutterSecureStorage(
            iOptions: IOSOptions(
              accountName: 'org.hohu.momentai.ai',
              accessibility: KeychainAccessibility.unlocked_this_device,
              synchronizable: false,
            ),
            aOptions: AndroidOptions(
              storageNamespace: 'momentai_ai',
              resetOnError: false,
              migrateWithBackup: true,
            ),
          );
  static const storageKey = 'momentai.ai.credentials.v2';
  static const legacyStorageKey = 'momentai.ai.credentials.v1';
  final FlutterSecureStorage _storage;

  @override
  Future<AiCredentialCatalog> read() async {
    try {
      final raw = await _storage.read(key: storageKey);
      if (raw != null) return _decodeCatalog(raw);
      final legacy = await _storage.read(key: legacyStorageKey);
      if (legacy == null) return AiCredentialCatalog.empty();
      return _decodeLegacy(legacy);
    } on AiFailure {
      rethrow;
    } catch (_) {
      throw AiFailure(l10n.couldNotReadSecureStorageUnlockYour);
    }
  }

  AiCredentialCatalog _decodeCatalog(String raw) {
    final map = jsonDecode(raw) as Map<String, dynamic>;
    if (map['schemaVersion'] != 2) {
      throw AiFailure(l10n.unsupportedAiSettingsVersionExistingSecureData);
    }
    return AiCredentialCatalog(
      services: (map['services'] as List).map((value) {
        final item = Map<String, dynamic>.from(value as Map);
        return AiServiceCredentials(
          AiServiceProfile.fromMap(
            Map<String, dynamic>.from(item['service'] as Map),
          ),
          item['apiKey'] as String,
        );
      }),
      defaultSummaryServiceId: map['defaultSummaryServiceId'] as String?,
      defaultSummaryModelId: map['defaultSummaryModelId'] as String?,
      defaultChatServiceId: map['defaultChatServiceId'] as String?,
      defaultChatModelId: map['defaultChatModelId'] as String?,
      remoteProcessingConsentVersion:
          map['remoteProcessingConsentVersion'] as int? ?? 0,
    );
  }

  AiCredentialCatalog _decodeLegacy(String raw) {
    final map = jsonDecode(raw) as Map<String, dynamic>;
    final configuration = AiConfiguration.fromMap(
      Map<String, dynamic>.from(map['configuration'] as Map),
    );
    final model = AiModelProfile(
      id: 'migrated-model-v1',
      name: configuration.model,
      modelId: configuration.model,
      outputTokenLimit: configuration.outputTokenLimit,
      tokenLimitParameter: configuration.tokenLimitParameter,
      includeUsage: configuration.includeUsage,
    );
    final service = AiServiceCredentials(
      AiServiceProfile(
        id: 'migrated-service-v1',
        name: 'OpenAI Compatible',
        apiKind: AiApiKind.openAiCompatible,
        baseUrl: configuration.baseUrl,
        models: [model],
      ),
      map['apiKey'] as String,
    );
    return AiCredentialCatalog(
      services: [service],
      defaultSummaryServiceId: service.service.id,
      defaultSummaryModelId: model.id,
      defaultChatServiceId: service.service.id,
      defaultChatModelId: model.id,
    );
  }

  @override
  Future<void> save(AiCredentialCatalog catalog) async {
    try {
      final value = jsonEncode({
        'schemaVersion': 2,
        'services': catalog.services
            .map(
              (item) => {
                'service': item.service.toMap(),
                'apiKey': item.apiKey,
              },
            )
            .toList(),
        'defaultSummaryServiceId': catalog.defaultSummaryServiceId,
        'defaultSummaryModelId': catalog.defaultSummaryModelId,
        'defaultChatServiceId': catalog.defaultChatServiceId,
        'defaultChatModelId': catalog.defaultChatModelId,
        'remoteProcessingConsentVersion':
            catalog.remoteProcessingConsentVersion,
      });
      await _storage.write(key: storageKey, value: value);
      if (await _storage.read(key: storageKey) != value) {
        throw StateError('readback');
      }
      // The v1 value intentionally remains as a non-destructive fallback.
    } catch (_) {
      throw AiFailure(l10n.couldNotSaveSecurelyTryAgainThe);
    }
  }

  @override
  Future<void> delete() async {
    try {
      await _storage.delete(key: storageKey);
      await _storage.delete(key: legacyStorageKey);
      if (await _storage.containsKey(key: storageKey) ||
          await _storage.containsKey(key: legacyStorageKey)) {
        throw StateError('delete');
      }
    } catch (_) {
      throw AiFailure(l10n.couldNotDeleteCredentialsFromSecureStorage);
    }
  }
}

/// Additive derived data in an existing Session. Never creates a Session directory.
/// The v1 file remains untouched; successful writes use a separate v2 file.
class FileAiDocumentStore implements AiDocumentStore {
  FileAiDocumentStore(this.directory);
  final String directory;
  static const fileName = 'ai_workspace_v2.json';
  static const legacyFileName = 'ai_workspace_v1.json';
  static const maxBytes = 8 * 1024 * 1024;
  File get _file => File('$directory/$fileName');
  File get _legacyFile => File('$directory/$legacyFileName');

  Future<void> _checkDirectory() async {
    if (await FileSystemEntity.type(directory, followLinks: false) !=
        FileSystemEntityType.directory) {
      throw AiFailure(l10n.theRecordingFolderIsUnavailableAiResults);
    }
    for (final file in [_file, _legacyFile]) {
      final type = await FileSystemEntity.type(file.path, followLinks: false);
      if (type != FileSystemEntityType.notFound &&
          type != FileSystemEntityType.file) {
        throw AiFailure(l10n.invalidAiDataPathWritingStopped);
      }
    }
  }

  @override
  Future<AiDocument> read(String sessionId) async {
    try {
      await _checkDirectory();
      final source = await _file.exists()
          ? _file
          : await _legacyFile.exists()
          ? _legacyFile
          : null;
      if (source == null) return AiDocument(sessionId, const []);
      if (await source.length() > maxBytes) throw StateError('size');
      return AiDocument.fromMap(
        jsonDecode(await source.readAsString()) as Map<String, dynamic>,
        sessionId,
      );
    } on AiFailure {
      rethrow;
    } catch (_) {
      throw AiFailure(l10n.couldNotReadLocalAiDataExisting);
    }
  }

  @override
  Future<void> save(AiDocument document) async {
    final partial = File('$directory/.$fileName.${newAiId()}.part');
    try {
      await _checkDirectory();
      final bytes = utf8.encode(jsonEncode(document.toMap()));
      if (bytes.length > maxBytes) {
        throw AiFailure(l10n.aiHistoryIsTooLargeDeleteUnneeded);
      }
      await partial.writeAsBytes(bytes, flush: true);
      await _checkDirectory();
      await partial.rename(_file.path);
    } on AiFailure {
      rethrow;
    } catch (_) {
      throw AiFailure(l10n.aiResultsHaveNotBeenSavedCheck);
    } finally {
      try {
        if (await partial.exists()) await partial.delete();
      } catch (_) {
        /* A failed temporary-file cleanup must not mask save status. */
      }
    }
  }
}
