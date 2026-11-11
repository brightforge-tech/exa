import 'dart:convert';

import 'package:flutter/foundation.dart' show debugPrint;
import 'package:http/http.dart' as http;

import 'ai_client.dart';

/// The remote-AI response/exception types are the shared [AiResponse] /
/// [AiException]; these aliases keep older `ClaudeResponse`/`ClaudeApiException`
/// references (orchestrator, job runner, tests) compiling unchanged.
typedef ClaudeResponse = AiResponse;
typedef ClaudeApiException = AiException;

/// Thin HTTP client for the Anthropic Messages API.
///
/// There is no official Dart SDK, so this speaks the wire format directly:
/// POST /v1/messages with x-api-key + anthropic-version headers.
class ClaudeClient implements AiClient {
  ClaudeClient({http.Client? httpClient})
      : _http = httpClient ?? http.Client();

  final http.Client _http;

  static const _endpoint = 'https://api.anthropic.com/v1/messages';
  static const _apiVersion = '2023-06-01';

  @override
  bool get supportsVision => true;

  @override
  bool get supportsPdfDocument => true;

  @override
  int? get contextWindow => 200000;

  /// Sends one (non-streaming) Messages API request.
  ///
  /// [messages] are raw API message maps ({role, content}) so tool_use /
  /// tool_result / thinking blocks round-trip unchanged through the loop.
  @override
  Future<AiResponse> createMessage({
    String? apiKey,
    required String model,
    required String system,
    required List<Map<String, Object?>> messages,
    List<Map<String, Object?>>? tools,
    int maxTokens = 8192,
  }) async {
    final body = _buildBody(
      model: model,
      system: system,
      messages: messages,
      tools: tools,
      maxTokens: maxTokens,
    );

    http.Response response;
    try {
      response = await _http
          .post(
            Uri.parse(_endpoint),
            headers: {
              'content-type': 'application/json',
              'x-api-key': apiKey ?? '',
              'anthropic-version': _apiVersion,
              // Context editing is still beta; prompt caching and effort are GA.
              'anthropic-beta': 'context-management-2025-06-27',
            },
            body: jsonEncode(body),
          )
          .timeout(const Duration(minutes: 5));
    } catch (e) {
      throw ClaudeApiException(
          'Network error talking to the AI service: $e');
    }

    final Map<String, Object?> decoded;
    try {
      decoded = (jsonDecode(response.body) as Map).cast<String, Object?>();
    } catch (_) {
      throw ClaudeApiException(
          'AI service returned an unreadable response '
          '(HTTP ${response.statusCode})');
    }

    if (response.statusCode != 200) {
      final error = decoded['error'];
      final message = error is Map ? error['message'] : null;
      throw ClaudeApiException(
        message?.toString() ??
            'AI service error (HTTP ${response.statusCode})',
        statusCode: response.statusCode,
      );
    }

    // Surface token usage so cache hit-rate is verifiable from `flutter run` /
    // logcat. cacheRead > 0 on repeat calls means the cache is working;
    // cacheWrite/cacheRead both 0 means the prefix is under the cache minimum.
    final usage = decoded['usage'];
    if (usage is Map) {
      debugPrint('[claude] tokens in=${usage['input_tokens']} '
          'cacheWrite=${usage['cache_creation_input_tokens']} '
          'cacheRead=${usage['cache_read_input_tokens']} '
          'out=${usage['output_tokens']}');
    }

    final content = (decoded['content'] as List? ?? const [])
        .map((block) => (block as Map).cast<String, Object?>())
        .toList();
    return AiResponse(
      stopReason: decoded['stop_reason'] as String? ?? 'end_turn',
      content: content,
      // Cached-read tokens still occupied the context window, so they count
      // toward what the estimator was trying to predict.
      inputTokens: usage is Map
          ? ((usage['input_tokens'] as int? ?? 0) +
              (usage['cache_read_input_tokens'] as int? ?? 0) +
              (usage['cache_creation_input_tokens'] as int? ?? 0))
          : null,
      outputTokens: usage is Map ? usage['output_tokens'] as int? : null,
      cacheReadTokens:
          usage is Map ? usage['cache_read_input_tokens'] as int? : null,
      cacheWriteTokens:
          usage is Map ? usage['cache_creation_input_tokens'] as int? : null,
    );
  }

  /// Streaming variant: parses the Anthropic SSE stream, forwarding each text
  /// delta to [onText] and reconstructing the same content-block list
  /// [createMessage] returns (so tool_use / thinking blocks round-trip through
  /// the loop unchanged).
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
    final body = _buildBody(
      model: model,
      system: system,
      messages: messages,
      tools: tools,
      maxTokens: maxTokens,
    )..['stream'] = true;

    final request = http.Request('POST', Uri.parse(_endpoint))
      ..headers.addAll({
        'content-type': 'application/json',
        'x-api-key': apiKey ?? '',
        'anthropic-version': _apiVersion,
        'anthropic-beta': 'context-management-2025-06-27',
      })
      ..body = jsonEncode(body);

    http.StreamedResponse response;
    try {
      response = await _http.send(request).timeout(const Duration(minutes: 5));
    } catch (e) {
      throw ClaudeApiException(
          'Network error talking to the AI service: $e');
    }

    if (response.statusCode != 200) {
      final raw = await response.stream.bytesToString();
      String? message;
      try {
        final decoded = jsonDecode(raw);
        if (decoded is Map && decoded['error'] is Map) {
          message = (decoded['error'] as Map)['message']?.toString();
        }
      } catch (_) {
        // Non-JSON error body; fall through to the generic message.
      }
      throw ClaudeApiException(
        message ?? 'AI service error (HTTP ${response.statusCode})',
        statusCode: response.statusCode,
      );
    }

