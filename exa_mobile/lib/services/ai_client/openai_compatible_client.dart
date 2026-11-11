import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:uuid/uuid.dart';

import 'ai_client.dart';
import 'openai_message_normalizer.dart';

/// Everything shared by backends that speak the OpenAI chat-completions wire
/// format: a self-hosted server ([LocalEndpointClient]) and DeepSeek's cloud
/// API ([DeepSeekClient]) differ only in where the request goes, how it
/// authenticates, and what a failure should be called in front of the user.
///
/// The rest of the app speaks the Anthropic block format, so the translation
/// Anthropic <-> OpenAI lives here, once. Subclasses supply [baseUrl],
/// [serviceName] and [buildHeaders]; anything else they need to change has a
/// hook ([decorateBody], [unreachableMessage], [streamMessage]).
abstract class OpenAiCompatibleClient implements AiClient {
  OpenAiCompatibleClient({http.Client? httpClient})
      : httpClient = httpClient ?? http.Client();

  /// Exposed to subclasses so a provider-specific probe (a `/models` check)
  /// can reuse the same connection.
  final http.Client httpClient;

  static const _uuid = Uuid();

  /// Root of the API, without a trailing `/v1/chat/completions`.
  String get baseUrl;

  /// How this backend is named in an error the user reads. Sentence-initial,
  /// e.g. "DeepSeek" -> "DeepSeek returned no choices".
  String get serviceName;

  /// Headers for one request. [apiKey] is the per-call key the orchestrator
  /// passes; each subclass decides whether that or a stored key wins.
  Map<String, String> buildHeaders(String? apiKey);

  /// Provider-specific request fields. The base fills model, messages,
  /// max_tokens, tools and stream before calling this.
  void decorateBody(Map<String, Object?> body) {}

  /// What to say when the request never reached the server at all.
  String unreachableMessage(Object error) =>
      'Could not reach $serviceName: $error';

  /// Output tokens a caller should ask for on top of the reply it sized,
  /// for a model that deliberates before it answers.
  ///
  /// `max_tokens` counts the deliberation too. A caller sizing a reply at
  /// 512 tokens means 512 tokens of reply; a reasoning model given exactly
  /// that spends it thinking and is cut off before the first word of the
  /// answer. Zero unless a backend says otherwise.
  ///
  /// Added by the callers that size a reply, not to every request. The
  /// routing call already budgets for thinking, and adding this to it as
  /// well turned a 49-second failed route into a 150-second one.
  int get reasoningHeadroom => 0;

  /// [reasoningHeadroom] of any client; zero for one that has no such thing.
  static int headroomOf(AiClient client) =>
      client is OpenAiCompatibleClient ? client.reasoningHeadroom : 0;

  /// Sees every parsed response before the caller does.
  void observeResponse(AiResponse response) {}

  /// Whether this backend can be asked, per request, to answer without
  /// deliberating first (see [createMessage]'s `deliberate`).
  bool get canSkipDeliberation => false;

  /// Set when the server refused a request because of the field that asks
  /// for that. It is then left out for the life of this instance.
  bool _skipRefused = false;

  Duration get requestTimeout => const Duration(minutes: 5);

  // PDF document blocks are Anthropic-specific; the OpenAI chat-completions
  // shape has no equivalent, so extracted text is always the right fallback.
  @override
  bool get supportsPdfDocument => false;

  Uri get chatCompletionsUri =>
      Uri.parse('${trimSlash(baseUrl)}/v1/chat/completions');

