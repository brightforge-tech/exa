import 'dart:collection';

import '../tools/agent_tool.dart';

/// Thrown when a replayed turn calls a tool the scenario provided no mock
/// response for - the scenario is incomplete, or the turn diverged.
class ReplayToolResponseMissing implements Exception {
  ReplayToolResponseMissing(this.toolName);

  final String toolName;

  @override
  String toString() =>
      'ReplayToolResponseMissing: no mock response queued for $toolName';
}

/// The replay-mode tool executor: answers every call from queued mock
/// responses, in order, and records what was called. It has no access to
/// repositories, services, or the OS - replay can never execute a real side
/// effect by construction.
class ReplayToolRegistry {
  ReplayToolRegistry(Map<String, List<Map<String, dynamic>>> responses)
      : _responses = {
          for (final entry in responses.entries)
            entry.key: Queue.of(entry.value),
        };

  final Map<String, Queue<Map<String, dynamic>>> _responses;

  /// Every call made through this registry, in order.
  final List<({String toolName, Map<String, Object?> arguments})> calls = [];

  Future<ToolResult> execute(
    String toolName,
    Map<String, Object?> arguments, {
    String? idempotencyKey,
    String agentTurnId = '',
  }) async {
    calls.add((toolName: toolName, arguments: arguments));
    final queue = _responses[toolName];
    if (queue == null || queue.isEmpty) {
      throw ReplayToolResponseMissing(toolName);
    }
    final response = queue.removeFirst();
    if (response['__error__'] is String) {
      return ToolResult.fail(response['__error__'] as String);
    }
    return ToolResult.ok(response);
  }

  bool get allConsumed =>
      _responses.values.every((queue) => queue.isEmpty);
}
