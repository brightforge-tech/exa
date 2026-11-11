import 'dart:convert';

import 'package:crypto/crypto.dart';

/// Builds deterministic idempotency keys for side-effecting tool calls and
/// decides which tools need one.
///
/// Key = sha256(turn id | tool name | canonical arguments | target entity),
/// so the same requested side effect inside one turn (a model retry, a skill
/// step retry, an app restart replaying the loop) maps to the same key and
/// is answered from the first successful execution instead of running twice.
class IdempotencyService {
  const IdempotencyService();

  /// Verbs whose tools change state. Read/list/search tools are repeatable
  /// by nature and never keyed.
  static const _sideEffectVerbs = {
    'create', 'update', 'delete', 'cancel', 'complete', 'send', 'mark',
    'store', 'save', 'add', 'pause', 'resume', 'activate', 'rollback',
    'propose', 'sync', 'run', 'define',
  };

  /// Sync/run tools change state but are safe (and often necessary) to
  /// repeat across a turn - never dedupe them.
  static const _repeatableTools = {
    'sync_emails',
    'sync_device_calendar',
    'run_scheduled_job_now',
  };

  bool isSideEffecting(String toolName) {
    if (_repeatableTools.contains(toolName)) return false;
    final verb = toolName.split('_').first;
    return _sideEffectVerbs.contains(verb);
  }

  String buildKey({
    required String agentTurnId,
    required String toolName,
    required Map<String, Object?> arguments,
    String? targetEntityId,
  }) {
    final normalizedArguments = canonicalJsonEncode(arguments);
    return sha256
        .convert(utf8.encode(
            '$agentTurnId|$toolName|$normalizedArguments|${targetEntityId ?? ''}'))
        .toString();
  }

  /// JSON with map keys sorted recursively, so semantically identical
  /// argument maps produce identical keys regardless of key order.
  static String canonicalJsonEncode(Object? value) =>
      jsonEncode(_canonicalize(value));

  static Object? _canonicalize(Object? value) {
    if (value is Map) {
      final sortedKeys = value.keys.map((k) => k.toString()).toList()..sort();
      return {
        for (final key in sortedKeys) key: _canonicalize(value[key]),
      };
    }
    if (value is List) {
      return [for (final item in value) _canonicalize(item)];
    }
    return value;
  }
}
