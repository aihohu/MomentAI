import 'dart:convert';
import 'dart:math';

import 'package:crypto/crypto.dart';
import 'package:momentai/l10n/app_localization.dart';

const aiPromptVersion = 4;
// Transport and persistence protection, not a model capability or product limit.
const aiMaximumOutputCharacters = 4 * 1024 * 1024;
const aiMaximumServices = 20;
const aiMaximumModelsPerService = 50;
const aiMaximumConversations = 30;
const aiRemoteProcessingConsentVersion = 1;

class AiFailure implements Exception {
  const AiFailure(this.message);
  final String message;
  @override
  String toString() => message;
}

class AiCancelled extends AiFailure {
  const AiCancelled() : super('');
  @override
  String get message => l10n.generationStoppedTheProviderMayStillCharge;
}

enum AiApiKind { openAiCompatible, anthropic }

extension AiApiKindPresentation on AiApiKind {
  String get label => switch (this) {
    AiApiKind.openAiCompatible => 'OpenAI Compatible',
    AiApiKind.anthropic => 'Anthropic Messages',
  };
}

void _validateHttpsBaseUrl(String value) {
  final uri = Uri.tryParse(value);
  if (uri == null ||
      uri.scheme != 'https' ||
      uri.host.isEmpty ||
      uri.userInfo.isNotEmpty ||
      uri.hasQuery ||
      uri.hasFragment ||
      value.contains(RegExp(r'[\s\x00-\x1f\x7f]')) ||
      value.length > 2048) {
    throw AiFailure(l10n.theApiUrlMustUseHttpsAnd);
  }
}

void _validateIdentifier(String value, String message) {
  if (value.isEmpty ||
      value.length > 200 ||
      value.contains(RegExp(r'[\x00-\x1f\x7f]'))) {
    throw AiFailure(message);
  }
}

class AiModelProfile {
  AiModelProfile({
    required String id,
    required String name,
    required String modelId,
    this.outputTokenLimit,
    this.tokenLimitParameter = 'max_tokens',
    this.includeUsage = false,
  }) : id = id.trim(),
       name = name.trim(),
       modelId = modelId.trim() {
    _validateIdentifier(this.id, l10n.invalidModelConfigurationId);
    _validateIdentifier(this.name, l10n.enterAModelDisplayName);
    _validateIdentifier(this.modelId, l10n.enterAValidModelId);
    if ((outputTokenLimit != null && outputTokenLimit! <= 0) ||
        ![
          'max_tokens',
          'max_completion_tokens',
        ].contains(tokenLimitParameter)) {
      throw AiFailure(l10n.theOutputTokenBudgetMustBeA);
    }
  }

  factory AiModelProfile.fromMap(Map<String, dynamic> map) => AiModelProfile(
    id: map['id'] as String,
    name: map['name'] as String,
    modelId: map['modelId'] as String,
    outputTokenLimit: map['outputTokenLimit'] as int?,
    tokenLimitParameter: map['tokenLimitParameter'] as String? ?? 'max_tokens',
    includeUsage: map['includeUsage'] == true,
  );

  final String id;
  final String name;
  final String modelId;
  final int? outputTokenLimit;
  final String tokenLimitParameter;
  final bool includeUsage;

  Map<String, Object> toMap() => {
    'id': id,
    'name': name,
    'modelId': modelId,
    'outputTokenLimit': ?outputTokenLimit,
    'tokenLimitParameter': tokenLimitParameter,
    'includeUsage': includeUsage,
  };
}

