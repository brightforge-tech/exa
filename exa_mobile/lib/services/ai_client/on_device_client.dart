import 'dart:convert';
import 'dart:io' show File, Platform;

import 'package:flutter_gemma/flutter_gemma.dart';

import '../../data/repositories/settings_repository.dart';
import 'ai_client.dart';
import 'on_device_catalog.dart';
import 'on_device_runtime.dart';

/// Tools exposed to on-device models. Deliberately a small subset of the full
/// registry: a 1.5B model at a ~4K context can't hold 35 tool schemas plus the
/// conversation, and these are the highest-value, simplest-schema actions.
/// All are non-destructive (none require confirmation), so the on-device path
/// never needs the interactive approval UI.
const Set<String> kOnDeviceToolNames = {
  'create_task',
  'list_tasks',
  'complete_task',
  'create_reminder',
  'list_reminders',
  'create_schedule_event',
  'list_schedule',
  'open_screen',
  'search',
};

/// Runs an embedded model fully on-device via flutter_gemma (MediaPipe LLM
/// Inference, Android only).
///
/// Function calling is bridged to Exa's Anthropic-format tool loop: a curated
/// [kOnDeviceToolNames] subset is handed to the model, and any function call it
/// emits is translated into a `tool_use` block so the orchestrator's existing
/// loop (permissions, logging, quick-actions) runs unchanged. Vision and PDF
/// document blocks are still unsupported. A model must be installed and active;
/// otherwise [createMessage] throws a friendly [AiException].
class OnDeviceClient implements AiClient {
  OnDeviceClient(this._settings);

  final SettingsRepository _settings;

  InferenceModel? _model;

  /// Identifies which model [_model] was built from (catalog id or file path),
  /// so we can rebuild it when the user switches the active on-device model.
  String? _modelKey;

  /// Context window for the active model. Capped to the model's built-in
  /// KV-cache size (from the catalog); a sideloaded file's is unknown, so it
  /// falls back to a conservative default that any `.task` model supports.
  int _activeMaxTokens = _fallbackMaxTokens;

  /// Model family of the active model, which selects the function-call parser
  /// (Qwen/Hammer/Gemma emit different tool-call syntaxes).
  ModelType _activeModelType = ModelType.gemmaIt;

  static const int _fallbackMaxTokens = 1024;

  /// Monotonic counter for synthesized tool_use ids within this client. Ids
  /// round-trip through the orchestrator, so uniqueness is all that matters.
  int _toolSeq = 0;

  @override
  bool get supportsVision => false;

  @override
  bool get supportsPdfDocument => false;

  /// Embedded models run with a small ekv cache; framing has to stay tiny
  /// or it crowds out the request itself.
  @override
  int? get contextWindow => 4096;

  @override
  Future<AiResponse> createMessage({
    String? apiKey,
    required String model,
    required String system,
    required List<Map<String, Object?>> messages,
    List<Map<String, Object?>>? tools,
    // The context window is chosen per-model from the catalog, not from this
    // caller-supplied value, so it can't exceed the model's built-in limit.
    int maxTokens = 8192,
  }) async {
    if (!Platform.isAndroid) {
      throw const AiException(
          'On-device AI is only available on Android right now. Switch to '
          'the Cloud or Local provider in Settings > AI provider.');
    }

    // The plugin only keeps the active model in memory, so after a restart (or
    // a model switch in Settings) we re-activate the stored selection here.
    final key = await _ensureActiveModel();
    if (key == null) {
      throw const AiException(
          'No on-device model is installed yet. Open Settings > AI provider '
          'to download one, or switch to the Cloud or Local provider.');
    }

    try {
      // Rebuild the loaded model if the active selection changed.
      if (_model != null && _modelKey != key) {
        await _model!.close();
        _model = null;
      }
      final inference = _model ??=
          await FlutterGemma.getActiveModel(maxTokens: _activeMaxTokens);
      _modelKey = key;

      final gemmaTools = _translateTools(tools);
      if (gemmaTools.isEmpty) {
        return await _plainResponse(inference, system, messages);
      }
      return await _toolResponse(inference, messages, gemmaTools);
    } on AiException {
      rethrow;
    } catch (e) {
      throw AiException('On-device model failed: $e');
    }
  }