  /// [deliberate] false asks a reasoning model to answer straight away.
  ///
  /// For the calls whose answer is a small, fixed shape - routing above all.
  /// Measured on the local server: the same routing answer took 10 tokens
  /// and under a second without deliberation, 70 tokens and four seconds
  /// with it, and on real requests the deliberation alone overran the
  /// call's whole allowance in 99% of runs. A backend that cannot do this
  /// ignores it; one that rejects the request for it is asked again
  /// without, once, and not asked that way again.
  @override
  Future<AiResponse> createMessage({
    String? apiKey,
    required String model,
    required String system,
    required List<Map<String, Object?>> messages,
    List<Map<String, Object?>>? tools,
    int maxTokens = 8192,
    bool deliberate = true,
  }) async {
    final skip = !deliberate && canSkipDeliberation && !_skipRefused;
    try {
      return await _post(
        apiKey: apiKey,
        body: buildBody(
          model: model,
          system: system,
          messages: messages,
          tools: tools,
          maxTokens: maxTokens,
          stream: false,
          deliberate: !skip,
        ),
      );
    } on AiException catch (e) {
      final refused = e.statusCode == 400 || e.statusCode == 422;
      if (!skip || !refused) rethrow;
      _skipRefused = true;
      return _post(
        apiKey: apiKey,
        body: buildBody(
          model: model,
          system: system,
          messages: messages,
          tools: tools,
          maxTokens: maxTokens,
          stream: false,
        ),
      );
    }
  }

  Future<AiResponse> _post({
    required String? apiKey,
    required Map<String, Object?> body,
  }) async {

    // Built before the try: a refusal from [buildHeaders] (no credential) is
    // a configuration error the user can fix, and must not be reported as a
    // network failure.
    final headers = buildHeaders(apiKey);
    http.Response response;
    try {
      response = await httpClient
          .post(chatCompletionsUri, headers: headers, body: jsonEncode(body))
          .timeout(requestTimeout);
    } catch (e) {
      throw AiException(unreachableMessage(e));
    }

    final Map<String, Object?> decoded;
    try {
      decoded = (jsonDecode(response.body) as Map).cast<String, Object?>();
    } catch (_) {
      throw AiException('$serviceName returned an unreadable response '
          '(HTTP ${response.statusCode})');
    }

    throwIfError(response.statusCode, decoded);
    final parsed = fromOpenAiResponse(decoded);
    observeResponse(parsed);
    return parsed;
  }

