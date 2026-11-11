import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/models/agent_datetime_label.dart';
import '../../data/models/task_item.dart';
import '../../data/repositories/settings_repository.dart';
import '../../services/ai_client/ai_client.dart';
import '../../services/ai_client/local_endpoint_client.dart';
import '../../shared/providers.dart';

/// One action item the model found in a transcript, before the user has
/// approved it.
///
/// Nothing here touches the database until the review sheet is confirmed, and
/// the fields are mutable because that sheet edits them in place - the point of
/// the review step is that the model's first guess at a title, priority or due
/// date is a draft, not a decision.
class ExtractedTask {
  ExtractedTask({
    required this.title,
    this.details,
    this.priority = 'Normal',
    this.dueAt,
    this.quote,
  });

  String title;
  String? details;
  String priority;
  DateTime? dueAt;

  /// The words in the transcript this was drawn from, so the user can check
  /// the model instead of trusting it. Null when the model omitted it.
  final String? quote;

  /// Description to store on the created task: the model's own detail plus
  /// where it came from, so a task opened days later still says why it exists.
  String? describeFrom(String transcriptTitle) {
    final parts = <String>[
      if (details != null && details!.isNotEmpty) details!,
      if (quote != null && quote!.isNotEmpty)
        'From transcript "$transcriptTitle": "$quote"',
    ];
    return parts.isEmpty ? null : parts.join('\n\n');
  }

  static ExtractedTask? fromJson(Object? value) {
    if (value is! Map) return null;
    final title = _text(value['title']);
    if (title == null) return null;
    final priority = _text(value['priority']);
    final due = _text(value['due_at']);
    return ExtractedTask(
      // Titles are one line in every list that shows them; a model that
      // answers with a sentence gets trimmed rather than dropped.
      title: title.length > 120 ? '${title.substring(0, 119)}…' : title,
      details: _text(value['details']),
      priority:
          TaskItem.priorities.contains(priority) ? priority! : 'Normal',
      dueAt: due == null ? null : DateTime.tryParse(due),
      quote: _text(value['quote']),
    );
  }

  static String? _text(Object? value) {
    if (value == null) return null;
    final text = value.toString().trim();
    return text.isEmpty ? null : text;
  }
}

const _extractionSystemPrompt = '''
You extract action items from a transcript of speech.

Reply with JSON only - no prose, no markdown fences:
{"tasks": [{"title": "...", "details": "...", "priority": "Low|Normal|High|Urgent", "due_at": "2026-08-07T09:00:00", "quote": "..."}]}

Rules:
- Only include something a person committed to doing, was asked to do, or
  agreed had to happen. Opinions, background, decisions already carried out and
  general discussion are NOT tasks.
- "title" is a short imperative instruction, at most 80 characters.
- "quote" is copied verbatim from the transcript - the words that show the task
  is real. Never invent or paraphrase a quote.
- "details" is optional context (who owns it, what it depends on). Omit it
  rather than padding it.
- "due_at" is ISO 8601 local time, and only when the transcript states or
  clearly implies a time. Use the weekday list to resolve relative dates like
  "Tuesday" or "next week". Otherwise use null.
- "priority" defaults to "Normal". Reserve "Urgent" for something the
  transcript itself treats as urgent.
- Transcripts are speech-to-text, so expect mis-heard words and false starts.
  Skip anything you cannot read confidently rather than guessing at it.
- If nobody committed to anything, reply {"tasks": []}.
''';

/// Asks the configured provider for the action items in [transcript].
///
/// Returns null when the reply could not be read as JSON at all - a real
/// outcome on smaller local models, and one the caller reports differently
/// from an empty list (which means the model read the transcript and found
/// nothing to do).
Future<List<ExtractedTask>?> extractTasksFromTranscript({
  required AiClient client,
  required String model,
  required String transcript,
  String? apiKey,
  DateTime? now,
}) async {
  final today = now ?? DateTime.now();
  final response = await client.createMessage(
    apiKey: apiKey,
    model: model,
    system: _extractionSystemPrompt,
    messages: [
      {
        'role': 'user',
        'content': 'Today is ${agentDateLabel(today)}.\n'
            'Dates you may need:\n${upcomingWeekdayMap(today)}\n\n'
            'Transcript:\n\n$transcript\n\n'
            'Extract the action items as JSON.',
      },
    ],
    maxTokens: 2048,
  );
  return parseExtractedTasks(response.text);
}

/// Reads the task list out of a model reply, tolerating prose or ```json
/// fences around it and an answer that is a bare array instead of the
/// documented object. Null means nothing decoded.
List<ExtractedTask>? parseExtractedTasks(String text) {
  for (final slice in [_slice(text, '{', '}'), _slice(text, '[', ']')]) {
    if (slice == null) continue;
    final Object? decoded;
    try {
      decoded = jsonDecode(slice);
    } catch (_) {
      continue;
    }
    final list = decoded is Map ? decoded['tasks'] : decoded;
    if (list is List) {
      return list
          .map(ExtractedTask.fromJson)
          .whereType<ExtractedTask>()
          .toList();
    }
  }
  return null;
}

String? _slice(String text, String open, String close) {
  final start = text.indexOf(open);
  final end = text.lastIndexOf(close);
  return start >= 0 && end > start ? text.substring(start, end + 1) : null;
}

/// A provider client resolved from settings, ready to send one request.
///
/// [owned] is non-null when the caller created the client and must dispose it;
/// clients that come from a provider are owned by the container instead.
typedef AiSession = ({
  AiClient client,
  String model,
  String? apiKey,
  AiClient? owned,
});

/// Resolves whichever backend the user has configured (Anthropic, DeepSeek, a
/// local OpenAI-compatible server, or the on-device model) for a one-shot
/// request.
Future<AiSession> openAiSession(WidgetRef ref) async {
  final settings = ref.read(settingsRepositoryProvider);
  final provider = await settings.getAiProvider();

  if (provider == SettingsRepository.providerDeepSeek) {
    final apiKey = await settings.getDeepSeekApiKey();
    if (apiKey == null || apiKey.isEmpty) {
      throw const AiException(
          'No DeepSeek API key set. Add one in Settings > AI provider.');
    }
    final deepSeek = ref.read(deepSeekClientProvider)
      ..baseUrl = await settings.getDeepSeekBaseUrl()
      ..apiKey = apiKey;
    return (
      client: deepSeek,
      model: await settings.getDeepSeekModel(),
      apiKey: apiKey,
      owned: null,
    );
  }
  if (provider == SettingsRepository.providerLocal) {
    final local = LocalEndpointClient(
      baseUrl: await settings.getLocalBaseUrl(),
      apiKey: await settings.getLocalApiKey(),
    );
    return (
      client: local,
      model: await settings.getLocalModel(),
      apiKey: null,
      owned: local,
    );
  }
  if (provider == SettingsRepository.providerOnDevice) {
    return (
      client: ref.read(onDeviceClientProvider),
      model: '',
      apiKey: null,
      owned: null,
    );
  }
  final apiKey = await settings.getApiKey();
  if (apiKey == null || apiKey.isEmpty) {
    throw const AiException(
        'No API key set. Add one in Settings > AI provider.');
  }
  return (
    client: ref.read(claudeClientProvider),
    model: await settings.getModel(),
    apiKey: apiKey,
    owned: null,
  );
}