  /// Tool-enabled path: replay the conversation into a function-calling chat
  /// and translate the model's reply back into Anthropic blocks.
  Future<AiResponse> _toolResponse(
    InferenceModel inference,
    List<Map<String, Object?>> messages,
    List<Tool> tools,
  ) async {
    final chat = await inference.createChat(
      tools: tools,
      supportsFunctionCalls: true,
      modelType: _activeModelType,
      toolChoice: ToolChoice.auto,
      systemInstruction: _compactSystemPrompt(),
    );
    try {
      await _replayHistory(chat, messages);
      final response = await chat.generateChatResponse();
      return _mapModelResponse(response);
    } finally {
      await chat.close();
    }
  }

  /// No-tools fallback (e.g. document summary): one-shot flattened prompt.
  Future<AiResponse> _plainResponse(
    InferenceModel inference,
    String system,
    List<Map<String, Object?>> messages,
  ) async {
    final session = await inference.createSession();
    try {
      await session.addQueryChunk(
          Message.text(text: _flattenPrompt(system, messages), isUser: true));
      final text = await session.getResponse();
      return AiResponse(
        stopReason: 'end_turn',
        content: [
          {'type': 'text', 'text': text},
        ],
      );
    } finally {
      await session.close();
    }
  }

  /// Feeds the Anthropic-format conversation into the flutter_gemma chat,
  /// converting `tool_use` blocks to tool-call messages and `tool_result`
  /// blocks to tool-response messages so the model sees its own prior calls
  /// and their outcomes. Image blocks are dropped (on-device has no vision).
  Future<void> _replayHistory(
    InferenceChat chat,
    List<Map<String, Object?>> messages,
  ) async {
    // Maps a tool_use id to its tool name, so the following tool_result can be
    // attributed to the right function.
    final idToName = <String, String>{};

    for (final message in messages) {
      final role = message['role'];
      final content = message['content'];
      final isAssistant = role == 'assistant';

      if (content is String) {
        final text = content.trim();
        if (text.isEmpty) continue;
        await chat.addQueryChunk(Message.text(text: text, isUser: !isAssistant));
        continue;
      }
      if (content is! List) continue;

      final textParts = <String>[];
      for (final block in content.whereType<Map>()) {
        switch (block['type']) {
          case 'text':
            final text = block['text'] as String? ?? '';
            if (text.isNotEmpty) textParts.add(text);
          case 'tool_use':
            final name = block['name'] as String?;
            final id = block['id'] as String?;
            if (id != null && name != null) idToName[id] = name;
            final input =
                (block['input'] as Map?)?.cast<String, dynamic>() ?? const {};
            await chat.addQueryChunk(Message.toolCall(
                text: jsonEncode({'name': name, 'parameters': input})));
          case 'tool_result':
            final id = block['tool_use_id'] as String?;
            await chat.addQueryChunk(Message.toolResponse(
              toolName: idToName[id] ?? 'tool',
              response: _asResponseMap(block['content']),
            ));
          // image / document blocks intentionally dropped
        }
      }

      final text = textParts.join('\n').trim();
      if (text.isNotEmpty) {
        await chat.addQueryChunk(Message.text(text: text, isUser: !isAssistant));
      }
    }
  }

  /// Translates flutter_gemma's response into an Anthropic-format [AiResponse].
  /// A function call becomes a `tool_use` block with `stopReason: 'tool_use'`,
  /// which drives the orchestrator's tool loop; anything else is plain text.
  AiResponse _mapModelResponse(ModelResponse response) {
    if (response is FunctionCallResponse) {
      return AiResponse(
        stopReason: 'tool_use',
        content: [_toolUseBlock(response)],
      );
    }
    if (response is ParallelFunctionCallResponse) {
      return AiResponse(
        stopReason: 'tool_use',
        content: [for (final call in response.calls) _toolUseBlock(call)],
      );
    }
    final text = response is TextResponse ? response.token : response.toString();
    return AiResponse(
      stopReason: 'end_turn',
      content: [
        {'type': 'text', 'text': text},
      ],
    );
  }

  Map<String, Object?> _toolUseBlock(FunctionCallResponse call) => {
        'type': 'tool_use',
        'id': 'toolu_od_${_toolSeq++}',
        'name': call.name,
        'input': call.args,
      };

  /// Converts a tool_result block's content (a JSON string or plain text) into
  /// the map [Message.toolResponse] expects.
  Map<String, dynamic> _asResponseMap(Object? content) {
    if (content is Map) return content.cast<String, dynamic>();
    final text = content?.toString() ?? '';
    try {
      final decoded = jsonDecode(text);
      if (decoded is Map<String, dynamic>) return decoded;
      return {'result': decoded};
    } catch (_) {
      return {'result': text};
    }
  }