  /// Streams the OpenAI SSE format, forwarding each text delta to [onText] and
  /// reassembling the same Anthropic block list [createMessage] returns - so
  /// the orchestrator's tool loop sees no difference between the two.
  ///
  /// Backends without real streaming (see [LocalEndpointClient]) override this
  /// with a single [createMessage] call instead.
  @override
  Future<AiResponse> streamMessage({
    String? apiKey,
    required String model,
    required String system,
    required List<Map<String, Object?>> messages,
    List<Map<String, Object?>>? tools,
    int maxTokens = 8192,
    void Function(String delta)? onText,
  }) async {
    final body = buildBody(
      model: model,
      system: system,
      messages: messages,
      tools: tools,
      maxTokens: maxTokens,
      stream: true,
    );

    final request = http.Request('POST', chatCompletionsUri)
      ..headers.addAll(buildHeaders(apiKey))
      ..body = jsonEncode(body);

    http.StreamedResponse response;
    try {
      response = await httpClient.send(request).timeout(requestTimeout);
    } catch (e) {
      throw AiException(unreachableMessage(e));
    }

    if (response.statusCode != 200) {
      final raw = await response.stream.bytesToString();
      Map<String, Object?> decoded;
      try {
        decoded = (jsonDecode(raw) as Map).cast<String, Object?>();
      } catch (_) {
        throw AiException(
          '$serviceName error (HTTP ${response.statusCode})',
          statusCode: response.statusCode,
        );
      }
      throwIfError(response.statusCode, decoded);
    }

    final text = StringBuffer();
    final reasoning = StringBuffer();
    // Tool calls arrive as fragments keyed by their position in the call
    // list: the id and name land on the first fragment, the arguments JSON
    // accumulates over the rest.
    final calls = <int, _StreamingToolCall>{};
    Map<String, Object?>? usage;

    final lines = response.stream
        .transform(utf8.decoder)
        .transform(const LineSplitter());
    await for (final line in lines) {
      if (!line.startsWith('data:')) continue;
      final payload = line.substring(5).trim();
      if (payload.isEmpty || payload == '[DONE]') continue;
      Map<String, Object?> event;
      try {
        event = (jsonDecode(payload) as Map).cast<String, Object?>();
      } catch (_) {
        continue;
      }

      // Some servers report a mid-stream failure as a data event rather than
      // an HTTP status; surface it as the same exception either way.
      if (event['error'] != null) throwIfError(200, event);

      final eventUsage = event['usage'];
      if (eventUsage is Map) usage = eventUsage.cast<String, Object?>();

      final choices = event['choices'];
      if (choices is! List || choices.isEmpty) continue;
      final delta = ((choices.first as Map)['delta'] as Map?)
              ?.cast<String, Object?>() ??
          const {};

      final chunk = delta['content'];
      if (chunk is String && chunk.isNotEmpty) {
        text.write(chunk);
        onText?.call(chunk);
      }
      // Reasoning models stream their chain of thought on a separate field.
      // It is kept out of [onText] - the chat shows the answer, not the
      // deliberation - but preserved as a thinking block.
      final thought = delta['reasoning_content'];
      if (thought is String && thought.isNotEmpty) reasoning.write(thought);

      final toolCalls = delta['tool_calls'];
      if (toolCalls is List) {
        for (final raw in toolCalls.whereType<Map>()) {
          final index = raw['index'] as int? ?? 0;
          final call = calls.putIfAbsent(index, _StreamingToolCall.new);
          final id = raw['id'];
          if (id is String && id.isNotEmpty) call.id = id;
          final function = (raw['function'] as Map?)?.cast<String, Object?>();
          if (function != null) {
            final name = function['name'];
            if (name is String && name.isNotEmpty) call.name = name;
            final arguments = function['arguments'];
            if (arguments is String) call.arguments.write(arguments);
          }
        }
      }
    }

    final content = <Map<String, Object?>>[];
    if (reasoning.isNotEmpty) {
      content.add({'type': 'thinking', 'thinking': reasoning.toString()});
    }
    if (text.isNotEmpty) {
      content.add({'type': 'text', 'text': text.toString()});
    }
    for (final index in calls.keys.toList()..sort()) {
      final call = calls[index]!;
      content.add({
        'type': 'tool_use',
        'id': call.id ?? syntheticToolCallId(),
        'name': call.name,
        'input': decodeArguments(call.arguments.toString()),
      });
    }

    return AiResponse(
      stopReason:
          content.any((b) => b['type'] == 'tool_use') ? 'tool_use' : 'end_turn',
      content: content,
      inputTokens: usage?['prompt_tokens'] as int?,
      outputTokens: usage?['completion_tokens'] as int?,
    );
  }

  /// The request body both paths send. Strict Jinja chat templates reject
  /// sequences the Anthropic block format permits, so repair what we can and
  /// fail loudly on what we cannot - locally, with a message that names the
  /// defect, rather than as an opaque template error from the server.
  Map<String, Object?> buildBody({
    required String model,
    required String system,
    required List<Map<String, Object?>> messages,
    required List<Map<String, Object?>>? tools,
    required int maxTokens,
    required bool stream,
    bool deliberate = true,
  }) {
    final wireMessages =
        normalizeOpenAiMessages(toOpenAiMessages(system, messages));
    validateOpenAiMessageSequence(wireMessages);
    final body = <String, Object?>{
      'model': model,
      'messages': wireMessages,
      'max_tokens': maxTokens,
      'stream': stream,
      if (tools != null && tools.isNotEmpty) 'tools': toOpenAiTools(tools),
      // llama.cpp hands this to the chat template, which is where a
      // reasoning model's thinking is switched.
      if (!deliberate)
        'chat_template_kwargs': const {'enable_thinking': false},
    };
    decorateBody(body);
    return body;
  }

