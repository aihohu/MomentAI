import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:momentai/l10n/app_localization.dart';

import 'ai_models.dart';
import 'ai_request.dart';

class AiCancellation {
  bool _cancelled = false;
  final _listeners = <void Function()>[];
  bool get isCancelled => _cancelled;
  void check() {
    if (_cancelled) throw const AiCancelled();
  }

  void onCancel(void Function() listener) {
    if (_cancelled) {
      listener();
    } else {
      _listeners.add(listener);
    }
  }

  void cancel() {
    if (_cancelled) return;
    _cancelled = true;
    for (final listener in _listeners) {
      listener();
    }
    _listeners.clear();
  }
}

class AiStreamEvent {
  const AiStreamEvent({
    this.text = '',
    this.totalTokens,
    this.finished = false,
  });
  final String text;
  final int? totalTokens;
  final bool finished;
}

abstract interface class AiProvider {
  Stream<AiStreamEvent> generate(
    AiCredentials credentials,
    List<AiMessage> messages,
    AiCancellation cancellation,
  );
}

class RoutingAiProvider implements AiProvider {
  RoutingAiProvider({
    ChatCompletionsAiProvider? openAiCompatible,
    AnthropicMessagesAiProvider? anthropic,
  }) : _openAiCompatible = openAiCompatible ?? ChatCompletionsAiProvider(),
       _anthropic = anthropic ?? AnthropicMessagesAiProvider();

  final ChatCompletionsAiProvider _openAiCompatible;
  final AnthropicMessagesAiProvider _anthropic;

  @override
  Stream<AiStreamEvent> generate(
    AiCredentials credentials,
    List<AiMessage> messages,
    AiCancellation cancellation,
  ) => switch (credentials.configuration.apiKind) {
    AiApiKind.openAiCompatible => _openAiCompatible.generate(
      credentials,
      messages,
      cancellation,
    ),
    AiApiKind.anthropic => _anthropic.generate(
      credentials,
      messages,
      cancellation,
    ),
  };
}

class AiHttpResponse {
  const AiHttpResponse(this.status, this.contentType, this.body);
  final int status;
  final String contentType;
  final Stream<List<int>> body;
}

abstract interface class AiHttpTransport {
  Future<AiHttpResponse> post(
    Uri uri,
    Map<String, String> headers,
    String body,
  );
  void close();
}

const aiConnectionTimeout = Duration(seconds: 60);

class IoAiHttpTransport implements AiHttpTransport {
  final _client = HttpClient()..connectionTimeout = aiConnectionTimeout;
  @override
  Future<AiHttpResponse> post(
    Uri uri,
    Map<String, String> headers,
    String body,
  ) async {
    final request = await _client.postUrl(uri);
    // Never forward user credentials through a redirect, including same-host redirects.
    request.followRedirects = false;
    headers.forEach(request.headers.set);
    request.add(utf8.encode(body));
    final response = await request.close();
    return AiHttpResponse(
      response.statusCode,
      response.headers.contentType?.mimeType ?? '',
      response,
    );
  }

  @override
  void close() => _client.close(force: true);
}

class ChatCompletionsAiProvider implements AiProvider {
  ChatCompletionsAiProvider({
    AiHttpTransport Function()? transportFactory,
    this.idleTimeout = const Duration(seconds: 60),
    this.totalTimeout = const Duration(minutes: 5),
  }) : _transportFactory = transportFactory ?? IoAiHttpTransport.new;
  final AiHttpTransport Function() _transportFactory;
  final Duration idleTimeout;
  final Duration totalTimeout;