class AiServiceProfile {
  AiServiceProfile({
    required String id,
    required String name,
    required this.apiKind,
    required String baseUrl,
    required Iterable<AiModelProfile> models,
    this.revision = 1,
  }) : id = id.trim(),
       name = name.trim(),
       baseUrl = baseUrl.trim().replaceAll(RegExp(r'/+$'), ''),
       models = List.unmodifiable(models) {
    _validateIdentifier(this.id, l10n.invalidServiceConfigurationId);
    _validateIdentifier(this.name, l10n.enterAServiceName);
    _validateHttpsBaseUrl(this.baseUrl);
    if (this.models.isEmpty || this.models.length > aiMaximumModelsPerService) {
      throw AiFailure(l10n.eachServiceMustHaveModels);
    }
    if (this.models.map((model) => model.id).toSet().length !=
        this.models.length) {
      throw AiFailure(l10n.modelConfigurationIdsMustBeUniqueWithin);
    }
    if (revision < 1) throw AiFailure(l10n.invalidServiceConfigurationVersion);
  }

  factory AiServiceProfile.fromMap(Map<String, dynamic> map) =>
      AiServiceProfile(
        id: map['id'] as String,
        name: map['name'] as String,
        apiKind: AiApiKind.values.byName(map['apiKind'] as String),
        baseUrl: map['baseUrl'] as String,
        models: (map['models'] as List).map(
          (value) =>
              AiModelProfile.fromMap(Map<String, dynamic>.from(value as Map)),
        ),
        revision: map['revision'] as int? ?? 1,
      );

  final String id;
  final String name;
  final AiApiKind apiKind;
  final String baseUrl;
  final List<AiModelProfile> models;
  final int revision;

  Uri get endpoint {
    if (apiKind == AiApiKind.openAiCompatible) {
      return Uri.parse(
        baseUrl.endsWith('/chat/completions')
            ? baseUrl
            : '$baseUrl/chat/completions',
      );
    }
    if (baseUrl.endsWith('/v1/messages')) return Uri.parse(baseUrl);
    if (baseUrl.endsWith('/v1')) return Uri.parse('$baseUrl/messages');
    return Uri.parse('$baseUrl/v1/messages');
  }

  Map<String, Object> toMap() => {
    'id': id,
    'name': name,
    'apiKind': apiKind.name,
    'baseUrl': baseUrl,
    'models': models.map((model) => model.toMap()).toList(),
    'revision': revision,
  };
}

class AiServiceCredentials {
  AiServiceCredentials(this.service, String apiKey) : apiKey = apiKey.trim() {
    if (this.apiKey.isEmpty ||
        this.apiKey.length > 8192 ||
        this.apiKey.contains(RegExp(r'[\s\x00-\x1f\x7f]'))) {
      throw AiFailure(l10n.enterAValidApiKeyWithoutWhitespace);
    }
  }
  final AiServiceProfile service;
  final String apiKey;
  @override
  String toString() => 'AiServiceCredentials(${service.id}, [redacted])';
}

/// The entire catalog is kept in OS secure storage because it contains keys.
class AiCredentialCatalog {
  AiCredentialCatalog({
    required Iterable<AiServiceCredentials> services,
    this.defaultSummaryServiceId,
    this.defaultSummaryModelId,
    this.defaultChatServiceId,
    this.defaultChatModelId,
    this.remoteProcessingConsentVersion = 0,
  }) : services = List.unmodifiable(services) {
    if (this.services.length > aiMaximumServices ||
        this.services.map((value) => value.service.id).toSet().length !=
            this.services.length) {
      throw AiFailure(l10n.invalidServiceCountOrServiceId);
    }
    final modelIds = this.services
        .expand((value) => value.service.models)
        .map((model) => model.id)
        .toList();
    if (modelIds.toSet().length != modelIds.length) {
      throw AiFailure(l10n.modelConfigurationIdsMustBeUniqueAcross);
    }
    if (remoteProcessingConsentVersion < 0 ||
        remoteProcessingConsentVersion > aiRemoteProcessingConsentVersion) {
      throw AiFailure(l10n.invalidConsentVersionExistingSecureDataIs);
    }
  }

  factory AiCredentialCatalog.empty() =>
      AiCredentialCatalog(services: const []);

