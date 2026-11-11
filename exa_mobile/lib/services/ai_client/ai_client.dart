/// Provider-agnostic AI client interface.
///
/// The app speaks the Anthropic Messages wire format internally (the
/// orchestrator and tool registry build `tool_use` / `tool_result` blocks
/// directly), so that format is the lingua franca. Non-Anthropic backends
/// (a local OpenAI-compatible server, an on-device model) implement this
/// interface and translate to/from their own wire format at the boundary.
abstract class AiClient {
  /// Sends one (non-streaming) request. [messages] and [tools] are in
  /// Anthropic block format; the returned [AiResponse.content] is too, so it
  /// round-trips back through the orchestrator's tool loop unchanged.
  ///
  /// [apiKey] is only meaningful for the remote provider; local backends
  /// ignore it.
  Future<AiResponse> createMessage({
    String? apiKey,
    required String model,
    required String system,
    required List<Map<String, Object?>> messages,
    List<Map<String, Object?>>? tools,
    int maxTokens = 8192,
  });

  /// Like [createMessage], but invokes [onText] with each chunk of assistant
  /// text as it arrives, then returns the same fully-assembled [AiResponse] so
  /// the orchestrator's tool loop is unchanged. Providers without real
  /// streaming deliver the whole text in one [onText] call at the end.
  Future<AiResponse> streamMessage({
    String? apiKey,
    required String model,
    required String system,
    required List<Map<String, Object?>> messages,
    List<Map<String, Object?>>? tools,
    int maxTokens = 8192,
    void Function(String delta)? onText,
  });

  /// Whether this provider can see image content blocks. Callers that attach
  /// images degrade gracefully (substitute a text note) when false.
  bool get supportsVision;

  /// Whether this provider accepts native PDF `document` blocks. When false,
  /// callers fall back to sending extracted text.
  bool get supportsPdfDocument;

  /// Roughly how many tokens this provider's context holds. Used to size
  /// what the app is willing to spend on framing (behavior rules, memory
  /// context) rather than on the request itself. Null when unknown, which
  /// callers treat as "large".
  int? get contextWindow => null;

  void dispose();
}

/// A normalized response in Anthropic block format.
class AiResponse {
  final String stopReason;
  final List<Map<String, Object?>> content;

  /// What the provider says the request actually cost, when it says.
  ///
  /// This is the only ground truth available for tokenization: no provider
  /// here ships a tokenizer that runs offline in Dart, so the estimator has
  /// to guess, and this is what tells it how wrong the guess was. Null when
  /// the provider reports nothing (some local servers do not).
  final int? inputTokens;
  final int? outputTokens;

  /// Prompt-cache accounting, when the provider does caching and reports it.
  ///
  /// These are the only honest answer to "is the cached prefix actually being
  /// reused?". A prefix that embeds anything per-turn (the wall clock, the
  /// turn's contract, the retrieved memories) is rewritten every turn, and
  /// the symptom is [cacheWriteTokens] staying high while [cacheReadTokens]
  /// stays near zero - which looks identical to caching working, from
  /// everywhere except here. Null on providers that cache nothing.
  final int? cacheReadTokens;
  final int? cacheWriteTokens;

  const AiResponse({
    required this.stopReason,
    required this.content,
    this.inputTokens,
    this.outputTokens,
    this.cacheReadTokens,
    this.cacheWriteTokens,
  });

  String get text => content
      .where((block) => block['type'] == 'text')
      .map((block) => block['text'] as String? ?? '')
      .join();

  List<Map<String, Object?>> get toolUses =>
      content.where((block) => block['type'] == 'tool_use').toList();
}

class AiException implements Exception {
  final String message;
  final int? statusCode;

  const AiException(this.message, {this.statusCode});

  @override
  String toString() => message;
}
