import 'package:exa_mobile/agent/security/capability_policy.dart';
import 'package:flutter_test/flutter_test.dart';

/// The capability gate is a security boundary, not a prompt: an unattended
/// run must be unable to send, delete, or rewrite its own rules even if the
/// model asks for it.
void main() {
  const gate = CapabilityGate();

  CapabilityDecision unattended(String tool,
          {JobPermissions permissions = JobPermissions.none}) =>
      gate.authorize(
        tool: tool,
        arguments: const {},
        runMode: AgentRunMode.unattended,
        jobPermissions: permissions,
      );

  group('unattended runs', () {
    test('cannot reach other people or external services', () {
      final decision = unattended('send_email');
      expect(decision.isAllowed, isFalse);
      expect(decision.code, 'unattended_capability');
      expect(unattended('add_to_phone_calendar').isAllowed, isFalse);
    });

    test('cannot delete data', () {
      for (final tool in [
        'delete_task',
        'delete_email',
        'delete_file',
        'delete_schedule_event',
        'delete_scheduled_job',
      ]) {
        expect(unattended(tool).isAllowed, isFalse, reason: tool);
      }
    });

    test('cannot rewrite their own rules or schedule', () {
      for (final tool in [
        'propose_behavior_change',
        'update_behavior',
        'create_scheduled_job',
        'pause_scheduled_job',
      ]) {
        expect(unattended(tool).isAllowed, isFalse, reason: tool);
      }
    });

    test('cannot start other jobs', () {
      final decision = unattended('run_scheduled_job_now');
      expect(decision.isAllowed, isFalse);
    });

    test('can still read and do local work', () {
      for (final tool in [
        'list_tasks',
        'search',
        'read_email_context',
        'create_task',
        'create_reminder',
        'cancel_reminder',
        'create_schedule_event',
        'sync_emails',
        'store_file',
      ]) {
        expect(unattended(tool).isAllowed, isTrue, reason: tool);
      }
    });

    test('an unclassified tool is refused rather than assumed safe', () {
      // A tool added later without being classified must not silently gain
      // background access.
      expect(unattended('some_future_tool').isAllowed, isFalse);
      expect(CapabilityGate.capabilityOf('some_future_tool'),
          ToolCapability.outbound);
    });

    test('the refusal tells the model what to do instead', () {
      final decision = unattended('send_email');
      expect(decision.reason, contains('skipped'));
    });
  });

  group('interactive runs', () {
    test('keep every capability - confirmation is the gate there', () {
      for (final tool in ['send_email', 'delete_task', 'update_behavior']) {
        final decision = gate.authorize(
          tool: tool,
          arguments: const {},
          runMode: AgentRunMode.interactive,
        );
        expect(decision.isAllowed, isTrue, reason: tool);
      }
    });
  });

  group('job permissions', () {
    test('an allow-list excludes everything else', () {
      const permissions = JobPermissions(
          allowedTools: {'search_email', 'create_task'});
      expect(unattended('create_task', permissions: permissions).isAllowed,
          isTrue);
      final denied =
          unattended('create_reminder', permissions: permissions);
      expect(denied.isAllowed, isFalse);
      expect(denied.code, 'job_tool_not_allowed');
    });

    test('an allow-list never keeps a job from reading', () {
      // A job narrowed to "create tasks from my chats" still has to look at
      // the tasks, reminders and schedule it already has, or it files
      // duplicates and books clashes - the very thing the list is for.
      const permissions = JobPermissions(
          allowedTools: {'read_message_context', 'create_task'});
      for (final tool in [
        'list_tasks',
        'list_reminders',
        'list_schedule',
        'find_contact',
      ]) {
        expect(unattended(tool, permissions: permissions).isAllowed, isTrue,
            reason: tool);
      }
      // Writes outside the list are still refused.
      expect(unattended('create_reminder', permissions: permissions).code,
          'job_tool_not_allowed');
      // A block is still the way to keep a read away from a job.
      const blocked = JobPermissions(
        allowedTools: {'create_task'},
        blockedTools: {'list_reminders'},
      );
      expect(unattended('list_reminders', permissions: blocked).code,
          'job_tool_blocked');
    });

    test('an allow-list admits other edits of the same kind', () {
      // A job that may add an event has to be able to move the one it
      // added when the next message reschedules it.
      const permissions =
          JobPermissions(allowedTools: {'create_schedule_event'});
      expect(
          unattended('update_schedule_event', permissions: permissions)
              .isAllowed,
          isTrue);
      expect(
          unattended('sync_device_calendar', permissions: permissions)
              .isAllowed,
          isTrue);
      // A different kind of record is still outside the list, and a
      // heavier class of change is never admitted this way.
      expect(unattended('create_task', permissions: permissions).code,
          'job_tool_not_allowed');
      expect(
          unattended('delete_schedule_event', permissions: permissions)
              .isAllowed,
          isFalse);
      // Full autonomy permits sending, but a job allowed to mark messages
      // handled is not thereby allowed to send one.
      final send = gate.authorize(
        tool: 'send_whatsapp',
        arguments: const {},
        runMode: AgentRunMode.unattended,
        jobPermissions:
            const JobPermissions(allowedTools: {'mark_message_digested'}),
        policy: CapabilityPolicy.autonomous,
      );
      expect(send.code, 'job_tool_not_allowed');
    });

    test('a block beats an allow', () {
      const permissions = JobPermissions(
        allowedTools: {'create_task'},
        blockedTools: {'create_task'},
      );
      final decision =
          unattended('create_task', permissions: permissions);
      expect(decision.isAllowed, isFalse);
      expect(decision.code, 'job_tool_blocked');
    });

    test('a job cannot widen what its run mode allows', () {
      // Listing send_email as allowed does not make it available to a
      // background run: capability restrictions outrank job permissions.
      const permissions = JobPermissions(allowedTools: {'send_email'});
      final decision = unattended('send_email', permissions: permissions);
      expect(decision.isAllowed, isFalse);
      expect(decision.code, 'unattended_capability');
    });

    test('permissions round-trip through storage, malformed ones are none',
        () {
      const permissions = JobPermissions(
        allowedTools: {'create_task'},
        blockedTools: {'send_email'},
      );
      final restored = JobPermissions.decode(permissions.encode());
      expect(restored.allowedTools, {'create_task'});
      expect(restored.blockedTools, {'send_email'});

      expect(JobPermissions.decode('{not json').isEmpty, isTrue);
      expect(JobPermissions.decode(null).isEmpty, isTrue);
    });
  });

  group('read-only (awaiting clarification)', () {
    CapabilityDecision readOnly(String tool) => gate.authorize(
          tool: tool,
          arguments: const {},
          policy: CapabilityPolicy.readOnly,
        );

    test('every kind of change is refused, on an interactive turn', () {
      // The run mode is interactive - a user is right there - so this is not
      // the unattended boundary. It is "we do not yet know what you meant".
      for (final tool in [
        'send_email', // outbound
        'delete_task', // destructive
        'create_task', // localWrite
        'create_reminder',
        'update_schedule_event',
        'create_scheduled_job', // selfModifying
        'write_file',
      ]) {
        final decision = readOnly(tool);
        expect(decision.isAllowed, isFalse, reason: tool);
        expect(decision.code, 'awaiting_clarification', reason: tool);
      }
    });

    test('a local write is refused too, unlike an unattended run', () {
      // The distinction that matters: an unattended run may create a task,
      // because it knows what it is doing and nobody needs to approve it. An
      // ambiguous turn may not, because a task created on the wrong reading of
      // the request is exactly the surprise this exists to prevent.
      expect(unattended('create_task').isAllowed, isTrue);
      expect(readOnly('create_task').isAllowed, isFalse);
    });

    test('reads stay available, so the question can name the candidates', () {
      for (final tool in [
        'list_tasks',
        'list_reminders',
        'list_schedule',
        'search',
        'read_email_context',
        'read_file',
      ]) {
        expect(readOnly(tool).isAllowed, isTrue, reason: tool);
      }
    });

    test('the refusal tells the model to ask, not that nobody can approve', () {
      final reason = readOnly('delete_task').reason ?? '';
      // The message is what the model acts on. Told the unattended reason it
      // would report "blocked in a scheduled run", which is false here and
      // sends it looking for the wrong recovery.
      expect(reason, contains('one question'));
      expect(reason.toLowerCase(), isNot(contains('scheduled run')));
    });
  });
}
