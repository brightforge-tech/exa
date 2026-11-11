import '../../agent/behaviors/token_estimator.dart';
import '../../data/repositories/settings_repository.dart';
import 'ai_client.dart';
import 'openai_compatible_client.dart';

/// Talks to a local, OpenAI-compatible chat-completions server
/// (Ollama, LM Studio, llama.cpp's server, etc.).
///
/// The wire translation lives in [OpenAiCompatibleClient]; what is specific
/// here is that the endpoint, the loaded model's capabilities and the context
/// size are all things only the user can tell us.
class LocalEndpointClient extends OpenAiCompatibleClient {
  LocalEndpointClient({
    required this.baseUrl,
    this.apiKey,
    super.httpClient,
  });

  /// Base URL of the server, e.g. `http://10.0.2.2:11434` (Android emulator
  /// reaching a host Ollama) or `http://192.168.1.20:1234` (LM Studio on the
  /// LAN). The `/v1/chat/completions` path is appended. Mutable so the single
  /// provider-held instance can be re-pointed from settings each turn.
  @override
  String baseUrl;

  /// Optional bearer token, from Settings > AI provider. Ollama and llama.cpp
  /// ignore it; LM Studio with auth on, an OpenAI-compatible gateway or a
  /// tunnel that guards the endpoint require it. Set on this instance each
  /// turn alongside [baseUrl], and null when the user has stored none - in
  /// which case a placeholder still goes out, so a server that merely demands
  /// the header is satisfied.
  String? apiKey;

  @override
  String get serviceName => 'Local AI server';

  /// Local servers run on whatever hardware the user has: a slow model plus
  /// a long prompt can legitimately grind for many minutes, and with no
  /// streaming there is no early sign of life. Give up far later than the
  /// cloud default so a working-but-slow reply is not reported as
  /// unreachable.
  @override
  Duration get requestTimeout => const Duration(minutes: 15);

  @override
  Map<String, String> buildHeaders(String? apiKey) {
    final stored = this.apiKey;
    final key = (stored != null && stored.isNotEmpty)
        ? stored
        : (apiKey != null && apiKey.isNotEmpty ? apiKey : 'local');
    return {
      'content-type': 'application/json',
      'authorization': 'Bearer $key',
    };
  }

  @override
  String unreachableMessage(Object error) =>
      'Could not reach the local AI server at $baseUrl: $error';

  /// llama.cpp, and servers built on it, take the switch per request. One
  /// that does not know the field ignores it.
  @override
  bool get canSkipDeliberation => true;

  /// Room for a model's thinking when nothing has been seen of it yet.
  ///
  /// Whether the loaded model reasons is as unknowable from here as whether
  /// it sees images, but guessing wrong is cheap in one direction only. To a
  /// model that does not think this is an unused ceiling. To one that does,
  /// its absence was the reply failing quietly: the call that writes it
  /// stopped at exactly 512 tokens having written none of it, and the repair
  /// that followed, which sees no tool results, wrote "I read your tasks" in
  /// place of the tasks. It is a default rather than something learned
  /// because a background run starts in a fresh isolate, with nothing seen.
  static const defaultReasoningHeadroom = 2048;

  /// However long the thinking, a call is never given more than this for it.
  static const maxReasoningHeadroom = 4096;

  int _reasoningHeadroom = defaultReasoningHeadroom;

  /// Grows, within the two bounds, to twice the longest deliberation this
  /// instance has seen.
  @override
  int get reasoningHeadroom => _reasoningHeadroom;

  @override
  void observeResponse(AiResponse response) {
    var thought = 0;
    for (final block in response.content) {
      if (block['type'] != 'thinking') continue;
      thought += TokenEstimator.estimate('${block['thinking'] ?? ''}');
    }
    final wanted = (thought * 2)
        .clamp(defaultReasoningHeadroom, maxReasoningHeadroom);
    if (wanted > _reasoningHeadroom) _reasoningHeadroom = wanted;
  }

  /// Whether the model currently loaded on the server can read images.
  ///
  /// Unknowable from here - one endpoint serves whatever model the user
  /// loaded - so the orchestrator sets it from the user's declaration in
  /// Settings > AI provider each turn, the same way it sets [baseUrl].
  /// Defaults to off so a text-only server never receives image parts.
  @override
  bool supportsVision = false;

  /// Context the loaded model was started with, in tokens.
  ///
  /// Unknowable from here - one endpoint serves whatever the user launched,
  /// with whatever `--ctx-size` they chose - so the orchestrator sets it
  /// from Settings > AI provider each turn, the same way it sets [baseUrl].
  /// Guessing too high is the expensive mistake: the request is rejected
  /// outright rather than degraded, so the default is conservative.
  @override
  int? contextWindow = SettingsRepository.defaultLocalContextTokens;

  /// No token streaming yet for the local server: run the normal request and
  /// hand the whole text back in one [onText] call so the chat UI shows it.
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
    final response = await createMessage(
      apiKey: apiKey,
      model: model,
      system: system,
      messages: messages,
      tools: tools,
      maxTokens: maxTokens,
    );
    if (response.text.isNotEmpty) onText?.call(response.text);
    return response;
  }
}
