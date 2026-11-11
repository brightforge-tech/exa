import 'dart:convert';

import '../models/agent_ids.dart';
import '../models/tool_execution_record.dart';
import '../services/execution_record_builder.dart';
import '../security/capability_policy.dart';
import '../services/idempotency_service.dart';
import '../tools/agent_tool.dart';
import '../tools/tool_registry.dart';
import 'models/workflow_skill.dart';
import 'workflow_skill_repository.dart';

/// Asked before a confirmation-gated step runs (same shape as the
/// orchestrator's ConfirmToolCall).
typedef SkillConfirm = Future<bool> Function(
    String toolName, Map<String, Object?> input);

/// Executes a deterministic workflow skill: ordered steps, dependency and
/// condition gating, per-step failure policies, retries, forEach fan-out -
/// all through the normal tool registry, so validation, permission checks,
/// logging, confirmation gates, and idempotency all still apply. A skill can
/// never bypass what a direct tool call could not.
class SkillExecutor {
  SkillExecutor({
    required ToolRegistry registry,
    required WorkflowSkillRepository repository,
    IdempotencyService idempotency = const IdempotencyService(),
  })  : _tools = registry,
        _skills = repository,
        _idempotencyService = idempotency;

  final ToolRegistry _tools;
  final WorkflowSkillRepository _skills;
  final IdempotencyService _idempotencyService;

  /// Upper bound on forEach fan-out per step, so a huge list result cannot
  /// turn one step into hundreds of calls.
  static const int maxForEachItems = 20;

  Future<SkillExecutionResult> execute({
    required WorkflowSkill skill,
    required Map<String, dynamic> inputs,
    required String agentTurnId,
    SkillConfirm? onConfirm,
    CapabilityContext capabilities = CapabilityContext.interactive,
  }) async {
    final executionId = AgentId.skillRun();
    await _skills.recordExecutionStart(
      executionId: executionId,
      skill: skill,
      agentTurnId: agentTurnId,
      inputs: inputs,
    );

    final records = <ToolExecutionRecord>[];
    final context = <String, Object?>{'input': inputs};
    final stepStatuses = <String, String>{};
    String status = 'completed';
    String? failureReason;

    for (final step in skill.steps) {
      // Dependency gate: every dependency must have succeeded.
      final unmet = step.dependsOn.where(
          (dep) => stepStatuses[dep] != 'completed');
      if (unmet.isNotEmpty) {
        stepStatuses[step.id] = 'skipped';
        await _skills.recordStep(
          executionId: executionId,
          stepId: step.id,
          status: 'skipped',
          errorMessage: 'Unmet dependencies: ${unmet.join(', ')}',
        );
        continue;
      }

      // Condition gate.
      if (step.condition != null &&
          !evaluateCondition(step.condition!, context)) {
        stepStatuses[step.id] = 'skipped';
        await _skills.recordStep(
          executionId: executionId,
          stepId: step.id,
          status: 'skipped',
          errorMessage: 'Condition not met: ${step.condition}',
        );
        continue;
      }

      // forEach fan-out or a single call.
      final items = step.forEachPath == null
          ? const [null]
          : _resolveList(step.forEachPath!, context);
      var stepFailed = false;
      var stepDenied = false;
      Object? lastResultData;

      for (final item in items.take(maxForEachItems)) {
        final arguments = resolveArguments(step.argumentTemplate, context,
            item: item);

        // Confirmation gates: the step's own flag plus the tool's registry
        // flag. Skills must never weaken tool-level gating.
        final tool = _tools[step.toolName];
        final needsConfirmation = step.requiresConfirmation ||
            step.failurePolicy == SkillStepFailurePolicy.requestConfirmation ||
            (tool?.requiresConfirmation ?? false);
        // Full autonomy approves in advance; the registry's gate still runs
        // on the call itself.
        if (needsConfirmation && !capabilities.autoApproveConfirmations) {
          final approved = onConfirm == null
              ? false
              : await onConfirm(step.toolName, arguments);
          if (!approved) {
            stepDenied = true;
            records.add(buildExecutionRecord(
              registry: _tools,
              toolUseId: '${executionId}_${step.id}',
              toolName: step.toolName,
              input: arguments,
              result: const ToolResult.fail(
                  'The user declined this action. Do not retry it.'),
              denied: true,
              isControlPlane: false,
              startedAt: DateTime.now(),
              agentTurnId: agentTurnId,
            ));
            break;
          }
        }

        final startedAt = DateTime.now();
        final key = _idempotencyService.isSideEffecting(step.toolName)
            ? _idempotencyService.buildKey(
                agentTurnId: agentTurnId,
                toolName: step.toolName,
                arguments: arguments,
                targetEntityId: arguments['id'] as String?,
              )
            : null;

        var attempts = 0;
        final maxAttempts =
            step.failurePolicy == SkillStepFailurePolicy.retry
                ? step.maxRetries + 1
                : 1;
        ToolResult result =
            const ToolResult.fail('Step did not execute');
        while (attempts < maxAttempts) {
          attempts++;
          result = await _tools.execute(
            step.toolName,
            arguments,
            idempotencyKey: key,
            agentTurnId: agentTurnId,
            capabilities: capabilities,
          );
          // Retrying a refusal is pointless: the gate's answer will not
          // change within a run.
          if (result.success || result.wasDenied) break;
        }

        records.add(buildExecutionRecord(
          registry: _tools,
          toolUseId: '${executionId}_${step.id}_$attempts',
          toolName: step.toolName,
          input: arguments,
          result: result,
          denied: result.wasDenied,
          isControlPlane: false,
          startedAt: startedAt,
          agentTurnId: agentTurnId,
          idempotencyKey: key,
        ));

        await _skills.recordStep(
          executionId: executionId,
          stepId: step.id,
          status: result.success ? 'completed' : 'failed',
          argumentsJson: jsonEncode(arguments),
          resultJson: result.success ? jsonEncode(result.data) : null,
          errorMessage: result.error,
          retryCount: attempts - 1,
          startedAt: startedAt,
          completedAt: DateTime.now(),
        );

        if (result.success) {
          lastResultData = result.data;
        } else {
          stepFailed = true;
          break;
        }
      }

      if (stepDenied) {
        stepStatuses[step.id] = 'cancelled';
        if (!step.isOptional) {
          status = 'cancelled';
          failureReason = 'The user declined step "${step.name}".';
          break;
        }
        continue;
      }

      if (stepFailed) {
        stepStatuses[step.id] = 'failed';
        switch (step.failurePolicy) {
          case SkillStepFailurePolicy.continueAndReport:
          case SkillStepFailurePolicy.skip:
            status = 'partial';
          case SkillStepFailurePolicy.stop:
          case SkillStepFailurePolicy.retry:
          case SkillStepFailurePolicy.requestUserInput:
          case SkillStepFailurePolicy.requestConfirmation:
            if (step.isOptional) {
              status = 'partial';
            } else {
              status = 'failed';
              failureReason = 'Step "${step.name}" failed.';
            }
        }
        if (status == 'failed') break;
        continue;
      }

      stepStatuses[step.id] = 'completed';
      if (lastResultData != null) {
        context[step.id] = lastResultData;
      }
    }

    await _skills.recordExecutionEnd(
      executionId: executionId,
      status: status,
      failureReason: failureReason,
    );

    return SkillExecutionResult(
      executionId: executionId,
      skillId: skill.id,
      skillName: skill.name,
      skillVersion: skill.version,
      status: status,
      toolRecords: records,
      failureReason: failureReason,
    );
  }