  /// A small, on-device-specific system prompt. The full cloud prompt is far
  /// too large for a ~4K context; this keeps identity, tool guidance, and
  /// today's date (needed for relative date arguments).
  String _compactSystemPrompt() {
    final now = DateTime.now();
    final date =
        '${now.year}-${_two(now.month)}-${_two(now.day)}';
    return 'You are Exa, a concise on-device assistant. Today is $date (local '
        "time). You can manage the user's tasks, reminders, and calendar with "
        'the provided tools. When the user asks to add, create, schedule, '
        'complete, list, open, or find something, call the matching tool with '
        'correct arguments. Use ISO 8601 for date-times, e.g. ${date}T09:00:00. '
        'For anything else, answer briefly in plain text. Never invent tools or '
        'data.';
  }

  static String _two(int n) => n < 10 ? '0$n' : '$n';

  /// Filters the orchestrator's full tool list down to [kOnDeviceToolNames] and
  /// converts each to a flutter_gemma [Tool]. Anthropic `input_schema` maps
  /// directly onto [Tool.parameters].
  List<Tool> _translateTools(List<Map<String, Object?>>? tools) {
    if (tools == null) return const [];
    final result = <Tool>[];
    for (final tool in tools) {
      final name = tool['name'] as String?;
      if (name == null || !kOnDeviceToolNames.contains(name)) continue;
      final schema =
          (tool['input_schema'] as Map?)?.cast<String, dynamic>() ?? const {};
      result.add(Tool(
        name: name,
        description: tool['description'] as String? ?? '',
        parameters: schema,
      ));
    }
    return result;
  }

  /// Ensures an on-device model is active, re-activating the stored selection
  /// when the plugin has lost it (its active pointer is in-memory only and
  /// resets on restart). Returns a stable key for the active model (catalog id
  /// or file path), or null when nothing is installed. Re-activation reuses the
  /// already-downloaded file, so it does no network work and is offline-safe.
  Future<String?> _ensureActiveModel() async {
    // First touch of the plugin in this process: set up its registry now,
    // rather than at app startup (see [OnDeviceRuntime]).
    await OnDeviceRuntime.ensureInitialized();
    final entry = onDeviceModelById(await _settings.getOnDeviceModelId());
    if (entry != null) {
      try {
        if (await FlutterGemma.isModelInstalled(entry.filename)) {
          if (!FlutterGemma.hasActiveModel() || _modelKey != entry.id) {
            await FlutterGemma.installModel(
                    modelType: entry.modelType, fileType: entry.fileType)
                .fromNetwork(entry.url)
                .install();
          }
          _activeMaxTokens = entry.maxTokens;
          _activeModelType = entry.modelType;
          return entry.id;
        }
      } catch (_) {
        // Fall through to the sideloaded-file path.
      }
    }

    final path = await _settings.getOnDeviceModelPath();
    if (path != null && path.isNotEmpty && File(path).existsSync()) {
      try {
        if (!FlutterGemma.hasActiveModel() || _modelKey != path) {
          await FlutterGemma.installModel(modelType: ModelType.gemmaIt)
              .fromFile(path)
              .install();
        }
        _activeMaxTokens = _fallbackMaxTokens;
        _activeModelType = ModelType.gemmaIt;
        return path;
      } catch (_) {
        return null;
      }
    }

    // Nothing persisted, but a model may still be active in memory this session.
    return FlutterGemma.hasActiveModel() ? (_modelKey ?? 'active') : null;
  }

  /// On-device inference is generated in one shot here; deliver the whole
  /// response through [onText] so the chat UI renders it the same way.
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

  /// Flattens the Anthropic-format conversation into a single prompt for the
  /// no-tools path. Only text survives - tool_use/tool_result/image blocks are
  /// dropped.
  static String _flattenPrompt(
    String system,
    List<Map<String, Object?>> messages,
  ) {
    final buffer = StringBuffer();
    if (system.trim().isNotEmpty) {
      buffer.writeln(system.trim());
      buffer.writeln();
    }
    for (final message in messages) {
      final role = message['role'] == 'assistant' ? 'Assistant' : 'User';
      final text = _textOf(message['content']);
      if (text.trim().isEmpty) continue;
      buffer.writeln('$role: $text');
    }
    buffer.write('Assistant:');
    return buffer.toString();
  }

  static String _textOf(Object? content) {
    if (content is String) return content;
    if (content is List) {
      return content
          .whereType<Map>()
          .where((block) => block['type'] == 'text')
          .map((block) => block['text'] as String? ?? '')
          .join('\n');
    }
    return '';
  }

  @override
  void dispose() {
    _model?.close();
    _model = null;
    _modelKey = null;
  }
}
