import 'dart:convert';

import '../models/agent_execution_report.dart';
import '../models/synthesized_response.dart';
import '../models/tool_execution_record.dart';
import '../models/turn_contract.dart';
import '../models/verification_result.dart';
import '../tools/tool_domains.dart';
import 'date_consistency.dart';

/// The deterministic turn verifier: compares the original contract, the tool
/// execution records, the normalized execution report, and the final
/// response - never judging completion from the final text alone.
///
/// Layer 1 (deterministic validation): required actions resolved, required
/// outputs declared, response non-empty, failures disclosed, no duplicate
/// side effects.
///
/// Layer 2 (evidence consistency): every success claim the response declares
/// must be supported by a matching successful tool record or report entry.
///
/// Layer 3 (model critic) is intentionally not implemented here: subjective
/// quality review is optional per the spec and must never be the
/// authoritative source for completed actions.
class TurnVerifier {
  const TurnVerifier();

  VerificationResult verify({
    required CompletionContract contract,
    required AgentExecutionReport report,
    required SynthesizedResponse response,
    List<ToolExecutionRecord> records = const [],
  }) {
    final issues = <VerificationIssue>[];
    final fabricatedDates = <String>[];

    // --- Layer 1: deterministic validation -------------------------------

    final missingOutputs =
        contract.requiredOutputs.difference(response.includedOutputs);
    for (final output in missingOutputs) {
      issues.add(VerificationIssue(
        code: 'missing_output',
        message: 'Required output ${output.wireName} is missing.',
        severity: VerificationSeverity.error,
        relatedOutput: output,
      ));
    }

    if (response.message.trim().isEmpty) {
      issues.add(const VerificationIssue(
        code: 'empty_response',
        message: 'The final response is empty.',
        severity: VerificationSeverity.error,
      ));
    }

    for (final action in contract.actions.where((a) => a.required)) {
      if (!action.isResolved) {
        // "Neither completed nor reported": a response that tells the
        // reader what was not done has reported it. Without this a repair
        // could never pass, however plainly it said so - the action is as
        // undone after the message is corrected as it was before.
        if (response.includesFailureReport) continue;
        issues.add(VerificationIssue(
          code: 'unresolved_action',
          message: 'Required action "${action.description}" was neither '
              'completed nor reported as failed.',
          severity: VerificationSeverity.error,
          relatedContractActionId: action.id,
        ));
      } else if (action.status == ContractItemStatus.failed &&
          !response.includesFailureReport) {
        issues.add(VerificationIssue(
          code: 'undisclosed_action_failure',
          message: 'Failed action "${action.description}" was not disclosed '
              'to the user.',
          severity: VerificationSeverity.critical,
          relatedContractActionId: action.id,
        ));
      }
    }

    // The resolver marks unmatched actions *completed* on a turn with no
    // tool records at all - a conversational answer often is the action -
    // so `isResolved` above can never catch the model that simply did not
    // act. This can: the turn was routed to a tool domain, planned required
    // actions, and executed nothing. That is "the jobs screen is now open"
    // with no open_screen call behind it.
    //
    // Gated on a non-core domain so an explanation the router happened to
    // phrase as an action is not accused of failing.
    final executedWork = records.any((record) => !record.isControlPlane);
    final routedToTools = contract.domains
            ?.any((domain) => domain != ToolDomains.core) ??
        false;
    if (!executedWork &&
        routedToTools &&
        contract.actions.any((action) => action.required) &&
        !response.includesFailureReport) {
      issues.add(VerificationIssue(
        code: 'action_claimed_without_execution',
        message: 'The turn planned '
            '${contract.actions.where((a) => a.required).length} required '
            'action(s) and ran no tools, but the response does not say so. '
            'State plainly what was not done.',
        severity: VerificationSeverity.critical,
      ));
    }

    if (report.hasFailures && !response.includesFailureReport) {
      issues.add(const VerificationIssue(
        code: 'undisclosed_failure',
        message: 'One or more failed actions were not disclosed.',
        severity: VerificationSeverity.critical,
      ));
    }

    // Duplicate side effects: two successful executions sharing an
    // idempotency key means the dedupe layer was bypassed.
    final seenKeys = <String>{};
    for (final record in records) {
      final key = record.idempotencyKey;
      if (key == null ||
          record.wasDeduplicated ||
          record.status != ToolExecutionStatus.success) {
        continue;
      }
      if (!seenKeys.add(key)) {
        issues.add(VerificationIssue(
          code: 'duplicate_action',
          message: '${record.toolName} executed twice with identical '
              'arguments in one turn.',
          severity: VerificationSeverity.critical,
          relatedToolRecordId: record.toolCallId,
        ));
      }
    }

    // --- Layer 2: evidence consistency ------------------------------------

    final unsupportedClaims = <String>[];
    for (final claim in response.claims) {
      if (!_claimSupported(claim, report, records)) {
        unsupportedClaims.add(claim.description.isEmpty
            ? claim.type
            : '${claim.type}: ${claim.description}');
        issues.add(VerificationIssue(
          code: 'unsupported_claim',
          message: 'The response claims "${claim.description}" '
              '(${claim.type}) but the execution report does not support it.',
          severity: VerificationSeverity.critical,
        ));
      }
    }

    // Claimed counts must not exceed the evidence: saying "three tasks"
    // when two exist is caught here for the claim types we can count.
    _checkClaimCounts(response, report, issues);

    // Dates stated in prose must come from the evidence. A model that
    // believes "today" is its training cutoff will quietly restate a
    // correctly stored future date as a past one - the actions are right and
    // only the sentence is wrong, so nothing else here would catch it.
    final evidence = StringBuffer()
      ..writeln(jsonEncode(report.toJson()))
      ..writeln(contract.originalRequest);
    for (final record in records) {
      evidence
        ..writeln(jsonEncode(record.arguments))
        ..writeln(record.rawResult == null ? '' : jsonEncode(record.rawResult))
        ..writeln(record.summary ?? '');
    }
    fabricatedDates.addAll(DateConsistency.unsupportedDates(
      message: response.message,
      evidence: evidence.toString(),
    ));
    for (final date in fabricatedDates) {
      issues.add(VerificationIssue(
        code: 'unsupported_date',
        message: 'The response states the date $date, which appears nowhere '
            'in what actually happened. Stored dates are authoritative.',
        severity: VerificationSeverity.critical,
      ));
    }

    // --- Scoring -----------------------------------------------------------

    final criticalCount = issues
        .where((issue) => issue.severity == VerificationSeverity.critical)
        .length;
    final errorCount = issues
        .where((issue) => issue.severity == VerificationSeverity.error)
        .length;
    final score =
        (1.0 - (criticalCount * 0.35) - (errorCount * 0.15)).clamp(0.0, 1.0);

    return VerificationResult(
      passed: criticalCount == 0 && errorCount == 0,
      score: score,
      issues: issues,
      missingOutputs: missingOutputs,
      unsupportedClaims: unsupportedClaims,
      fabricatedDates: fabricatedDates,
      authoritativeDates: _authoritativeLabels(report, records),
      requiresRepair: missingOutputs.isNotEmpty ||
          unsupportedClaims.isNotEmpty ||
          errorCount > 0 ||
          criticalCount > 0,
      requiresUserAttention: criticalCount > 0,
    );
  }

