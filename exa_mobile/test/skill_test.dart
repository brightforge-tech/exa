import 'package:exa_mobile/agent/models/agent_ids.dart';
import 'package:exa_mobile/agent/models/tool_execution_record.dart';
import 'package:exa_mobile/agent/models/turn_contract.dart';
import 'package:exa_mobile/agent/skills/models/workflow_skill.dart';
import 'package:exa_mobile/agent/skills/skill_executor.dart';
import 'package:exa_mobile/agent/skills/skill_matcher.dart';
import 'package:exa_mobile/agent/skills/skill_registry.dart';
import 'package:exa_mobile/agent/skills/workflow_skill_repository.dart';
import 'package:exa_mobile/data/database/app_database.dart';
import 'package:exa_mobile/data/repositories/behavior_repository.dart';
import 'package:exa_mobile/data/repositories/browser_context_repository.dart';
import 'package:exa_mobile/data/repositories/dynamic_screen_repository.dart';
import 'package:exa_mobile/data/repositories/email_repository.dart';
import 'package:exa_mobile/data/repositories/idempotency_repository.dart';
import 'package:exa_mobile/data/repositories/job_repository.dart';
import 'package:exa_mobile/data/repositories/mail_account_repository.dart';
import 'package:exa_mobile/data/repositories/pending_calendar_repository.dart';
import 'package:exa_mobile/data/repositories/reminder_repository.dart';
import 'package:exa_mobile/data/repositories/schedule_repository.dart';
import 'package:exa_mobile/data/repositories/task_repository.dart';
import 'package:exa_mobile/data/repositories/tool_call_repository.dart';
import 'package:exa_mobile/agent/tools/tool_registry.dart';
import 'package:exa_mobile/services/background_jobs/job_runner.dart';
import 'package:exa_mobile/services/browser/browser_bridge.dart';
import 'package:exa_mobile/services/calendar/device_calendar_service.dart';
import 'package:exa_mobile/services/mail/mail_service.dart';
import 'package:exa_mobile/services/notifications/notification_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

