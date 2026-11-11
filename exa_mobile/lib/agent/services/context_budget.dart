import 'dart:convert';

import '../behaviors/token_estimator.dart';
import 'token_calibration.dart';

/// How much of a model's context each part of a turn may occupy.
///
/// A turn is assembled from four growing things - chat history, the system
/// framing, tool results, and retrieved memories - and until now none of
/// them had a ceiling. That is fine until one of them is large: 57
/// undigested emails returned by a single tool call is tens of thousands of
/// tokens in one string, appended to a message list that is then re-sent on
/// every subsequent loop iteration. The turn dies at the context limit, and
/// the user is told nothing useful.
///
/// Budgets are fractions of the window rather than fixed numbers because
/// the app runs against anything from a 4k on-device model to a 200k remote
/// one, and a limit that protects the first would waste the second.
class ContextBudget {
  const ContextBudget({
    required this.windowTokens,
    required this.historyTokens,
    required this.toolResultTokens,
    required this.memoryTokens,
  });

  /// The window assumed when a provider does not report one.
  ///
  /// 32k is the point where the per-part shares stop fighting each other: at
  /// 16k the 20% history share is ~3,200 tokens, which two of Exa's own
  /// replies exhaust, so the replay collapsed to a couple of turns and
  /// [HistoryBudget.minimumRecentMessages] could not be honoured without the
  /// request ceiling clawing it straight back.
  ///
  /// Guessing high is not free — a request over the provider's real limit is
  /// rejected outright rather than degraded — but nothing reaches this
  /// fallback except a client that reports no window at all, and 32k is now
  /// the low end for anything worth pointing Exa at.
  static const defaultWindow = 32000;

  final int windowTokens;

  /// Ceiling for the replayed conversation.
  final int historyTokens;

  /// Ceiling for a SINGLE tool result. The tool loop re-sends every result
  /// on each iteration, so one oversized payload is charged repeatedly.
  final int toolResultTokens;

  /// Ceiling for the retrieved-memory block.
  final int memoryTokens;

  /// Ceiling for the tool definitions sent on every call.
  ///
  /// This is the largest single block in a turn and the easiest to overlook:
  /// the full registry is ~6,700 tokens, re-sent on every loop iteration.
  /// With a 1,700-token system prompt that is over 8k before the
  /// conversation starts, which is a hard failure on a small local model
  /// rather than a degraded answer.
  int get toolDefinitionTokens => (windowTokens * 0.30).round();

  /// Characters of evidence the final response-writing call may be given.
  ///
  /// That call is the one place the turn's reads are read a second time, by
  /// a model that did not make them, and it was the only part of a turn
  /// still on a fixed number: 6,000 characters whatever the window. A fifth
  /// of the window, counted at JSON density because evidence is JSON. The
  /// floor is the old fixed value, so no model gets less than it had; the
  /// ceiling keeps a 200k remote model from being sent 100k characters to
  /// write four sentences.
  int get evidenceChars => (windowTokens * 0.20 * jsonCharsPerToken)
      .round()
      .clamp(evidenceFloorChars, evidenceCeilingChars);

  static const evidenceFloorChars = 6000;
  static const evidenceCeilingChars = 48000;

  /// How densely JSON tokenizes - see [TokenEstimator].
  static const jsonCharsPerToken = 2.7;

  /// Ceiling for the whole running conversation - history plus everything
  /// the tool loop appends. Per-result caps are not enough on their own:
  /// five results at 15% each is 75% of the window.
  int get conversationTokens => (windowTokens * 0.45).round();

  factory ContextBudget.forWindow(int? contextWindow) {
    final window = (contextWindow ?? defaultWindow).clamp(2000, 1000000);
    return ContextBudget(
      windowTokens: window,
      historyTokens: (window * 0.20).round(),
      toolResultTokens: (window * 0.15).round(),
      memoryTokens: (window * 0.08).round(),
    );
  }
}

