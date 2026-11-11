import 'package:exa_mobile/agent/security/capability_policy.dart';
import 'package:exa_mobile/agent/security/write_scope.dart';
import 'package:flutter_test/flutter_test.dart';

/// Outbound grants are the one way a scheduled job can be wider than its run
/// mode, and the lock-screen policy is the one way an interactive turn is
/// narrower. Both are boundaries enforced in the gate, so both are pinned
/// here rather than trusted to the prompt.
void main() {
  const gate = CapabilityGate();

  CapabilityDecision unattended(
    String tool, {
    JobPermissions permissions = JobPermissions.none,
    bool externalContent = false,
    WriteScopeLedger? ledger,
  }) =>
      gate.authorize(
        tool: tool,
        arguments: const {},
        runMode: AgentRunMode.unattended,
        jobPermissions: permissions,
        externalContentInScope: externalContent,
        writeLedger: ledger,
      );

  group('outbound grants', () {
    const granted = JobPermissions(outboundGrants: {'send_sms'});

    test('let a scheduled run use exactly the granted outbound tool', () {
      expect(unattended('send_sms').isAllowed, isFalse);
      expect(unattended('send_sms', permissions: granted).isAllowed, isTrue);
      // Not any other outbound tool.
      expect(unattended('send_whatsapp', permissions: granted).isAllowed,
          isFalse);
      expect(unattended('send_email', permissions: granted).isAllowed, isFalse);
    });

    test('cannot grant anything that is not outbound', () {
      // The gate only honours grants for outbound capability; a grant naming
      // a delete or a rule change is inert.
      const sneaky = JobPermissions(
          outboundGrants: {'delete_task', 'update_behavior', 'create_task'});
      expect(unattended('delete_task', permissions: sneaky).isAllowed, isFalse);
      expect(
          unattended('update_behavior', permissions: sneaky).isAllowed, isFalse);
      // create_task was already allowed as a local write - unchanged.
      expect(unattended('create_task', permissions: sneaky).isAllowed, isTrue);
    });

    test('still yield to blocks, allow-lists and outside content', () {
      expect(
        unattended('send_sms',
                permissions: const JobPermissions(
                    outboundGrants: {'send_sms'}, blockedTools: {'send_sms'}))
            .code,
        'job_tool_blocked',
      );
      expect(
        unattended('send_sms',
                permissions: const JobPermissions(
                    outboundGrants: {'send_sms'},
                    allowedTools: {'list_tasks'}))
            .code,
        'job_tool_not_allowed',
      );
      // A message the job read cannot talk it into texting someone.
      final afterReading =
          unattended('send_sms', permissions: granted, externalContent: true);
      expect(afterReading.isAllowed, isFalse);
      expect(afterReading.code, 'external_content_authorization');
    });

    test('do not apply to a turn awaiting clarification or on the lock screen',
        () {
      for (final policy in [
        CapabilityPolicy.readOnly,
        CapabilityPolicy.lockScreen,
      ]) {
        final decision = gate.authorize(
          tool: 'send_sms',
          arguments: const {},
          jobPermissions: granted,
          policy: policy,
        );
        expect(decision.isAllowed, isFalse, reason: policy.refusal.name);
      }
    });

    test('the unattended refusal points at the grant', () {
      expect(unattended('send_sms').reason, contains('outbound grant'));
      // Non-outbound refusals do not mention it - there is no such grant.
      expect(unattended('delete_task').reason,
          isNot(contains('outbound grant')));
    });

    test('round-trip through storage', () {
      final restored = JobPermissions.decode(granted.encode());
      expect(restored.outboundGrants, {'send_sms'});
      expect(restored.grantsOutbound('send_sms'), isTrue);
      expect(restored.isEmpty, isFalse);
      expect(JobPermissions.decode('{"outbound_grants": "send_sms"}')
          .outboundGrants, isEmpty);
    });

    test('widen the job write scope to the granted effect, and count it', () {
      final json = granted.encode();
      final plain = WriteScope.decode(json);
      expect(plain.allows(WriteEffect.messageSend), isFalse,
          reason: 'the unattended default deliberately omits message.send');
      final forJob = WriteScope.forJob(json);
      expect(forJob.allows(WriteEffect.messageSend), isTrue);
      // Nothing else widened.
      expect(forJob.allows(WriteEffect.taskCreateRecurring), isFalse);
      expect(forJob.allows(WriteEffect.jobCreate), isFalse);

      // Through the gate with the job's ledger: allowed, and counted.
      final ledger = WriteScopeLedger(forJob);
      final decision =
          unattended('send_sms', permissions: granted, ledger: ledger);
      expect(decision.isAllowed, isTrue, reason: decision.reason);
      // The plain scope's ledger would have refused it one line later.
      final refused = unattended('send_sms',
          permissions: granted, ledger: WriteScopeLedger(plain));
      expect(refused.isAllowed, isFalse);
      expect(refused.code, 'write_scope');
    });

    test('forJob is the plain decode when there are no grants', () {
      expect(WriteScope.forJob(null).allowedEffects,
          WriteScope.unattendedDefault.allowedEffects);
      expect(WriteScope.forJob('{not json').allowedEffects,
          WriteScope.unattendedDefault.allowedEffects);
      expect(WriteScope.forJob('{"allowed_effects": ["task.create"]}')
          .allowedEffects, {WriteEffect.taskCreate});
    });
  });

  group('lock-screen policy', () {
    CapabilityDecision locked(String tool) => gate.authorize(
          tool: tool,
          arguments: const {},
          policy: CapabilityPolicy.lockScreen,
        );

    test('reads and local writes run; nothing that leaves or destroys', () {
      for (final tool in [
        'list_tasks',
        'search',
        'read_email_context',
        'create_task',
        'create_reminder',
        'store_file',
      ]) {
        expect(locked(tool).isAllowed, isTrue, reason: tool);
      }
      for (final tool in [
        'send_sms',
        'place_call',
        'send_whatsapp',
        'send_email',
        'reply_to_chat',
        'delete_task',
        'create_scheduled_job',
        'update_behavior',
      ]) {
        final decision = locked(tool);
        expect(decision.isAllowed, isFalse, reason: tool);
        expect(decision.code, 'locked_device', reason: tool);
      }
    });

    test('the refusal tells the model to say "unlock", not "scheduled run"',
        () {
      final reason = locked('send_sms').reason ?? '';
      expect(reason, contains('unlock'));
      expect(reason.toLowerCase(), isNot(contains('scheduled run')));
    });

    test('an ambiguity block is narrower still', () {
      // The orchestrator prefers readOnly over the caller's policy while an
      // ambiguity block is up; under readOnly even a local write is refused.
      final decision = gate.authorize(
        tool: 'create_task',
        arguments: const {},
        policy: CapabilityPolicy.readOnly,
      );
      expect(decision.isAllowed, isFalse);
      expect(locked('create_task').isAllowed, isTrue);
    });
  });
}