  final List<AiServiceCredentials> services;
  final String? defaultSummaryServiceId;
  final String? defaultSummaryModelId;
  final String? defaultChatServiceId;
  final String? defaultChatModelId;
  final int remoteProcessingConsentVersion;

  bool get isEmpty => services.isEmpty;
  bool get hasRemoteProcessingConsent =>
      remoteProcessingConsentVersion == aiRemoteProcessingConsentVersion;

  AiCredentialCatalog withRemoteProcessingConsent({required bool granted}) =>
      AiCredentialCatalog(
        services: services,
        defaultSummaryServiceId: defaultSummaryServiceId,
        defaultSummaryModelId: defaultSummaryModelId,
        defaultChatServiceId: defaultChatServiceId,
        defaultChatModelId: defaultChatModelId,
        remoteProcessingConsentVersion: granted
            ? aiRemoteProcessingConsentVersion
            : 0,
      );

  AiCredentials resolve(
    AiRunKind kind, {
    String? serviceId,
    String? modelProfileId,
  }) {
    if (services.isEmpty) {
      throw AiFailure(l10n.addAModelServiceAndApiKey);
    }
    serviceId ??= kind == AiRunKind.summary
        ? defaultSummaryServiceId
        : defaultChatServiceId;
    modelProfileId ??= kind == AiRunKind.summary
        ? defaultSummaryModelId
        : defaultChatModelId;
    var selectedService = services.first;
    if (serviceId != null) {
      selectedService = services.firstWhere(
        (value) => value.service.id == serviceId,
        orElse: () => services.first,
      );
    } else if (modelProfileId != null) {
      selectedService = services.firstWhere(
        (value) =>
            value.service.models.any((model) => model.id == modelProfileId),
        orElse: () => services.first,
      );
    }
    final models = selectedService.service.models;
    final model = modelProfileId == null
        ? models.first
        : models.firstWhere(
            (value) => value.id == modelProfileId,
            orElse: () => models.first,
          );
    return AiCredentials(
      AiConfiguration.fromProfiles(selectedService.service, model),
      selectedService.apiKey,
    );
  }
}

/// Immutable selected request configuration. Credentials are never serialized here.
class AiConfiguration {
  AiConfiguration({
    required String baseUrl,
    required String model,
    this.outputTokenLimit,
    this.tokenLimitParameter = 'max_tokens',
    this.includeUsage = false,
    this.apiKind = AiApiKind.openAiCompatible,
    this.serviceId = 'legacy-service',
    this.serviceName = 'OpenAI Compatible',
    this.modelProfileId = 'legacy-model',
    String? modelName,
    this.serviceRevision = 1,
  }) : baseUrl = baseUrl.trim().replaceAll(RegExp(r'/+$'), ''),
       model = model.trim(),
       modelName = (modelName ?? model).trim() {
    _validateHttpsBaseUrl(this.baseUrl);
    _validateIdentifier(this.model, l10n.enterAValidModelId);
    _validateIdentifier(this.modelName, l10n.enterAModelDisplayName);
    if ((outputTokenLimit != null && outputTokenLimit! <= 0) ||
        ![
          'max_tokens',
          'max_completion_tokens',
        ].contains(tokenLimitParameter)) {
      throw AiFailure(l10n.theOutputTokenBudgetMustBeA);
    }
    if (apiKind == AiApiKind.anthropic && outputTokenLimit == null) {
      throw AiFailure(l10n.anthropicMessagesRequiresAnOutputTokenBudget);
    }
  }

  factory AiConfiguration.fromProfiles(
    AiServiceProfile service,
    AiModelProfile model,
  ) => AiConfiguration(
    baseUrl: service.baseUrl,
    model: model.modelId,
    outputTokenLimit: model.outputTokenLimit,
    tokenLimitParameter: model.tokenLimitParameter,
    includeUsage: model.includeUsage,
    apiKind: service.apiKind,
    serviceId: service.id,
    serviceName: service.name,
    modelProfileId: model.id,
    modelName: model.name,
    serviceRevision: service.revision,
  );