/// The last check before a request goes out.
///
/// Every other budget here is per-part, and per-part budgets do not add up
/// to a guarantee: the system prompt, the tool definitions and the
/// conversation are each within their own allowance while the total is
/// still over the model's limit. A server that rejects the request outright
/// ("17042 tokens exceeds the available context size (16384)") turns that
/// arithmetic gap into a job that simply never runs.
///
/// This measures what is actually about to be sent and trims until it fits.
class RequestFitter {
  const RequestFitter._();

  /// Fraction of the window a request may occupy when the caller does not
  /// say how much output it needs. The remainder is the model's room to
  /// answer - a request that exactly fills the context leaves nothing to
  /// generate into.
  ///
  /// A flat share is wrong at both ends: it strands a fifth of a 200k
  /// window and is still too generous on a 4k one. Callers that know what
  /// they are asking for pass [reservedOutput] instead, which is computed
  /// from the turn frame's response budget.
  static const double requestShare = 0.75;

  /// Trims [messages] in place until system + tools + messages fit.
  ///
  /// Returns the estimated request size after trimming, and how much of the
  /// replayed history survived — the caller passes that back on the next
  /// iteration so the prefix stays accurate as the tool loop appends.
  ///
  /// [historyCount] is how many leading messages are replayed history and
  /// may therefore be dropped as a last resort. Leave it at 0 to forbid
  /// dropping any (the pre-existing behaviour: blank tool results only).
  ///
  /// [estimateScale] applies the model's learned estimate-versus-actual
  /// correction (see `TokenCalibration`), so a provider whose tokenizer
  /// splits more finely than the estimator assumes is budgeted for what it
  /// actually charges rather than what was guessed.
  static ({int size, int historyCount}) fit({
    required String system,
    required List<Map<String, Object?>> tools,
    required List<Map<String, Object?>> messages,
    required int windowTokens,
    int historyCount = 0,
    int? reservedOutput,
    double estimateScale = 1.0,
  }) {
    final ceiling = reservedOutput == null
        ? (windowTokens * requestShare).round()
        : OutputReservation.availableInput(
            contextWindow: windowTokens,
            reservedOutput: reservedOutput,
          );
    final fixed = ((TokenEstimator.estimate(system) +
                TokenEstimator.estimate(jsonEncode(tools))) *
            estimateScale)
        .ceil();
    final forMessages = ceiling - fixed;

    // Framing alone over budget: nothing here can fix that, but blanking
    // the conversation still gives the request its best chance, and the
    // caller records why.
    final allowance = forMessages < 200 ? 200 : forMessages;
    MessageWindow.trim(messages, allowance, keepRecent: 1);

    // Blanking tool results is not enough on its own. It cannot reach the
    // replayed history at all, and on the first call of a turn there are no
    // tool results to blank - so without this, a history floor that
    // overshoots the window would sail straight through to a provider
    // rejection.
    final remainingHistory =
        MessageWindow.tokensOf(messages) > allowance && historyCount > 0
            ? MessageWindow.dropOldestHistory(messages, allowance,
                historyCount: historyCount)
            : historyCount;

    return (
      size: fixed + MessageWindow.tokensOf(messages),
      historyCount: remainingHistory,
    );
  }
}

/// Keeps the running conversation inside the window as the tool loop grows.
///
/// Every iteration re-sends the whole message list, so results accumulate:
/// reading five emails individually is five bodies charged on every
/// subsequent call. Older results are replaced with a short marker rather
/// than removed, because a `tool_use` block must always be answered by a
/// matching `tool_result` - dropping one would make the request invalid.
class MessageWindow {
  const MessageWindow._();

  static const placeholder =
      '[earlier result dropped to fit the model context - call the tool '
      'again if you still need it]';

  /// Trims in place. The most recent [keepRecent] messages are never
  /// touched: they are what the model is answering right now.
  static void trim(
    List<Map<String, Object?>> messages,
    int maxTokens, {
    int keepRecent = 2,
  }) {
    if (_tokens(messages) <= maxTokens) return;
    final trimmable = messages.length - keepRecent;
    for (var i = 0; i < trimmable; i++) {
      final content = messages[i]['content'];
      if (content is! List) continue;
      var changed = false;
      for (final block in content) {
        if (block is Map &&
            block['type'] == 'tool_result' &&
            block['content'] is String &&
            block['content'] != placeholder) {
          block['content'] = placeholder;
          changed = true;
        }
      }
      if (changed && _tokens(messages) <= maxTokens) return;
    }
  }

