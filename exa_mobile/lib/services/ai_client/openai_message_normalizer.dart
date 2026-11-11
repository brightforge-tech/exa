/// Normalizes and validates an OpenAI-format message sequence before it is
/// posted to a local server.
///
/// Named for the wire format rather than for one model: llama-server, Ollama
/// and LM Studio all render histories through strict Jinja chat templates, and
/// Ministral is simply the one that surfaced it. Those templates raise an
/// "alternating roles" exception (or silently drop turns) on sequences the
/// Anthropic block format allows quite happily:
///
///  - more than one `system` message, or one that is not first
///  - `content: null` on an assistant message
///  - a structured (non-string) `content` on a tool message
///  - two consecutive `user` or two consecutive plain `assistant` turns
///  - a tool result whose `tool_call_id` never appeared in a prior tool call
///
/// [normalizeOpenAiMessages] repairs what can be repaired; anything left that
/// would make the server fail is caught by [validateOpenAiMessageSequence] and
/// reported here, where the message can name the real problem, instead of
/// coming back as an opaque 500 from the template engine.
library;

import 'dart:convert';

import 'ai_client.dart';

/// Collapses every `system` message into a single one at index 0, coerces
/// assistant/tool content into the shapes the templates require, and merges
/// consecutive same-role turns.
List<Map<String, Object?>> normalizeOpenAiMessages(
  List<Map<String, Object?>> input,
) {
  final systemParts = <String>[];
  final output = <Map<String, Object?>>[];

  for (final source in input) {
    final message = Map<String, Object?>.from(source);
    final role = message['role'];

    if (role == 'system') {
      final content = message['content'];
      if (content is String && content.trim().isNotEmpty) {
        systemParts.add(content.trim());
      }
      continue;
    }

    // Templates index assistant content directly; null blows them up.
    if (role == 'assistant' && message['content'] == null) {
      message['content'] = '';
    }
    if (role == 'tool' && message['content'] is! String) {
      message['content'] = jsonEncode(message['content']);
    }

    if (_mergeIntoPrevious(output, message)) continue;
    output.add(message);
  }

  if (systemParts.isNotEmpty) {
    output.insert(0, {
      'role': 'system',
      'content': systemParts.join('\n\n'),
    });
  }
  return output;
}

/// Merges [message] into the tail of [output] when both are ordinary turns of
/// the same role. Returns whether it was merged.
///
/// Only plain text turns merge: an assistant message carrying `tool_calls`
/// must stay exactly as it was, because the tool results that follow are
/// matched to the ids inside it.
bool _mergeIntoPrevious(
  List<Map<String, Object?>> output,
  Map<String, Object?> message,
) {
  if (output.isEmpty) return false;
  final previous = output.last;
  final role = message['role'];
  if (role != previous['role']) return false;
  if (role != 'user' && role != 'assistant') return false;
  if (previous['tool_calls'] != null || message['tool_calls'] != null) {
    return false;
  }
  final before = previous['content'];
  final after = message['content'];
  // Multimodal turns are lists of content parts; concatenating them is fine,
  // mixing a list with a bare string is not - leave those alone.
  if (before is List && after is List) {
    previous['content'] = [...before, ...after];
    return true;
  }
  if (before is String && after is String) {
    previous['content'] =
        [before.trim(), after.trim()].where((p) => p.isNotEmpty).join('\n\n');
    return true;
  }
  return false;
}

/// Throws [AiException] when [messages] would be rejected by a strict chat
/// template. Run after [normalizeOpenAiMessages] - anything reaching here is a
/// real defect, not a formatting quirk.
void validateOpenAiMessageSequence(List<Map<String, Object?>> messages) {
  const roles = {'system', 'user', 'assistant', 'tool'};
  final seenToolCallIds = <String>{};

  for (var i = 0; i < messages.length; i++) {
    final message = messages[i];
    final role = message['role'];

    if (role is! String || !roles.contains(role)) {
      throw AiException('Unsupported message role "$role" at index $i.');
    }
    if (role == 'system' && i != 0) {
      throw AiException(
          'Only the first message may be a system message (found one at '
          'index $i).');
    }

    if (role == 'assistant') {
      final content = message['content'];
      if (content == null) {
        throw AiException('Assistant message at index $i has null content.');
      }
      final toolCalls = message['tool_calls'];
      final hasText = content is String
          ? content.trim().isNotEmpty
          : (content is List && content.isNotEmpty);
      final hasCalls = toolCalls is List && toolCalls.isNotEmpty;
      if (!hasText && !hasCalls) {
        throw AiException(
            'Assistant message at index $i has neither text nor tool calls.');
      }
      if (hasCalls) {
        for (final call in toolCalls.whereType<Map>()) {
          final id = call['id'];
          if (id is String && id.isNotEmpty) seenToolCallIds.add(id);
        }
      }
    }

    if (role == 'tool') {
      final id = message['tool_call_id'];
      if (id is! String || id.isEmpty) {
        throw AiException('Tool message at index $i has no tool_call_id.');
      }
      if (message['content'] is! String) {
        throw AiException('Tool message at index $i has non-string content.');
      }
      if (!seenToolCallIds.contains(id)) {
        throw AiException(
            'Tool result at index $i references tool_call_id "$id", which no '
            'earlier assistant message requested.');
      }
    }
  }
}