  @override
  Stream<AiStreamEvent> generate(
    AiCredentials credentials,
    List<AiMessage> messages,
    AiCancellation cancellation,
  ) async* {
    cancellation.check();
    final config = credentials.configuration;
    final transport = _transportFactory();
    cancellation.onCancel(transport.close);
    var timedOut = false;
    final deadline = Timer(totalTimeout, () {
      timedOut = true;
      transport.close();
    });
    try {
      final response = await transport
          .post(
            config.endpoint,
            {
              HttpHeaders.authorizationHeader: 'Bearer ${credentials.apiKey}',
              HttpHeaders.contentTypeHeader: 'application/json; charset=utf-8',
              HttpHeaders.acceptHeader: 'text/event-stream',
            },
            jsonEncode({
              'model': config.model,
              'messages': messages.map((item) => item.toMap()).toList(),
              'stream': true,
              if (config.outputTokenLimit != null)
                config.tokenLimitParameter: config.outputTokenLimit,
              if (config.includeUsage)
                'stream_options': {'include_usage': true},
            }),
          )
          .timeout(idleTimeout);
      cancellation.check();
      if (response.status != 200) {
        throw AiFailure(_statusMessage(response.status));
      }
      if (response.contentType != 'text/event-stream') {
        throw AiFailure(l10n.theServiceDidNotReturnSseCheck);
      }
      var stopped = false;
      var done = false;
      var outputLength = 0;
      var bytesReceived = 0;
      var eventBytes = 0;
      var lineLength = 0;
      final dataLines = <String>[];
      final lines = response.body
          .timeout(idleTimeout)
          .map((bytes) {
            bytesReceived += bytes.length;
            for (final byte in bytes) {
              lineLength = byte == 10 || byte == 13 ? 0 : lineLength + 1;
              if (lineLength > 262144) {
                throw AiFailure(l10n.theServiceReturnedADataLineThat);
              }
            }
            if (bytesReceived > 4194304) {
              throw AiFailure(l10n.theResponseExceedsTheSafetyLimit);
            }
            return bytes;
          })
          .transform(utf8.decoder)
          .transform(const LineSplitter());
      await for (final line in lines) {
        cancellation.check();
        if (timedOut) {
          throw AiFailure(l10n.generationTimedOutTryAgainRequestsAre);
        }
        if (line.isNotEmpty) {
          if (line.startsWith('data:')) {
            var value = line.substring(5);
            if (value.startsWith(' ')) value = value.substring(1);
            eventBytes += value.length;
            if (eventBytes > 262144) {
              throw AiFailure(l10n.theServiceReturnedAnEventThatIs);
            }
            dataLines.add(value);
          }
          continue;
        }
        if (dataLines.isEmpty) continue;
        final data = dataLines.join('\n');
        dataLines.clear();
        eventBytes = 0;
        if (data == '[DONE]') {
          done = true;
          break;
        }
        final map = jsonDecode(data) as Map<String, dynamic>;
        if (map['error'] != null) {
          throw AiFailure(l10n.theModelServiceReturnedAnErrorCheck);
        }
        final usage = map['usage'];
        if (usage is Map &&
            usage['total_tokens'] is int &&
            usage['total_tokens'] >= 0) {
          yield AiStreamEvent(totalTokens: usage['total_tokens'] as int);
        }
        final choices = map['choices'];
        if (choices is! List) {
          throw AiFailure(
            l10n.theServiceReturnedAnIncompatibleResponseStructure,
          );
        }
        for (final choice in choices) {
          if (choice is! Map || choice['index'] != 0) continue;
          final delta = choice['delta'];
          if (delta is! Map) {
            throw AiFailure(
              l10n.theServiceReturnedIncompatibleStreamingContent,
            );
          }
          if (delta['tool_calls'] != null || delta['function_call'] != null) {
            throw AiFailure(l10n.toolCallsAreNotSupportedInThis);
          }
          final text = delta['content'] ?? delta['refusal'];
          if (text != null && text is! String) {
            throw AiFailure(l10n.theModelDidNotReturnPlainText);
          }
          if (text is String && text.isNotEmpty) {
            if (stopped) {
              throw AiFailure(l10n.theServiceContinuedSendingTextAfterIts);
            }
            outputLength += text.length;
            if (outputLength > aiMaximumOutputCharacters) {
              throw AiFailure(l10n.theOutputExceedsTheSafetyLimitAnd);
            }
            yield AiStreamEvent(text: text);
          }
          final finish = choice['finish_reason'];
          if (finish != null) {
            if (finish == 'length') {
              throw AiFailure(
                config.outputTokenLimit == null
                    ? l10n.theModelStoppedBeforeCompletionPossiblyDue
                    : l10n.theModelReachedTheTokenOutputBudget(
                        (config.outputTokenLimit).toString(),
                      ),
              );
            }
            if (finish != 'stop') {
              throw AiFailure(l10n.theModelDidNotFinishNormallyPossibly);
            }
            stopped = true;
          }
        }
      }
      cancellation.check();
      if (timedOut) throw AiFailure(l10n.generationTimedOutTryAgainRequestsAre);
      if (!stopped || !done || outputLength == 0) {
        throw AiFailure(l10n.theResponseWasEmptyOrEndedEarly);
      }
      yield const AiStreamEvent(finished: true);
    } on AiFailure {
      rethrow;
    } catch (_) {
      cancellation.check();
      throw AiFailure(
        timedOut
            ? l10n.generationTimedOutTryAgain
            : l10n.aNetworkOrResponseErrorOccurredCheck,
      );
    } finally {
      deadline.cancel();
      transport.close();
    }
  }