  /// Drops the oldest replayed history messages until the list fits. The
  /// last resort, after [trim] has blanked everything it can.
  ///
  /// [trim] cannot touch the replayed conversation at all: those messages
  /// carry plain strings, and it only rewrites `tool_result` blocks. So on
  /// the first call of a turn — no tool results yet — it is a no-op, and
  /// history is the only thing left to give.
  ///
  /// Only the first [historyCount] messages are eligible. Everything after
  /// them is the current question and this turn's tool traffic: dropping
  /// those would either discard what the user actually asked or orphan a
  /// `tool_use` block from its `tool_result`, which makes the request
  /// invalid rather than merely smaller.
  ///
  /// Returns how many history messages survive, so a caller tracking the
  /// prefix across a growing tool loop stays in step.
  static int dropOldestHistory(
    List<Map<String, Object?>> messages,
    int maxTokens, {
    required int historyCount,
  }) {
    var remaining = historyCount.clamp(0, messages.length);
    var dropped = false;
    while (remaining > 0 && tokensOf(messages) > maxTokens) {
      messages.removeAt(0);
      remaining--;
      dropped = true;
    }
    // The API rejects a conversation that opens on an assistant turn, and
    // dropping from the front is exactly how that happens. Once the whole
    // prefix is gone the first message is the current user turn, which is
    // valid by construction.
    while (dropped && remaining > 0 && messages.first['role'] != 'user') {
      messages.removeAt(0);
      remaining--;
    }
    return remaining;
  }

  static int _tokens(List<Map<String, Object?>> messages) =>
      tokensOf(messages);

  static int tokensOf(List<Map<String, Object?>> messages) {
    var total = 0;
    for (final message in messages) {
      final content = message['content'];
      total += TokenEstimator.estimate(
          content is String ? content : jsonEncode(content));
    }
    return total;
  }
}

/// Trims a tool result to fit a budget while keeping it valid JSON.
///
/// Cutting the encoded string would hand the model a truncated object it
/// cannot parse. Instead the largest list in the payload is shortened -
/// which is almost always the right thing, since oversized results are
/// oversized because they contain many items - and the result says so, with
/// the counts the model needs to ask for the rest.
class ToolResultBudget {
  const ToolResultBudget._();

  /// Marker key added to a shortened payload.
  static const truncatedKey = '_truncated';

  /// The token allowance that holds [chars] characters of JSON, for callers
  /// that budget in characters.
  static int tokensForJsonChars(int chars) =>
      (chars / ContextBudget.jsonCharsPerToken).floor();

  static Object? fit(Object? data, int maxTokens) {
    if (data == null) return data;
    if (_tokens(data) <= maxTokens) return data;

    if (data is Map) {
      final map = data.cast<String, Object?>();
      final listKey = _largestListKey(map);
      if (listKey != null) {
        final full = (map[listKey] as List).length;
        var kept = full;
        var reduced = map;
        // Halve until it fits, then stop - a couple of passes at most, and
        // never below one item so the model always sees the shape.
        while (kept > 1) {
          kept = kept ~/ 2;
          reduced = {
            ...map,
            listKey: (map[listKey] as List).take(kept).toList(),
            truncatedKey: {
              'reason': 'too large for the model context',
              'showing': kept,
              'total': full,
              'remaining': full - kept,
              'next_step': 'Handle these first, then call this tool again '
                  'for the next batch.',
            },
          };
          if (_tokens(reduced) <= maxTokens) return reduced;
        }
        return reduced;
      }

      // No list to shorten: clip the longest string value instead.
      final stringKey = _largestStringKey(map);
      if (stringKey != null) {
        final value = map[stringKey] as String;
        final budgetChars = (maxTokens * 3.6).round();
        if (budgetChars < value.length) {
          return {
            ...map,
            stringKey: '${value.substring(0, budgetChars)}...',
            truncatedKey: {
              'reason': 'too large for the model context',
              'field': stringKey,
              'kept_characters': budgetChars,
              'total_characters': value.length,
            },
          };
        }
      }
    }

    // Last resort: a scalar or a shape with nothing to shorten.
    final encoded = jsonEncode(data);
    final budgetChars = (maxTokens * 3.6).round();
    return {
      truncatedKey: {
        'reason': 'too large for the model context',
        'kept_characters': budgetChars,
        'total_characters': encoded.length,
      },
      'content': encoded.length <= budgetChars
          ? encoded
          : '${encoded.substring(0, budgetChars)}...',
    };
  }