  /// Raises the provider's own error message when the call failed.
  void throwIfError(int statusCode, Map<String, Object?> decoded) {
    if (statusCode == 200 && decoded['error'] == null) return;
    final error = decoded['error'];
    final message = error is Map ? error['message'] : error;
    throw AiException(
      message?.toString() ?? '$serviceName error (HTTP $statusCode)',
      statusCode: statusCode == 200 ? null : statusCode,
    );
  }

  // ------------------------------------------------- request translation --

  List<Map<String, Object?>> toOpenAiTools(List<Map<String, Object?>> tools) =>
      [
        for (final tool in tools)
          {
            'type': 'function',
            'function': {
              'name': tool['name'],
              'description': tool['description'],
              'parameters': tool['input_schema'] ??
                  const {'type': 'object', 'properties': {}},
            },
          },
      ];

  List<Map<String, Object?>> toOpenAiMessages(
    String system,
    List<Map<String, Object?>> messages,
  ) {
    final out = <Map<String, Object?>>[];
    if (system.trim().isNotEmpty) {
      out.add({'role': 'system', 'content': system});
    }
    for (final message in messages) {
      final role = message['role'] as String? ?? 'user';
      final content = message['content'];

      if (content is String) {
        out.add({'role': role, 'content': content});
        continue;
      }
      if (content is! List) continue;
      final blocks = content.cast<Map>();

      if (role == 'assistant') {
        out.add(_assistantBlocksToOpenAi(blocks));
      } else {
        out.addAll(_userBlocksToOpenAi(blocks));
      }
    }
    return out;
  }

  Map<String, Object?> _assistantBlocksToOpenAi(List<Map> blocks) {
    final textParts = <String>[];
    final toolCalls = <Map<String, Object?>>[];
    for (final block in blocks) {
      switch (block['type']) {
        case 'text':
          textParts.add(block['text'] as String? ?? '');
        case 'tool_use':
          toolCalls.add({
            // Preserve the id from the response translation so it pairs with
            // the matching tool result on this same request.
            'id': block['id'] as String? ?? syntheticToolCallId(),
            'type': 'function',
            'function': {
              'name': block['name'],
              'arguments': jsonEncode(block['input'] ?? const {}),
            },
          });
        // 'thinking' and any other block types are dropped. That is required,
        // not incidental: reasoning models reject their own reasoning being
        // fed back in the next request.
      }
    }
    return {
      'role': 'assistant',
      'content': textParts.join(),
      if (toolCalls.isNotEmpty) 'tool_calls': toolCalls,
    };
  }

  /// User turns are either tool_result blocks (each -> a `role: tool`
  /// message) or a rich text/image turn (-> one `role: user` message).
  List<Map<String, Object?>> _userBlocksToOpenAi(List<Map> blocks) {
    final out = <Map<String, Object?>>[];
    final richParts = <Map<String, Object?>>[];
    for (final block in blocks) {
      switch (block['type']) {
        case 'tool_result':
          out.add({
            'role': 'tool',
            'tool_call_id': block['tool_use_id'],
            'content': _stringifyToolResult(block['content']),
          });
        case 'text':
          richParts.add({'type': 'text', 'text': block['text'] ?? ''});
        case 'image':
          final source = (block['source'] as Map?) ?? const {};
          final data = source['data'];
          final mediaType = source['media_type'] ?? 'image/png';
          if (data != null) {
            richParts.add({
              'type': 'image_url',
              'image_url': {'url': 'data:$mediaType;base64,$data'},
            });
          }
      }
    }
    if (richParts.isNotEmpty) {
      out.add({'role': 'user', 'content': richParts});
    }
    return out;
  }

  static String _stringifyToolResult(Object? content) {
    if (content is String) return content;
    return jsonEncode(content);
  }

  // ------------------------------------------------ response translation --