ToolRegistry buildRegistry(AppDatabase database) {
  final notifications = NotificationService();
  final mailAccounts = MailAccountRepository(database);
  final emails = EmailRepository(database);
  final schedule = ScheduleRepository(database);
  return ToolRegistry(
    tasks: TaskRepository(database),
    reminders: ReminderRepository(database),
    schedule: schedule,
    behaviors: BehaviorRepository(database),
    screens: DynamicScreenRepository(database),
    toolCalls: ToolCallRepository(database),
    notifications: notifications,
    database: database,
    jobs: JobRepository(database),
    jobRunner: JobRunner(database: database, notifications: notifications),
    browserContext: BrowserContextRepository(database),
    emails: emails,
    browserBridge: BrowserBridge(),
    mailAccounts: mailAccounts,
    mail: MailService(accounts: mailAccounts, emails: emails),
    deviceCalendar: DeviceCalendarService(schedule: schedule),
    pendingCalendar: PendingCalendarRepository(database),
    idempotency: IdempotencyRepository(database),
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  late AppDatabase database;
  late WorkflowSkillRepository skills;
  late SkillMatcher matcher;
  late ToolRegistry registry;
  late SkillExecutor executor;

  setUp(() async {
    database = AppDatabase();
    await database.open(overridePath: inMemoryDatabasePath);
    skills = WorkflowSkillRepository(database);
    await SkillRegistry(skills).seedSystemSkills();
    matcher = SkillMatcher(skills);
    registry = buildRegistry(database);
    executor = SkillExecutor(registry: registry, repository: skills);
  });

  tearDown(() => database.close());

  group('seeding and versioning', () {
    test('system skills are seeded once, idempotently', () async {
      final before = await skills.listAllVersions();
      await SkillRegistry(skills).seedSystemSkills();
      final after = await skills.listAllVersions();
      expect(after.length, before.length,
          reason: 'reseeding must not duplicate versions');
      expect(before.map((s) => s.name).toSet(), {
        'digest_emails',
        'daily_review',
        'analyze_snippet',
        'prepare_daily_briefing',
        'follow_up_overdue_tasks',
      });
    });

    test('the daily review recipe looks at the day, not just the mail',
        () async {
      final review = (await skills.getLatestByName('daily_review'))!;
      final tools = review.steps.map((s) => s.toolName).toSet();
      expect(tools,
          containsAll(['list_schedule', 'list_tasks', 'list_reminders']));
      expect(tools,
          containsAll(['sync_emails', 'read_email_context',
              'mark_email_digested']));
      // Mail trouble must not stop the review of the day itself.
      expect(
          review.steps.firstWhere((s) => s.id == 'read').failurePolicy,
          SkillStepFailurePolicy.continueAndReport);
    });

    test('a new version coexists with the old; latest wins', () async {
      final v1 = (await skills.getLatestByName('follow_up_overdue_tasks'))!;
      await skills.insert(WorkflowSkill(
        id: AgentId.skill(),
        name: v1.name,
        description: v1.description,
        version: 2,
        mode: v1.mode,
        requiredDomains: v1.requiredDomains,
        requiredOutputs: v1.requiredOutputs,
        triggerExamples: v1.triggerExamples,
        steps: v1.steps,
        createdAt: DateTime.now(),
        updatedAt: DateTime.now(),
      ));
      final latest = (await skills.getLatestByName(v1.name))!;
      expect(latest.version, 2);
      final old = await skills.getByNameVersion(v1.name, 1);
      expect(old, isNotNull, reason: 'old versions stay immutable');
      final enabled = await skills.listEnabled();
      expect(enabled.where((s) => s.name == v1.name), hasLength(1));
    });
  });

  group('SkillMatcher', () {
    test('exact trigger phrase matches with high confidence', () async {
      final match = await matcher.match(userRequest: 'Digest my emails');
      expect(match, isNotNull);
      expect(match!.skill.name, 'digest_emails');
      expect(match.confidence, greaterThanOrEqualTo(0.9));
    });

    test('the scheduled daily review matches its own skill, not the '
        'email-only digest', () async {
      // The job's fixed prompt is phrased to hit exactly this trigger; if
      // digest_emails won, the review would never look at the schedule.
      final match =
          await matcher.match(userRequest: JobRunner.dailyReviewPrompt);
      expect(match, isNotNull);
      expect(match!.skill.name, 'daily_review');
      expect(match.confidence, greaterThanOrEqualTo(0.9));

      // Even when the router nominates the digest skill, the trigger wins.
      final nominated = await matcher.match(
        userRequest: JobRunner.dailyReviewPrompt,
        routerSkillName: 'digest_emails',
        routerConfidence: 0.9,
      );
      expect(nominated!.skill.name, 'daily_review');
    });

    test('explicit command names the skill', () async {
      final match = await matcher.match(
          userRequest: 'run the prepare daily briefing skill please');
      expect(match!.skill.name, 'prepare_daily_briefing');
      expect(match.matchSource, 'explicit_command');
    });

    test('unrelated requests match nothing', () async {
      final match = await matcher.match(
          userRequest: 'what is the capital of France?');
      expect(match, isNull);
    });

    test('router nomination is validated against the registry', () async {
      final bogus = await matcher.match(
        userRequest: 'sort things out',
        routerSkillName: 'not_a_real_skill',
        routerConfidence: 0.99,
      );
      expect(bogus, isNull);

      final real = await matcher.match(
        userRequest: 'go through my inbox for me',
        routerSkillName: 'digest_emails',
        routerConfidence: 0.9,
      );
      expect(real, isNotNull);
      expect(real!.skill.name, 'digest_emails');
    });
  });

  group('SkillExecutor', () {
    test('deterministic briefing skill executes its steps in order '
        'through the registry', () async {
      await registry.execute(
          'create_task', {'title': 'Overdue thing', 'priority': 'High'});
      final skill = (await skills.getLatestByName('prepare_daily_briefing'))!;
      final result = await executor.execute(
        skill: skill,
        inputs: const {},
        agentTurnId: 'turn_test',
      );
      expect(result.status, 'completed');
      expect(result.toolRecords.map((r) => r.toolName).toList(),
          ['list_schedule', 'list_tasks', 'list_reminders']);
      expect(
          result.toolRecords
              .every((r) => r.status == ToolExecutionStatus.success),
          isTrue);
      // The execution is durably logged.
      final executions = await database.db.query('skill_executions');
      expect(executions, hasLength(1));
      expect(executions.single['status'], 'completed');
    });

    test('dependency on a failed step skips dependents', () async {
      final skill = WorkflowSkill(
        id: AgentId.skill(),
        name: 'test_dep_skill',
        description: 'test',
        version: 1,
        mode: SkillExecutionMode.deterministic,
        requiredDomains: const {},
        requiredOutputs: const {ResponseOutputType.confirmation},
        steps: const [
          SkillStep(
            id: 'boom',
            name: 'Fails',
            toolName: 'complete_task',
            argumentTemplate: {'id': 'missing_task'},
            failurePolicy: SkillStepFailurePolicy.continueAndReport,
          ),
          SkillStep(
            id: 'after',
            name: 'Depends on boom',
            toolName: 'list_tasks',
            dependsOn: ['boom'],
          ),
        ],
        createdAt: DateTime.now(),
        updatedAt: DateTime.now(),
      );
      await skills.insert(skill);
      final result = await executor.execute(
          skill: skill, inputs: const {}, agentTurnId: 'turn_test');
      expect(result.status, 'partial');
      expect(result.toolRecords.map((r) => r.toolName), ['complete_task'],
          reason: 'dependent step must not run');
    });

    test('failed mandatory stop-step aborts the skill', () async {
      final skill = WorkflowSkill(
        id: AgentId.skill(),
        name: 'test_stop_skill',
        description: 'test',
        version: 1,
        mode: SkillExecutionMode.deterministic,
        requiredDomains: const {},
        requiredOutputs: const {},
        steps: const [
          SkillStep(
            id: 'boom',
            name: 'Fails hard',
            toolName: 'complete_task',
            argumentTemplate: {'id': 'missing_task'},
            failurePolicy: SkillStepFailurePolicy.stop,
          ),
          SkillStep(id: 'never', name: 'Never runs', toolName: 'list_tasks'),
        ],
        createdAt: DateTime.now(),
        updatedAt: DateTime.now(),
      );
      await skills.insert(skill);
      final result = await executor.execute(
          skill: skill, inputs: const {}, agentTurnId: 'turn_test');
      expect(result.status, 'failed');
      expect(result.failureReason, contains('Fails hard'));
      expect(result.toolRecords.map((r) => r.toolName),
          isNot(contains('list_tasks')));
    });

    test('condition gates a step off', () async {
      final skill = WorkflowSkill(
        id: AgentId.skill(),
        name: 'test_condition_skill',
        description: 'test',
        version: 1,
        mode: SkillExecutionMode.deterministic,
        requiredDomains: const {},
        requiredOutputs: const {},
        steps: const [
          SkillStep(id: 'list', name: 'List tasks', toolName: 'list_tasks'),
          SkillStep(
            id: 'complete',
            name: 'Complete first task',
            toolName: 'complete_task',
            dependsOn: ['list'],
            condition: 'list.count > 0',
            argumentTemplate: {'id': '{{list.tasks.0.id}}'},
          ),
        ],
        createdAt: DateTime.now(),
        updatedAt: DateTime.now(),
      );
      await skills.insert(skill);
      // No tasks exist: the conditional step is skipped, not failed.
      final result = await executor.execute(
          skill: skill, inputs: const {}, agentTurnId: 'turn_test');
      expect(result.status, 'completed');
      expect(result.toolRecords.map((r) => r.toolName), ['list_tasks']);
    });

    test('forEach fans out over a previous list result', () async {
      await registry.execute('create_task', {'title': 'One'});
      await registry.execute('create_task', {'title': 'Two'});
      final skill = WorkflowSkill(
        id: AgentId.skill(),
        name: 'test_foreach_skill',
        description: 'test',
        version: 1,
        mode: SkillExecutionMode.deterministic,
        requiredDomains: const {},
        requiredOutputs: const {},
        steps: const [
          SkillStep(id: 'list', name: 'List', toolName: 'list_tasks'),
          SkillStep(
            id: 'complete_all',
            name: 'Complete each',
            toolName: 'complete_task',
            dependsOn: ['list'],
            forEachPath: 'list.tasks',
            argumentTemplate: {'id': '{{item.id}}'},
          ),
        ],
        createdAt: DateTime.now(),
        updatedAt: DateTime.now(),
      );
      await skills.insert(skill);
      final result = await executor.execute(
          skill: skill, inputs: const {}, agentTurnId: 'turn_test');
      expect(result.status, 'completed');
      expect(
          result.toolRecords
              .where((r) => r.toolName == 'complete_task')
              .length,
          2);
      final open = await registry.execute('list_tasks', {'open_only': true});
      expect((open.data as Map)['count'], 0);
    });

    test('confirmation-gated tools are denied without approval and cannot '
        'be bypassed by a skill', () async {
      await registry.execute('create_task', {'title': 'Doomed'});
      final listResult = await registry.execute('list_tasks', {});
      final taskId =
          (((listResult.data as Map)['tasks'] as List).first as Map)['id'];
      final skill = WorkflowSkill(
        id: AgentId.skill(),
        name: 'test_confirm_skill',
        description: 'test',
        version: 1,
        mode: SkillExecutionMode.deterministic,
        requiredDomains: const {},
        requiredOutputs: const {},
        steps: [
          SkillStep(
            id: 'del',
            name: 'Delete task',
            toolName: 'delete_task',
            argumentTemplate: {'id': taskId},
          ),
        ],
        createdAt: DateTime.now(),
        updatedAt: DateTime.now(),
      );
      await skills.insert(skill);

      // No onConfirm callback = declined.
      final denied = await executor.execute(
          skill: skill, inputs: const {}, agentTurnId: 'turn_a');
      expect(denied.status, 'cancelled');
      expect(denied.toolRecords.single.status, ToolExecutionStatus.denied);

      // Approved: runs.
      final approved = await executor.execute(
        skill: skill,
        inputs: const {},
        agentTurnId: 'turn_b',
        onConfirm: (tool, input) async => true,
      );
      expect(approved.status, 'completed');
    });

    test('re-running a skill in the same turn cannot duplicate side effects',
        () async {
      final skill = WorkflowSkill(
        id: AgentId.skill(),
        name: 'test_idempotent_skill',
        description: 'test',
        version: 1,
        mode: SkillExecutionMode.deterministic,
        requiredDomains: const {},
        requiredOutputs: const {},
        steps: const [
          SkillStep(
            id: 'make',
            name: 'Create task',
            toolName: 'create_task',
            argumentTemplate: {'title': 'Exactly once'},
          ),
        ],
        createdAt: DateTime.now(),
        updatedAt: DateTime.now(),
      );
      await skills.insert(skill);

      await executor.execute(
          skill: skill, inputs: const {}, agentTurnId: 'turn_same');
      final second = await executor.execute(
          skill: skill, inputs: const {}, agentTurnId: 'turn_same');
      expect(second.status, 'completed');
      expect(second.toolRecords.single.wasDeduplicated, isTrue);

      final tasks = await registry.execute('list_tasks', {});
      expect((tasks.data as Map)['count'], 1,
          reason: 'the duplicate create was answered from the first result');
    });

    test('argument templates resolve inputs and step results', () {
      final resolved = SkillExecutor.resolveArguments(
        {
          'title': '{{input.title}}',
          'note': 'From {{read.count}} emails',
          'raw': 42,
        },
        {
          'input': {'title': 'Hello'},
          'read': {'count': 3},
        },
      );
      expect(resolved['title'], 'Hello');
      expect(resolved['note'], 'From 3 emails');
      expect(resolved['raw'], 42);
    });

    test('condition language covers comparisons, equality, and truthiness',
        () {
      final scope = {
        'read': {
          'count': 2,
          'emails': [1, 2],
          'ok': true,
          'empty': <Object?>[],
        },
      };
      expect(SkillExecutor.evaluateCondition('read.count > 0', scope), isTrue);
      expect(SkillExecutor.evaluateCondition('read.count >= 2', scope), isTrue);
      expect(SkillExecutor.evaluateCondition('read.count < 2', scope), isFalse);
      expect(SkillExecutor.evaluateCondition('read.emails.length > 0', scope),
          isTrue);
      expect(SkillExecutor.evaluateCondition('read.ok == true', scope), isTrue);
      expect(
          SkillExecutor.evaluateCondition('read.ok != true', scope), isFalse);
      expect(SkillExecutor.evaluateCondition('read.empty', scope), isFalse);
      expect(SkillExecutor.evaluateCondition('read.missing', scope), isFalse);
    });
  });
}
