import 'dart:convert';

import 'package:http/http.dart' as http;

import 'ai_client.dart';
import 'openai_compatible_client.dart';

/// Talks to DeepSeek's cloud API.
///
/// DeepSeek speaks the OpenAI chat-completions format, so everything about
/// the conversation - tools, tool results, streaming, usage - is the shared
/// [OpenAiCompatibleClient] translation. What is specific to DeepSeek is the
/// endpoint, a required API key, a real context window we know up front, and
/// two output limits that differ between the chat and the reasoning model.
class DeepSeekClient extends OpenAiCompatibleClient {
  DeepSeekClient({
    String baseUrl = defaultBaseUrl,
    this.apiKey,
    super.httpClient,
  }) {
    // Through the setter, so a construction-time value gets the same
    // empty-means-default treatment as one set later from Settings.
    this.baseUrl = baseUrl;
  }

  static const defaultBaseUrl = 'https://api.deepseek.com';

  /// Both DeepSeek models hold 128K of context.
  static const int contextTokens = 128000;

  /// Ceiling on `max_tokens`. DeepSeek rejects a request that asks for more
  /// than the model can emit, so the request is trimmed here rather than
  /// bounced: `deepseek-chat` tops out at 8K output tokens, the reasoning
  /// model much higher (its chain of thought is counted against the same
  /// budget).
  static const int maxOutputTokens = 8192;
  static const int maxReasonerOutputTokens = 65536;

  /// Overridable so a corporate proxy or gateway can be pointed at instead.
  /// A trailing `/v1` is tolerated - the path is appended by the base class.
  String _baseUrl = defaultBaseUrl;

  @override
  String get baseUrl {
    final trimmed = OpenAiCompatibleClient.trimSlash(_baseUrl.trim());
    return trimmed.endsWith('/v1')
        ? trimmed.substring(0, trimmed.length - 3)
        : trimmed;
  }

  set baseUrl(String value) =>
      _baseUrl = value.trim().isEmpty ? defaultBaseUrl : value;

  /// The stored key. The orchestrator passes the key per call as well; either
  /// route works, and the per-call one wins.
  String? apiKey;

  @override
  String get serviceName => 'DeepSeek';

  // No vision in the DeepSeek API: image parts are rejected outright rather
  // than ignored, so callers must substitute a text note instead.
  @override
  bool get supportsVision => false;

  @override
  int? get contextWindow => contextTokens;

  @override
  Map<String, String> buildHeaders(String? apiKey) {
    final key = (apiKey?.isNotEmpty ?? false) ? apiKey : this.apiKey;
    if (key == null || key.isEmpty) {
      // Caught here rather than as a 401 from the server, because the fix is
      // a specific screen in this app.
      throw const AiException(
          'No DeepSeek API key is set. Add one in Settings > AI provider.');
    }
    return {
      'content-type': 'application/json',
      'authorization': 'Bearer $key',
    };
  }

  @override
  String unreachableMessage(Object error) =>
      'Could not reach DeepSeek: $error';

  @override
  Map<String, Object?> buildBody({
    required String model,
    required String system,
    required List<Map<String, Object?>> messages,
    required List<Map<String, Object?>>? tools,
    required int maxTokens,
    required bool stream,
    bool deliberate = true,
  }) =>
      super.buildBody(
        model: model,
        system: system,
        messages: messages,
        tools: tools,
        maxTokens: maxTokens.clamp(
            1, isReasoningModel(model) ? maxReasonerOutputTokens : maxOutputTokens),
        stream: stream,
        deliberate: deliberate,
      );

  @override
  void decorateBody(Map<String, Object?> body) {
    // Usage only rides along on the final streamed chunk when asked for, and
    // it is the only ground truth the token estimator gets to calibrate on -
    // including the cache hit/miss split, which is how "is the prefix
    // actually being reused?" stays answerable.
    if (body['stream'] == true) {
      body['stream_options'] = const {'include_usage': true};
    }
  }

  /// The reasoning model emits its chain of thought before the answer, which
  /// counts against the output budget - hence the far larger ceiling.
  static bool isReasoningModel(String model) => model.contains('reasoner');

  /// Lists the model ids this key can use, for the Settings connection test.
  /// Throws [AiException] the same way a chat request would.
  Future<List<String>> listModels({String? apiKey}) async {
    final headers = buildHeaders(apiKey);
    http.Response response;
    try {
      response = await httpClient
          .get(Uri.parse('$baseUrl/v1/models'), headers: headers)
          .timeout(const Duration(seconds: 20));
    } catch (e) {
      throw AiException(unreachableMessage(e));
    }
    final Map<String, Object?> decoded;
    try {
      decoded = (jsonDecode(response.body) as Map).cast<String, Object?>();
    } catch (_) {
      throw AiException('DeepSeek returned an unreadable response '
          '(HTTP ${response.statusCode})');
    }
    throwIfError(response.statusCode, decoded);
    return [
      for (final row in (decoded['data'] as List? ?? const []).whereType<Map>())
        if (row['id'] is String) row['id'] as String,
    ];
  }
}