  factory AiConfiguration.fromMap(Map<String, dynamic> map) => AiConfiguration(
    baseUrl: map['baseUrl'] as String,
    model: map['model'] as String,
    outputTokenLimit: map['outputTokenLimit'] as int?,
    tokenLimitParameter: map['tokenLimitParameter'] as String? ?? 'max_tokens',
    includeUsage: map['includeUsage'] == true,
  );

  final String baseUrl;
  final String model;
  final String modelName;
  final int? outputTokenLimit;
  final String tokenLimitParameter;
  final bool includeUsage;
  final AiApiKind apiKind;
  final String serviceId;
  final String serviceName;
  final String modelProfileId;
  final int serviceRevision;

  Uri get endpoint {
    if (apiKind == AiApiKind.openAiCompatible) {
      return Uri.parse(
        baseUrl.endsWith('/chat/completions')
            ? baseUrl
            : '$baseUrl/chat/completions',
      );
    }
    if (baseUrl.endsWith('/v1/messages')) return Uri.parse(baseUrl);
    if (baseUrl.endsWith('/v1')) return Uri.parse('$baseUrl/messages');
    return Uri.parse('$baseUrl/v1/messages');
  }

  Map<String, Object> toMap() => {
    'baseUrl': baseUrl,
    'model': model,
    'outputTokenLimit': ?outputTokenLimit,
    'tokenLimitParameter': tokenLimitParameter,
    'includeUsage': includeUsage,
  };
}

class AiCredentials {
  AiCredentials(this.configuration, String apiKey) : apiKey = apiKey.trim() {
    if (this.apiKey.isEmpty ||
        this.apiKey.length > 8192 ||
        this.apiKey.contains(RegExp(r'[\s\x00-\x1f\x7f]'))) {
      throw AiFailure(l10n.enterAValidApiKeyWithoutWhitespace);
    }
  }
  final AiConfiguration configuration;
  final String apiKey;
  @override
  String toString() => 'AiCredentials([redacted])';
}

/// Input boundary: no native runtime, audio path, platform or playback dependency.
class AiSourceSnapshot {
  AiSourceSnapshot({
    required this.sessionId,
    required this.title,
    required this.text,
    required this.textLayer,
    required this.hasGaps,
    this.speakerText,
  });
  final String sessionId;
  final String title;
  final String text;
  final String textLayer;
  final bool hasGaps;
  final Map<String, Object?>? speakerText;
  Map<String, Object> get payload => {
    'title': title,
    'textLayer': textLayer,
    'hasConfirmedGaps': hasGaps,
    'text': text,
    'speakerText': ?speakerText,
  };
  String get fingerprint => sha256
      .convert(utf8.encode(jsonEncode({'sessionId': sessionId, ...payload})))
      .toString();
}

enum AiRunKind { summary, chat }

enum AiRunStatus { running, complete, failed, interrupted }

class AiRun {
  const AiRun({
    required this.id,
    required this.kind,
    required this.status,
    required this.question,
    required this.text,
    required this.sourceFingerprint,
    required this.textLayer,
    required this.hasGaps,
    required this.model,
    required this.endpoint,
    required this.createdAt,
    this.serviceId = 'legacy-service',
    this.modelProfileId = 'legacy-model',
    this.conversationId,
    this.error,
    this.totalTokens,
    this.promptVersion = aiPromptVersion,
  });