  String _statusMessage(int status) => switch (status) {
    401 => l10n.theApiKeyIsInvalidOrExpired,
    403 => l10n.accessWasDeniedCheckAccountPermissionsAnd,
    404 => l10n.theEndpointOrModelWasNotFound,
    429 => l10n.rateLimitOrQuotaReachedTryAgain,
    >= 300 && < 400 => l10n.theEndpointRequestedARedirectTheApi,
    _ => l10n.modelRequestFailedHttpCheckTheEndpoint((status).toString()),
  };
}

class AnthropicMessagesAiProvider implements AiProvider {
  AnthropicMessagesAiProvider({
    AiHttpTransport Function()? transportFactory,
    this.idleTimeout = const Duration(seconds: 60),
    this.totalTimeout = const Duration(minutes: 5),
  }) : _transportFactory = transportFactory ?? IoAiHttpTransport.new;

  final AiHttpTransport Function() _transportFactory;
  final Duration idleTimeout;
  final Duration totalTimeout;

  @override
  Stream<AiStreamEvent> generate(
    AiCredentials credentials,
    List<AiMessage> messages,
    AiCancellation cancellation,
  ) async* {
    cancellation.check();
    final config = credentials.configuration;
    final transport = _transportFactory();
    cancellation.onCancel(transport.close);
    var timedOut = false;
    final deadline = Timer(totalTimeout, () {
      timedOut = true;
      transport.close();
    });
    try {
      final system = messages
          .where((message) => message.role == 'system')
          .map((message) => message.content)
          .join('\n\n');
      final response = await transport
          .post(
            config.endpoint,
            {
              'x-api-key': credentials.apiKey,
              'anthropic-version': '2023-06-01',
              HttpHeaders.contentTypeHeader: 'application/json; charset=utf-8',
              HttpHeaders.acceptHeader: 'text/event-stream',
            },
            jsonEncode({
              'model': config.model,
              if (system.isNotEmpty) 'system': system,
              'messages': messages
                  .where((message) => message.role != 'system')
                  .map((message) => message.toMap())
                  .toList(),
              'stream': true,
              'max_tokens': config.outputTokenLimit!,
            }),
          )
          .timeout(idleTimeout);
      cancellation.check();
      if (response.status != 200) {
        throw AiFailure(_statusMessage(response.status));
      }
      if (response.contentType != 'text/event-stream') {
        throw AiFailure(l10n.theServiceDidNotReturnSseCheck176);
      }

      var outputLength = 0;
      var bytesReceived = 0;
      var lineLength = 0;
      var eventBytes = 0;
      var inputTokens = 0;
      var outputTokens = 0;
      var sawStop = false;
      String? stopReason;
      final dataLines = <String>[];
      final lines = response.body
          .timeout(idleTimeout)
          .map((bytes) {
            bytesReceived += bytes.length;
            for (final byte in bytes) {
              lineLength = byte == 10 || byte == 13 ? 0 : lineLength + 1;
              if (lineLength > 262144) {
                throw AiFailure(l10n.theServiceReturnedADataLineThat);
              }
            }
            if (bytesReceived > 4194304) {
              throw AiFailure(l10n.theResponseExceedsTheSafetyLimit);
            }
            return bytes;
          })
          .transform(utf8.decoder)
          .transform(const LineSplitter());

      await for (final line in lines) {
        cancellation.check();
        if (timedOut) {
          throw AiFailure(l10n.generationTimedOutTryAgainRequestsAre);
        }
        if (line.isNotEmpty) {
          if (line.startsWith('data:')) {
            var value = line.substring(5);
            if (value.startsWith(' ')) value = value.substring(1);
            eventBytes += value.length;
            if (eventBytes > 262144) {
              throw AiFailure(l10n.theServiceReturnedAnEventThatIs);
            }
            dataLines.add(value);
          }
          continue;
        }
        if (dataLines.isEmpty) continue;
        final data = dataLines.join('\n');
        dataLines.clear();
        eventBytes = 0;
        final map = jsonDecode(data) as Map<String, dynamic>;
        final type = map['type'];
        if (type == 'error') {
          throw AiFailure(l10n.theModelServiceReturnedAnErrorCheck);
        }
        if (type == 'message_start') {
          final message = map['message'];
          final usage = message is Map ? message['usage'] : null;
          if (usage is Map && usage['input_tokens'] is int) {
            inputTokens = usage['input_tokens'] as int;
          }
          continue;
        }
        if (type == 'content_block_delta') {
          final delta = map['delta'];
          if (delta is! Map) {
            throw AiFailure(
              l10n.theServiceReturnedIncompatibleStreamingContent,
            );
          }
          if (delta['type'] != 'text_delta') {
            // Ignore documented non-text deltas, but never execute tools.
            continue;
          }
          final text = delta['text'];
          if (text is! String) {
            throw AiFailure(l10n.theModelDidNotReturnPlainText);
          }
          outputLength += text.length;
          if (outputLength > aiMaximumOutputCharacters) {
            throw AiFailure(l10n.theOutputExceedsTheSafetyLimitAnd);
          }
          if (text.isNotEmpty) yield AiStreamEvent(text: text);
          continue;
        }
        if (type == 'message_delta') {
          final delta = map['delta'];
          if (delta is Map) stopReason = delta['stop_reason'] as String?;
          final usage = map['usage'];
          if (usage is Map && usage['output_tokens'] is int) {
            outputTokens = usage['output_tokens'] as int;
            yield AiStreamEvent(totalTokens: inputTokens + outputTokens);
          }
          continue;
        }
        if (type == 'message_stop') {
          sawStop = true;
          break;
        }
        // ping and future event types are deliberately ignored.
      }
      cancellation.check();
      if (timedOut) throw AiFailure(l10n.generationTimedOutTryAgainRequestsAre);
      if (stopReason == 'max_tokens') {
        throw AiFailure(l10n.theModelReachedItsOutputLimitThe);
      }
      if (!sawStop ||
          outputLength == 0 ||
          !['end_turn', 'stop_sequence'].contains(stopReason)) {
        throw AiFailure(l10n.theResponseWasEmptyOrEndedEarly);
      }
      yield AiStreamEvent(
        totalTokens: inputTokens + outputTokens,
        finished: true,
      );
    } on AiFailure {
      rethrow;
    } catch (_) {
      cancellation.check();
      throw AiFailure(
        timedOut
            ? l10n.generationTimedOutTryAgain
            : l10n.aNetworkOrResponseErrorOccurredCheck,
      );
    } finally {
      deadline.cancel();
      transport.close();
    }
  }

  String _statusMessage(int status) => switch (status) {
    401 => l10n.theApiKeyIsInvalidOrExpired,
    403 => l10n.accessWasDeniedCheckAccountPermissionsAnd,
    404 => l10n.theEndpointOrModelWasNotFound,
    429 => l10n.rateLimitOrQuotaReachedTryAgain,
    >= 300 && < 400 => l10n.theEndpointRequestedARedirectTheApi,
    _ => l10n.modelRequestFailedHttpCheckTheEndpoint((status).toString()),
  };
}