  AiResponse fromOpenAiResponse(Map<String, Object?> decoded) {
    final choices = (decoded['choices'] as List?) ?? const [];
    if (choices.isEmpty) {
      throw AiException('$serviceName returned no choices');
    }
    final choice = (choices.first as Map).cast<String, Object?>();
    final message =
        ((choice['message'] as Map?) ?? const {}).cast<String, Object?>();

    final content = <Map<String, Object?>>[];
    // Reasoning models answer on two fields; the deliberation is kept as a
    // thinking block, which never reaches the user and is dropped when the
    // turn is echoed back.
    final thought = message['reasoning_content'];
    if (thought is String && thought.isNotEmpty) {
      content.add({'type': 'thinking', 'thinking': thought});
    }
    final text = message['content'];
    if (text is String && text.isNotEmpty) {
      content.add({'type': 'text', 'text': text});
    }

    final toolCalls = (message['tool_calls'] as List?) ?? const [];
    for (final raw in toolCalls) {
      final call = (raw as Map).cast<String, Object?>();
      final function =
          ((call['function'] as Map?) ?? const {}).cast<String, Object?>();
      final serverId = call['id'] as String?;
      content.add({
        'type': 'tool_use',
        // Preserve the server's own id when it sends one: strict chat
        // templates (Mistral's 9-char ids) re-validate it when the history
        // is re-rendered next request. Some llama.cpp builds omit it - only
        // then synthesize one. This id is what the orchestrator pairs the
        // tool_result with.
        'id': serverId != null && serverId.isNotEmpty
            ? serverId
            : syntheticToolCallId(),
        'name': function['name'] ?? '',
        'input': decodeArguments(function['arguments']),
      });
    }

    // finish_reason alone can't be trusted: some servers report
    // 'tool_calls' when no call actually parsed. Entering the tool loop
    // with zero tool_use blocks would make the orchestrator send back an
    // empty tool_results message, which strict servers reject - so only
    // report tool_use when there is a call to run.
    final stopReason = content.any((b) => b['type'] == 'tool_use')
        ? 'tool_use'
        : 'end_turn';
    // Most OpenAI-compatible servers report usage; some do not. A missing
    // count is left null rather than guessed at - a fabricated measurement
    // would poison the very calibration it feeds.
    final usage = decoded['usage'];
    return AiResponse(
      stopReason: stopReason,
      content: content,
      inputTokens: usage is Map ? usage['prompt_tokens'] as int? : null,
      outputTokens: usage is Map ? usage['completion_tokens'] as int? : null,
      // Reported by providers that cache prompt prefixes automatically
      // (DeepSeek does; local servers do not).
      cacheReadTokens:
          usage is Map ? usage['prompt_cache_hit_tokens'] as int? : null,
      cacheWriteTokens:
          usage is Map ? usage['prompt_cache_miss_tokens'] as int? : null,
    );
  }

  /// 9 alphanumeric chars: unique enough within a conversation, and matches
  /// the strictest tool-call id format in the wild (Mistral chat templates
  /// require ^[a-zA-Z0-9]{9}$).
  static String syntheticToolCallId() =>
      _uuid.v4().replaceAll('-', '').substring(0, 9);

  static Map<String, Object?> decodeArguments(Object? arguments) {
    if (arguments is Map) return arguments.cast<String, Object?>();
    if (arguments is String && arguments.trim().isNotEmpty) {
      try {
        return (jsonDecode(arguments) as Map).cast<String, Object?>();
      } catch (_) {
        return {'_raw': arguments};
      }
    }
    return const {};
  }

  static String trimSlash(String url) =>
      url.endsWith('/') ? url.substring(0, url.length - 1) : url;

  @override
  void dispose() => httpClient.close();
}

/// One tool call being assembled across SSE fragments.
class _StreamingToolCall {
  String? id;
  String name = '';
  final StringBuffer arguments = StringBuffer();
}