  factory AiRun.fromMap(Map<String, dynamic> map) => AiRun(
    id: map['id'] as String,
    kind: AiRunKind.values.byName(map['kind'] as String),
    status: AiRunStatus.values.byName(map['status'] as String),
    question: map['question'] as String,
    text: map['text'] as String,
    sourceFingerprint: map['sourceFingerprint'] as String,
    textLayer: map['textLayer'] as String,
    hasGaps: map['hasGaps'] as bool,
    model: map['model'] as String,
    endpoint: map['endpoint'] as String,
    createdAt: DateTime.parse(map['createdAt'] as String),
    serviceId: map['serviceId'] as String? ?? 'legacy-service',
    modelProfileId: map['modelProfileId'] as String? ?? 'legacy-model',
    conversationId: map['conversationId'] as String?,
    error: map['error'] as String?,
    totalTokens: map['totalTokens'] as int?,
    promptVersion: map['promptVersion'] as int? ?? 1,
  );
  final String id;
  final AiRunKind kind;
  final AiRunStatus status;
  final String question;
  final String text;
  final String sourceFingerprint;
  final String textLayer;
  final bool hasGaps;
  final String model;
  final String endpoint;
  final String serviceId;
  final String modelProfileId;
  final String? conversationId;
  final DateTime createdAt;
  final String? error;
  final int? totalTokens;
  final int promptVersion;

  AiRun withResult({
    required AiRunStatus status,
    required String text,
    String? error,
    int? totalTokens,
  }) => AiRun(
    id: id,
    kind: kind,
    status: status,
    question: question,
    text: text,
    sourceFingerprint: sourceFingerprint,
    textLayer: textLayer,
    hasGaps: hasGaps,
    model: model,
    endpoint: endpoint,
    serviceId: serviceId,
    modelProfileId: modelProfileId,
    conversationId: conversationId,
    createdAt: createdAt,
    error: error,
    totalTokens: totalTokens,
    promptVersion: promptVersion,
  );

  Map<String, Object?> toMap() => {
    'id': id,
    'kind': kind.name,
    'status': status.name,
    'question': question,
    'text': text,
    'sourceFingerprint': sourceFingerprint,
    'textLayer': textLayer,
    'hasGaps': hasGaps,
    'model': model,
    'endpoint': endpoint,
    'serviceId': serviceId,
    'modelProfileId': modelProfileId,
    'conversationId': conversationId,
    'createdAt': createdAt.toUtc().toIso8601String(),
    'error': error,
    'totalTokens': totalTokens,
    'promptVersion': promptVersion,
  };
}

class AiConversation {
  const AiConversation({
    required this.id,
    required this.title,
    required this.createdAt,
    required this.updatedAt,
  });
  factory AiConversation.fromMap(Map<String, dynamic> map) => AiConversation(
    id: map['id'] as String,
    title: map['title'] as String,
    createdAt: DateTime.parse(map['createdAt'] as String),
    updatedAt: DateTime.parse(map['updatedAt'] as String),
  );
  final String id;
  final String title;
  final DateTime createdAt;
  final DateTime updatedAt;
  AiConversation copyWith({String? title, DateTime? updatedAt}) =>
      AiConversation(
        id: id,
        title: title ?? this.title,
        createdAt: createdAt,
        updatedAt: updatedAt ?? this.updatedAt,
      );
  Map<String, Object> toMap() => {
    'id': id,
    'title': title,
    'createdAt': createdAt.toUtc().toIso8601String(),
    'updatedAt': updatedAt.toUtc().toIso8601String(),
  };
}

class AiConsentGrant {
  const AiConsentGrant({
    required this.serviceId,
    required this.serviceRevision,
    required this.grantedAt,
    this.scopeVersion = 1,
  });
  factory AiConsentGrant.fromMap(Map<String, dynamic> map) => AiConsentGrant(
    serviceId: map['serviceId'] as String,
    serviceRevision: map['serviceRevision'] as int,
    grantedAt: DateTime.parse(map['grantedAt'] as String),
    scopeVersion: map['scopeVersion'] as int? ?? 1,
  );
  final String serviceId;
  final int serviceRevision;
  final DateTime grantedAt;
  final int scopeVersion;
  Map<String, Object> toMap() => {
    'serviceId': serviceId,
    'serviceRevision': serviceRevision,
    'grantedAt': grantedAt.toUtc().toIso8601String(),
    'scopeVersion': scopeVersion,
  };
}