  /// The `..._label` values the tools produced ("Friday, July 31, 2026 at
  /// 23:59"), which a repair must copy verbatim instead of working a date
  /// out for itself.
  static List<String> _authoritativeLabels(
      AgentExecutionReport report, List<ToolExecutionRecord> records) {
    final labels = <String>{};
    void scan(Object? value) {
      if (value is Map) {
        for (final entry in value.entries) {
          if (entry.key.toString().endsWith('_label') &&
              entry.value is String) {
            labels.add(entry.value as String);
          } else {
            scan(entry.value);
          }
        }
      } else if (value is List) {
        value.forEach(scan);
      }
    }

    scan(report.toJson());
    for (final record in records) {
      scan(record.rawResult);
    }
    return labels.toList()..sort();
  }

  /// Whether one declared claim is backed by the report or a successful
  /// record. Claim types map onto the report's normalized sections; unknown
  /// claim types fall back to requiring any successful record (they cannot
  /// be fabricated wholesale on a turn where nothing succeeded).
  bool _claimSupported(
    ResponseClaim claim,
    AgentExecutionReport report,
    List<ToolExecutionRecord> records,
  ) {
    bool successfulTool(Set<String> names) => records.any((record) =>
        names.contains(record.toolName) &&
        record.status == ToolExecutionStatus.success);
    final anySuccess = records
        .any((record) => record.status == ToolExecutionStatus.success);

    return switch (claim.type) {
      'task_created' => report.tasksCreated.isNotEmpty,
      'event_created' || 'meeting_added' => report.eventsCreated.isNotEmpty,
      'event_modified' || 'event_updated' => report.eventsModified.isNotEmpty,
      'email_sent' => successfulTool(const {'send_email'}),
      // "Handled" is one idea to the model and two tools here. The prompt
      // named a claim for mail and none for chats, so a chat digest filed
      // "1 chat message read and marked as handled" under the mail one, was
      // held to a mail step it never had reason to run, and went for repair
      // with a true message: seven runs of eighteen in one morning. Either
      // name is backed by either tool; what is checked is that something
      // was marked, not which inbox the model thinks it came from.
      'emails_digested' ||
      'email_digested' ||
      'messages_digested' ||
      'message_digested' =>
        successfulTool(
            const {'mark_email_digested', 'mark_message_digested'}),
      'emails_reviewed' ||
      'emails_read' ||
      'messages_reviewed' ||
      'messages_read' =>
        report.emailDigestItems.isNotEmpty ||
            successfulTool(const {
              'read_email_context',
              'read_message_context',
              'read_chat',
            }),
      'reminder_created' => successfulTool(const {'create_reminder'}),
      'reminder_cancelled' || 'reminder_deleted' =>
        successfulTool(const {'cancel_reminder'}),
      'task_completed' => successfulTool(const {'complete_task'}),
      'task_updated' => successfulTool(const {'update_task'}),
      'task_deleted' => successfulTool(const {'delete_task'}),
      'file_stored' || 'file_saved' || 'file_deleted' =>
        report.filesAffected.isNotEmpty,
      'screen_created' => report.screensCreated.isNotEmpty,
      'rule_changed' || 'behavior_changed' || 'rule_activated' =>
        report.rulesChanged.isNotEmpty,
      'job_created' || 'job_scheduled' =>
        successfulTool(const {'create_scheduled_job'}),
      // Informational claims (answered, summarized, searched...) need no
      // side-effect evidence; anything else needs at least one success.
      'answered' || 'summarized' || 'searched' || 'listed' || 'read' => true,
      _ => records.isEmpty || anySuccess,
    };
  }

  /// Compares claimed counts per countable claim type against the report.
  void _checkClaimCounts(
    SynthesizedResponse response,
    AgentExecutionReport report,
    List<VerificationIssue> issues,
  ) {
    final countable = <String, int>{
      'task_created': report.tasksCreated.length,
      'event_created': report.eventsCreated.length,
    };
    for (final entry in countable.entries) {
      final claimed =
          response.claims.where((claim) => claim.type == entry.key).length;
      if (claimed > entry.value) {
        issues.add(VerificationIssue(
          code: 'claim_count_mismatch',
          message: 'The response claims $claimed ${entry.key} but the '
              'report contains ${entry.value}.',
          severity: VerificationSeverity.critical,
        ));
      }
    }
  }
}
