/// A single controlled capability the agent can invoke.
///
/// The agent never touches the database or OS directly — every action flows
/// through one of these, which validates input, executes, and is logged.
class AgentTool {
  final String name;
  final String description;

  /// JSON Schema for the tool input, in Claude `input_schema` format.
  final Map<String, Object?> inputSchema;

  /// Sensitive actions pause the agent loop and ask the user first.
  final bool requiresConfirmation;

  /// For confirmation tools that are safe to repeat once approved (e.g.
  /// reading several browser tabs to compare them): ask only on the first
  /// call of a turn instead of for every call. Never set this on
  /// destructive tools.
  final bool confirmOncePerTurn;

  /// Permission group, e.g. `tasks.write` (informational for the activity log
  /// and the future permission dashboard).
  final String permission;

  final Future<ToolResult> Function(Map<String, Object?> input) execute;

  const AgentTool({
    required this.name,
    required this.description,
    required this.inputSchema,
    this.requiresConfirmation = false,
    this.confirmOncePerTurn = false,
    required this.permission,
    required this.execute,
  });

  /// Claude API tool definition.
  Map<String, Object?> toApiJson() => {
        'name': name,
        'description': description,
        'input_schema': inputSchema,
      };

  /// Minimal structural validation against the schema: required keys present
  /// and primitive types match. Returns an error message or null when valid.
  String? validateInput(Map<String, Object?> input) {
    final required =
        (inputSchema['required'] as List?)?.cast<String>() ?? const [];
    for (final key in required) {
      if (!input.containsKey(key) || input[key] == null) {
        return 'Missing required parameter: $key';
      }
    }
    final properties =
        (inputSchema['properties'] as Map?)?.cast<String, Object?>() ??
            const {};
    for (final entry in input.entries) {
      final spec = properties[entry.key];
      if (spec is! Map) continue;
      final expected = spec['type'];
      final value = entry.value;
      if (value == null) continue;
      final ok = switch (expected) {
        'string' => value is String,
        'integer' => value is int,
        'number' => value is num,
        'boolean' => value is bool,
        'object' => value is Map,
        'array' => value is List,
        _ => true,
      };
      if (!ok) {
        return "Parameter '${entry.key}' should be of type $expected";
      }
    }
    return null;
  }
}

class ToolResult {
  final bool success;

  /// JSON-encodable payload returned to the model.
  final Object? data;
  final String? error;

  /// When set, the UI should navigate to this route after the turn.
  final String? navigateTo;

  const ToolResult.ok(this.data, {this.navigateTo})
      : success = true,
        error = null,
        wasDenied = false;

  const ToolResult.fail(this.error)
      : success = false,
        data = null,
        navigateTo = null,
        wasDenied = false;

  /// Refused before execution by the capability gate (an unattended run
  /// reaching for something it may not do) or by the user declining a
  /// confirmation. Distinguished from a failure so the execution report can
  /// say "skipped, not allowed" rather than "tried and broke".
  const ToolResult.denied(this.error)
      : success = false,
        data = null,
        navigateTo = null,
        wasDenied = true;

  /// True when the action was refused rather than attempted.
  final bool wasDenied;
}
