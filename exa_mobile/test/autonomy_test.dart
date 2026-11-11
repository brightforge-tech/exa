import 'package:exa_mobile/agent/security/capability_policy.dart';
import 'package:exa_mobile/agent/security/write_scope.dart';
import 'package:exa_mobile/data/database/app_database.dart';
import 'package:exa_mobile/data/models/autonomy_level.dart';
import 'package:exa_mobile/data/repositories/settings_repository.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

/// Full autonomy is the v3 default: no confirmations, every capability in
/// every run mode. It is still enforced in the gate rather than the prompt,
/// so the widening is pinned here the same way the guarded refusals are
/// pinned in capability_gate_test - and guarded must stay exactly v2.
void main() {
  const gate = CapabilityGate();

  CapabilityDecision unattended(
    String tool, {
    CapabilityPolicy? policy,
    JobPermissions permissions = JobPermissions.none,
    bool externalContent = false,
    bool bypassExternalContent = false,
    WriteScopeLedger? ledger,
  }) =>
      gate.authorize(
        tool: tool,
        arguments: const {},
        runMode: AgentRunMode.unattended,
        policy: policy,
        jobPermissions: permissions,
        externalContentInScope: externalContent,
        bypassExternalContentGate: bypassExternalContent,
        writeLedger: ledger,
      );

  group('AutonomyLevel', () {
    test('defaults to full unless the setting says guarded', () {
      expect(AutonomyLevel.fromWire(null), AutonomyLevel.full);
      expect(AutonomyLevel.fromWire(''), AutonomyLevel.full);
      expect(AutonomyLevel.fromWire('full'), AutonomyLevel.full);
      expect(AutonomyLevel.fromWire('guarded'), AutonomyLevel.guarded);
      expect(AutonomyLevel.guarded.wireName, 'guarded');
    });
  });

  group('CapabilityPolicy.autonomous', () {
    const auto = CapabilityPolicy.autonomous;

    test('lets an unattended run send, delete, rewrite rules and start jobs',
        () {
      for (final tool in [
        'send_email',
        'send_sms',
        'add_to_phone_calendar',
        'delete_task',
        'delete_scheduled_job',
        'update_behavior',
        'create_scheduled_job',
        'run_scheduled_job_now',
        'some_future_tool',
      ]) {
        expect(unattended(tool, policy: auto).isAllowed, isTrue,
            reason: tool);
      }
    });

    test('is not implied: the guarded defaults are unchanged', () {
      expect(unattended('send_email').isAllowed, isFalse);
      expect(unattended('delete_task').isAllowed, isFalse);
      expect(unattended('run_scheduled_job_now').isAllowed, isFalse);
    });

    test('still honours job blocks and allow-lists', () {
      expect(
        unattended('send_email',
                policy: auto,
                permissions: const JobPermissions(blockedTools: {'send_email'}))
            .code,
        'job_tool_blocked',
      );
      expect(
        unattended('send_email',
                policy: auto,
                permissions: const JobPermissions(allowedTools: {'list_tasks'}))
            .code,
        'job_tool_not_allowed',
      );
    });

    test('outside content blocks only while the gate is not bypassed', () {
      final guardedByContent =
          unattended('send_email', policy: auto, externalContent: true);
      expect(guardedByContent.isAllowed, isFalse);
      expect(guardedByContent.code, 'external_content_authorization');

      final bypassed = unattended('send_email',
          policy: auto, externalContent: true, bypassExternalContent: true);
      expect(bypassed.isAllowed, isTrue);
    });

    test('the write ledger still counts under full autonomy', () {
      final ledger = WriteScopeLedger(WriteScope.autonomous);
      for (var i = 0; i < WriteScope.autonomous.maxRecordsPerRun; i++) {
        ledger.record(WriteEffect.taskCreate);
      }
      final capped = unattended('create_task', policy: auto, ledger: ledger);
      expect(capped.isAllowed, isFalse);
      expect(capped.code, 'write_scope');
    });
  });

  group('WriteScope.autonomous', () {
    test('allows recurring work and every effect', () {
      final ledger = WriteScopeLedger(WriteScope.autonomous);
      expect(ledger.check(WriteEffect.taskCreateRecurring, const {}), isNull);
      for (final effect in WriteEffect.values) {
        expect(WriteScope.autonomous.allows(effect), isTrue,
            reason: effect.wireName);
      }
    });

    test('keeps per-effect and per-run caps as loop-breakers', () {
      final ledger = WriteScopeLedger(WriteScope.autonomous);
      final perEffect =
          WriteScope.autonomous.ruleFor(WriteEffect.taskCreate).maxPerRun;
      for (var i = 0; i < perEffect; i++) {
        ledger.record(WriteEffect.taskCreate);
      }
      final refusal = ledger.check(WriteEffect.taskCreate, const {});
      expect(refusal, isNotNull);
      expect(refusal, contains('limit'));
      // A different effect is still fine until the run-wide cap.
      expect(ledger.check(WriteEffect.reminderCreateOneTime, const {}),
          isNull);
    });

    test('the guarded unattended default is untouched', () {
      final ledger = WriteScopeLedger(WriteScope.unattendedDefault);
      expect(ledger.check(WriteEffect.taskCreateRecurring, const {}),
          isNotNull);
      expect(ledger.check(WriteEffect.messageSend, const {}), isNotNull);
    });
  });

  group('CapabilityContext', () {
    test('defaults to guarded so direct callers keep every gate', () {
      const context = CapabilityContext.interactive;
      expect(context.autonomy, AutonomyLevel.guarded);
      expect(context.autoApproveConfirmations, isFalse);
      expect(context.bypassUserPermissionGate, isFalse);
      expect(context.bypassExternalContentGate, isFalse);
    });

    test('full autonomy switches all three off', () {
      const context = CapabilityContext(autonomy: AutonomyLevel.full);
      expect(context.autoApproveConfirmations, isTrue);
      expect(context.bypassUserPermissionGate, isTrue);
      expect(context.bypassExternalContentGate, isTrue);
    });
  });

  group('SettingsRepository', () {
    late AppDatabase database;

    setUpAll(() {
      sqfliteFfiInit();
      databaseFactory = databaseFactoryFfi;
    });

    setUp(() async {
      database = AppDatabase();
      await database.open(overridePath: inMemoryDatabasePath);
    });

    tearDown(() => database.close());

    test('a fresh install is fully autonomous and the choice round-trips',
        () async {
      final settings = SettingsRepository(database);
      expect(await settings.getAutonomyLevel(), AutonomyLevel.full);
      await settings.setAutonomyLevel(AutonomyLevel.guarded);
      expect(await settings.getAutonomyLevel(), AutonomyLevel.guarded);
      await settings.setAutonomyLevel(AutonomyLevel.full);
      expect(await settings.getAutonomyLevel(), AutonomyLevel.full);
    });
  });
}