  static bool wasTruncated(Object? data) =>
      data is Map && data.containsKey(truncatedKey);

  static int _tokens(Object? data) {
    try {
      return TokenEstimator.estimate(jsonEncode(data));
    } catch (_) {
      return TokenEstimator.estimate('$data');
    }
  }

  static String? _largestListKey(Map<String, Object?> map) {
    String? key;
    var best = 0;
    for (final entry in map.entries) {
      final value = entry.value;
      if (value is List && value.length > best) {
        best = value.length;
        key = entry.key;
      }
    }
    return best > 1 ? key : null;
  }

  static String? _largestStringKey(Map<String, Object?> map) {
    String? key;
    var best = 0;
    for (final entry in map.entries) {
      final value = entry.value;
      if (value is String && value.length > best) {
        best = value.length;
        key = entry.key;
      }
    }
    return best > 0 ? key : null;
  }
}

/// Clips a plain-text block to a token budget on a line boundary, so a
/// truncated block never ends mid-sentence and always says it was cut.
class TextBudget {
  const TextBudget._();

  static String fit(String text, int maxTokens) {
    if (TokenEstimator.estimate(text) <= maxTokens) return text;
    final lines = text.split('\n');
    final kept = <String>[];
    var tokens = 0;
    for (final line in lines) {
      final cost = TokenEstimator.estimate('$line\n');
      if (tokens + cost > maxTokens) break;
      kept.add(line);
      tokens += cost;
    }
    if (kept.isEmpty) return '';
    return '${kept.join('\n')}\n(trimmed to fit the model context)';
  }
}

/// Drops the oldest turns until the replayed conversation fits.
///
/// Recent turns matter most and the newest is what the user just said, so
/// trimming is always from the front. The API also requires the first
/// message to be from the user, which the caller re-establishes.
class HistoryBudget {
  const HistoryBudget._();

  /// Replayed messages kept regardless of the token budget: three
  /// user/assistant pairs.
  ///
  /// A pure token budget can cut the replay to a single message, and then a
  /// follow-up that points at something ("make that screen show only the
  /// unread ones") has lost the thing it points at. Long assistant replies
  /// make that the normal case rather than an edge one: a couple of them
  /// exhaust a small window's history share on their own.
  ///
  /// The floor is deliberately SOFT. [RequestFitter] may go below it —
  /// see [MessageWindow.dropOldestHistory] — because this budget is a
  /// fraction of the window, not the window itself, and holding messages
  /// past the point where the request fits would turn a degraded answer
  /// into a provider rejection that kills the turn outright.
  static const int minimumRecentMessages = 6;

  static List<Map<String, Object?>> fit(
    List<Map<String, Object?>> messages,
    int maxTokens, {
    int keepRecent = minimumRecentMessages,
  }) {
    var total = messages.fold<int>(
        0, (sum, message) => sum + _tokensOf(message));
    if (total <= maxTokens) return messages;

    final floor = keepRecent < 1 ? 1 : keepRecent;
    final trimmed = [...messages];
    while (trimmed.length > floor && total > maxTokens) {
      total -= _tokensOf(trimmed.removeAt(0));
    }
    return trimmed;
  }

  static int _tokensOf(Map<String, Object?> message) {
    final content = message['content'];
    return TokenEstimator.estimate(
        content is String ? content : jsonEncode(content));
  }
}
