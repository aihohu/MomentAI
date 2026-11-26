import 'dart:convert';

import 'package:momentai/l10n/app_localization.dart';

import 'ai_models.dart';

class AiMessage {
  const AiMessage(this.role, this.content);
  final String role;
  final String content;
  Map<String, String> toMap() => {'role': role, 'content': content};
}

/// Immutable request presented to the user before a single paid network call.
class AiPreparedRequest {
  AiPreparedRequest._({
    required this.credentials,
    required this.source,
    required this.kind,
    required this.question,
    required this.messages,
    required this.historyCount,
    required this.omittedHistoryCount,
    this.conversationId,
  });
  final AiCredentials credentials;
  final AiSourceSnapshot source;
  final AiRunKind kind;
  final String question;
  final List<AiMessage> messages;
  final int historyCount;
  final int omittedHistoryCount;
  final String? conversationId;
  int get characterCount =>
      messages.fold(0, (sum, item) => sum + item.content.length);
  String get preview => messages
      .where((item) => item.role != 'system')
      .map((item) => '${item.role}:\n${item.content}')
      .join('\n\n');

  static AiPreparedRequest create({
    required AiCredentials credentials,
    required AiSourceSnapshot source,
    required AiRunKind kind,
    required AiDocument document,
    String question = '',
    String? conversationId,
  }) {
    if (document.sessionId != source.sessionId || source.text.trim().isEmpty) {
      throw AiFailure(l10n.thisRecordingHasNoUsableTextFor);
    }
    if (document.runs.length >= 100) {
      throw AiFailure(l10n.thisRecordingHasSavedAiResultsDelete);
    }
    question = question.trim();
    if (kind == AiRunKind.chat &&
        (question.isEmpty || question.length > 4000)) {
      throw AiFailure(l10n.enterAQuestionOfNoMoreThan);
    }
    if (kind == AiRunKind.chat &&
        (conversationId == null ||
            !document.conversations.any(
              (conversation) => conversation.id == conversationId,
            ))) {
      throw AiFailure(l10n.thisConversationNoLongerExistsCreateOr);
    }
    final allHistory = document.runs
        .where(
          (run) =>
              run.kind == AiRunKind.chat &&
              run.conversationId == conversationId,
        )
        .toList();
    final eligible = allHistory
        .where(
          (run) =>
              run.status == AiRunStatus.complete &&
              run.sourceFingerprint == source.fingerprint,
        )
        .toList();
    // Explicit, bounded context window; old/failed/source-stale turns are not evidence.
    final recent = kind == AiRunKind.chat
        ? eligible.skip(eligible.length > 6 ? eligible.length - 6 : 0).toList()
        : <AiRun>[];
    final messages = <AiMessage>[
      AiMessage('system', l10n.youAreARecordingAssistantAnswerOnly),
      AiMessage(
        'user',
        l10n.theFollowingJsonContainsTheCompleteText(
          (jsonEncode(source.payload)).toString(),
        ),
      ),
      for (final run in recent) ...[
        AiMessage('user', run.question),
        AiMessage('assistant', run.text),
      ],
      AiMessage(
        'user',
        kind == AiRunKind.summary
            ? l10n.organizeThisRecordingUseExactlyTheFollowing
            : question,
      ),
    ];
    final request = AiPreparedRequest._(
      credentials: credentials,
      source: source,
      kind: kind,
      question: kind == AiRunKind.chat ? question : '',
      messages: List.unmodifiable(messages),
      historyCount: recent.length,
      omittedHistoryCount: kind == AiRunKind.chat
          ? allHistory.length - recent.length
          : 0,
      conversationId: kind == AiRunKind.chat ? conversationId : null,
    );
    return request;
  }
}