    // Content blocks keyed by their stream index; tool_use inputs arrive as
    // partial JSON fragments accumulated until the block closes.
    final blocks = <int, Map<String, Object?>>{};
    final jsonBuffers = <int, StringBuffer>{};
    var stopReason = 'end_turn';

    final lines = response.stream
        .transform(utf8.decoder)
        .transform(const LineSplitter());
    await for (final line in lines) {
      if (!line.startsWith('data:')) continue;
      final payload = line.substring(5).trim();
      if (payload.isEmpty) continue;
      Map<String, Object?> event;
      try {
        event = (jsonDecode(payload) as Map).cast<String, Object?>();
      } catch (_) {
        continue;
      }

      switch (event['type']) {
        case 'content_block_start':
          final index = event['index'] as int? ?? 0;
          final block = ((event['content_block'] as Map?) ?? const {})
              .cast<String, Object?>();
          switch (block['type']) {
            case 'text':
              blocks[index] = {'type': 'text', 'text': block['text'] ?? ''};
            case 'thinking':
              blocks[index] = {
                'type': 'thinking',
                'thinking': block['thinking'] ?? '',
              };
            case 'tool_use':
              blocks[index] = {
                'type': 'tool_use',
                'id': block['id'],
                'name': block['name'],
                'input': <String, Object?>{},
              };
              jsonBuffers[index] = StringBuffer();
            default:
              blocks[index] = block; // e.g. redacted_thinking - pass through
          }
        case 'content_block_delta':
          final index = event['index'] as int? ?? 0;
          final delta =
              ((event['delta'] as Map?) ?? const {}).cast<String, Object?>();
          final block = blocks[index];
          switch (delta['type']) {
            case 'text_delta':
              final text = delta['text'] as String? ?? '';
              if (block != null) {
                block['text'] = (block['text'] as String? ?? '') + text;
              }
              if (text.isNotEmpty) onText?.call(text);
            case 'thinking_delta':
              final t = delta['thinking'] as String? ?? '';
              if (block != null) {
                block['thinking'] =
                    (block['thinking'] as String? ?? '') + t;
              }
            case 'signature_delta':
              final sig = delta['signature'] as String? ?? '';
              if (block != null) {
                block['signature'] =
                    (block['signature'] as String? ?? '') + sig;
              }
            case 'input_json_delta':
              jsonBuffers[index]
                  ?.write(delta['partial_json'] as String? ?? '');
          }
        case 'content_block_stop':
          final index = event['index'] as int? ?? 0;
          final raw = jsonBuffers[index]?.toString() ?? '';
          if (raw.isNotEmpty && blocks[index] != null) {
            try {
              blocks[index]!['input'] =
                  (jsonDecode(raw) as Map).cast<String, Object?>();
            } catch (_) {
              // Leave the empty input map if the fragments don't parse.
            }
          }
        case 'message_delta':
          final delta =
              ((event['delta'] as Map?) ?? const {}).cast<String, Object?>();
          if (delta['stop_reason'] is String) {
            stopReason = delta['stop_reason'] as String;
          }
        case 'error':
          final error = (event['error'] as Map?)?.cast<String, Object?>();
          throw ClaudeApiException(
              error?['message']?.toString() ?? 'AI streaming error');
      }
    }

    final ordered = blocks.keys.toList()..sort();
    return AiResponse(
      stopReason: stopReason,
      content: [for (final i in ordered) blocks[i]!],
    );
  }

  /// Shared request body for [createMessage] / [streamMessage] (no `stream`
  /// flag; the streaming path sets it).
  Map<String, Object?> _buildBody({
    required String model,
    required String system,
    required List<Map<String, Object?>> messages,
    List<Map<String, Object?>>? tools,
    required int maxTokens,
  }) {
    final isHaiku = model.startsWith('claude-haiku');
    final hasTools = tools != null && tools.isNotEmpty;
    return <String, Object?>{
      'model': model,
      'max_tokens': maxTokens,
      // Prompt caching: the system prompt + tool definitions render before the
      // messages and are re-sent on every tool-loop iteration. A cache
      // breakpoint on the (single) system block caches tools + system
      // together; after the first call writes the cache (~1.25x), the rest of
      // the loop and follow-up turns within 5 min read it at ~0.1x. Needs a
      // >=4096-token prefix to take effect on Opus 4.8 (silently skipped
      // otherwise - watch cacheRead in the debug log below).
      'system': [
        {
          'type': 'text',
          'text': system,
          'cache_control': {'type': 'ephemeral'},
        },
      ],
      'messages': messages,
      if (hasTools) 'tools': tools,
      // Adaptive thinking: the model decides when and how deeply to reason.
      // Supported on Fable 5 / Opus 4.x / Sonnet 4.6 but not Haiku, which
      // rejects the parameter - omit it there.
      if (!isHaiku) 'thinking': {'type': 'adaptive'},
      // Medium effort trims output tokens (5x the price of input) and produces
      // fewer, more-consolidated tool calls - so fewer loop round-trips. Haiku
      // rejects output_config.effort, so omit it there.
      if (!isHaiku) 'output_config': {'effort': 'medium'},
      // Context editing: once a tool-heavy turn grows large, clear stale tool
      // results the model has already acted on (browser reads, file text) so
      // they aren't re-sent every iteration. Only relevant when tools are in
      // play; the conservative default thresholds leave short turns untouched.
      if (hasTools)
        'context_management': {
          'edits': [
            {'type': 'clear_tool_uses_20250919'},
          ],
        },
    };
  }

  @override
  void dispose() => _http.close();
}