class AiDocument {
  AiDocument(
    this.sessionId,
    Iterable<AiRun> runs, {
    Iterable<AiConversation> conversations = const [],
    Iterable<AiConsentGrant> consentGrants = const [],
  }) : runs = List.unmodifiable(runs),
       conversations = List.unmodifiable(conversations),
       consentGrants = List.unmodifiable(consentGrants);

  factory AiDocument.fromMap(Map<String, dynamic> map, String sessionId) {
    final schemaVersion = map['schemaVersion'];
    if (![1, 2].contains(schemaVersion) || map['sessionId'] != sessionId) {
      throw AiFailure(l10n.theAiDataVersionOrRecordingDoes);
    }
    var runs = (map['runs'] as List)
        .map((value) => AiRun.fromMap(Map<String, dynamic>.from(value as Map)))
        .toList();
    var conversations = <AiConversation>[];
    var grants = <AiConsentGrant>[];
    if (schemaVersion == 2) {
      conversations = (map['conversations'] as List? ?? const [])
          .map(
            (value) =>
                AiConversation.fromMap(Map<String, dynamic>.from(value as Map)),
          )
          .toList();
      grants = (map['consentGrants'] as List? ?? const [])
          .map(
            (value) =>
                AiConsentGrant.fromMap(Map<String, dynamic>.from(value as Map)),
          )
          .toList();
    } else if (runs.any((run) => run.kind == AiRunKind.chat)) {
      final chatRuns = runs.where((run) => run.kind == AiRunKind.chat).toList();
      const legacyId = 'legacy-conversation';
      conversations = [
        AiConversation(
          id: legacyId,
          title: l10n.previousConversation,
          createdAt: chatRuns.first.createdAt,
          updatedAt: chatRuns.last.createdAt,
        ),
      ];
      runs = runs
          .map(
            (run) => run.kind == AiRunKind.chat
                ? AiRun(
                    id: run.id,
                    kind: run.kind,
                    status: run.status,
                    question: run.question,
                    text: run.text,
                    sourceFingerprint: run.sourceFingerprint,
                    textLayer: run.textLayer,
                    hasGaps: run.hasGaps,
                    model: run.model,
                    endpoint: run.endpoint,
                    serviceId: run.serviceId,
                    modelProfileId: run.modelProfileId,
                    conversationId: legacyId,
                    createdAt: run.createdAt,
                    error: run.error,
                    totalTokens: run.totalTokens,
                    promptVersion: run.promptVersion,
                  )
                : run,
          )
          .toList();
    }
    final document = AiDocument(
      sessionId,
      runs,
      conversations: conversations,
      consentGrants: grants,
    );
    document._validate();
    return document;
  }

  final String sessionId;
  final List<AiRun> runs;
  final List<AiConversation> conversations;
  final List<AiConsentGrant> consentGrants;

  void _validate() {
    if (runs.length > 200 ||
        conversations.length > aiMaximumConversations ||
        runs.map((run) => run.id).toSet().length != runs.length ||
        conversations.map((value) => value.id).toSet().length !=
            conversations.length ||
        runs.any(
          (run) =>
              run.text.length > aiMaximumOutputCharacters ||
              run.question.length > 4000 ||
              (run.kind == AiRunKind.chat &&
                  run.conversationId != null &&
                  !conversations.any(
                    (value) => value.id == run.conversationId,
                  )),
        )) {
      throw AiFailure(l10n.aiDataExceedsTheSafetyLimitExisting);
    }
  }

  Map<String, Object> toMap() => {
    'schemaVersion': 2,
    'sessionId': sessionId,
    'runs': runs.map((run) => run.toMap()).toList(),
    'conversations': conversations.map((value) => value.toMap()).toList(),
    'consentGrants': consentGrants.map((value) => value.toMap()).toList(),
  };
}

String newAiId() => List.generate(
  16,
  (_) => Random.secure().nextInt(256).toRadixString(16).padLeft(2, '0'),
).join();