  // ------------------------------------------------------------ templates --

  /// Resolves an argument template against the execution context. A value
  /// that is exactly one `{{path}}` placeholder becomes the raw referenced
  /// value (any type); strings with embedded placeholders interpolate; maps
  /// and lists resolve recursively.
  static Map<String, Object?> resolveArguments(
    Map<String, dynamic> template,
    Map<String, Object?> context, {
    Object? item,
  }) {
    final scope = <String, Object?>{...context, 'item': ?item};
    final resolved = <String, Object?>{};
    template.forEach((key, value) {
      final result = _resolveValue(value, scope);
      if (result != null) resolved[key] = result;
    });
    return resolved;
  }

  static Object? _resolveValue(Object? value, Map<String, Object?> scope) {
    if (value is String) {
      final exact = RegExp(r'^\{\{([^}]+)\}\}$').firstMatch(value.trim());
      if (exact != null) {
        return _resolvePath(exact.group(1)!.trim(), scope);
      }
      return value.replaceAllMapped(
        RegExp(r'\{\{([^}]+)\}\}'),
        (match) => '${_resolvePath(match.group(1)!.trim(), scope) ?? ''}',
      );
    }
    if (value is Map) {
      final map = <String, Object?>{};
      value.forEach((key, inner) {
        map[key.toString()] = _resolveValue(inner, scope);
      });
      return map;
    }
    if (value is List) {
      return [for (final inner in value) _resolveValue(inner, scope)];
    }
    return value;
  }

  static Object? _resolvePath(String path, Map<String, Object?> scope) {
    Object? current = scope;
    for (final segment in path.split('.')) {
      if (current is Map) {
        current = (current).cast<String, Object?>()[segment];
      } else if (current is List && segment == 'length') {
        current = current.length;
      } else if (current is String && segment == 'length') {
        current = current.length;
      } else {
        return null;
      }
    }
    return current;
  }

  static List<Object?> _resolveList(String path, Map<String, Object?> scope) {
    final value = _resolvePath(path, scope);
    return value is List ? value : const [];
  }

  // ----------------------------------------------------------- conditions --

  /// Evaluates a minimal condition language over previous step results:
  /// `path op literal` (op: > >= < <= == !=) or a bare `path` (truthy =
  /// non-null, non-false, non-empty). `length` is valid as a path segment
  /// on lists and strings.
  static bool evaluateCondition(String condition, Map<String, Object?> scope) {
    final match = RegExp(r'^(.+?)\s*(>=|<=|==|!=|>|<)\s*(.+)$')
        .firstMatch(condition.trim());
    if (match == null) {
      final value = _resolvePath(condition.trim(), scope);
      if (value == null || value == false) return false;
      if (value is List) return value.isNotEmpty;
      if (value is String) return value.isNotEmpty;
      if (value is num) return value != 0;
      return true;
    }

    final left = _resolvePath(match.group(1)!.trim(), scope);
    final operator = match.group(2)!;
    final rightRaw = match.group(3)!.trim();
    final Object? right = switch (rightRaw) {
      'true' => true,
      'false' => false,
      'null' => null,
      _ => num.tryParse(rightRaw) ??
          rightRaw.replaceAll(RegExp('''^["']|["']\$'''), ''),
    };

    if (operator == '==') return _looselyEqual(left, right);
    if (operator == '!=') return !_looselyEqual(left, right);
    if (left is num && right is num) {
      return switch (operator) {
        '>' => left > right,
        '>=' => left >= right,
        '<' => left < right,
        '<=' => left <= right,
        _ => false,
      };
    }
    return false;
  }

  static bool _looselyEqual(Object? left, Object? right) {
    if (left == right) return true;
    if (left is num && right is num) return left == right;
    return left?.toString() == right?.toString();
  }
}
