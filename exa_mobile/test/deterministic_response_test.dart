import 'package:exa_mobile/agent/behaviors/behavior_triggers.dart';
import 'package:exa_mobile/agent/behaviors/token_estimator.dart';
import 'package:exa_mobile/agent/behaviors/trigger_firing_ledger.dart';
import 'package:exa_mobile/agent/evaluation/turn_metrics.dart';
import 'package:exa_mobile/agent/models/agent_execution_report.dart';
import 'package:exa_mobile/agent/models/agent_ids.dart';
import 'package:exa_mobile/agent/models/answer_plan.dart';
import 'package:exa_mobile/agent/models/tool_execution_record.dart';
import 'package:exa_mobile/agent/models/turn_contract.dart';
import 'package:exa_mobile/agent/services/action_lexicon.dart';
import 'package:exa_mobile/agent/services/deterministic_renderer.dart';
import 'package:exa_mobile/agent/behaviors/output_validator.dart';
import 'package:exa_mobile/agent/services/request_decomposition.dart';
import 'package:exa_mobile/agent/services/response_gateway.dart';
import 'package:exa_mobile/agent/services/token_calibration.dart';
import 'package:exa_mobile/agent/tools/tool_failure.dart';
import 'package:exa_mobile/agent/tools/tool_view.dart';
import 'package:exa_mobile/data/database/app_database.dart';
import 'package:exa_mobile/data/models/agent_behavior.dart';
import 'package:exa_mobile/data/repositories/chat_repository.dart';
import 'package:exa_mobile/services/service_circuit_breaker.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

ToolExecutionRecord record({
  required String tool,
  Map<String, Object?> arguments = const {},
  Object? result,
  ToolExecutionStatus status = ToolExecutionStatus.success,
  String? error,
}) =>
    ToolExecutionRecord(
      toolCallId: 'tc_1',
      toolName: tool,
      domain: 'tasks',
      arguments: arguments,
      status: status,
      startedAt: DateTime.now(),
      completedAt: DateTime.now(),
      rawResult: result,
      errorMessage: error,
    );

CompletionContract contract({
  Set<ResponseOutputType> outputs = const {ResponseOutputType.confirmation},
}) =>
    CompletionContract(
      id: AgentId.contract(),
      agentTurnId: 'turn_1',
      originalRequest: 'create a task',
      domains: const {'tasks'},
      actions: const [],
      requiredOutputs: outputs,
      requiresConfirmation: false,
      requiresSynthesis: true,
      requiresVerification: false,
      createdAt: DateTime.now(),
    );

AgentExecutionReport cleanReport({
  List<String> failures = const [],
  List<String> warnings = const [],
}) =>
    AgentExecutionReport(
      originalRequest: 'create a task',
      toolsCalled: const [],
      actionsCompleted: const ['Created task'],
      actionsFailed: failures,
      tasksCreated: const [],
      eventsCreated: const [],
      eventsModified: const [],
      emailDigestItems: const [],
      filesAffected: const [],
      screensCreated: const [],
      rulesChanged: const [],
      warnings: warnings,
      uncertainItems: const [],
      partialFailures: const [],
    );

void main() {
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  group('DeterministicRenderer', () {
    const renderer = DeterministicRenderer();

    test('a single task creation is rendered in code', () {
      final rendered = renderer.render(
        contract: contract(),
        report: cleanReport(),
        records: [
          record(
            tool: 'create_task',
            arguments: const {'title': 'Submit tax documents'},
            result: const {
              'id': 't1',
              'title': 'Submit tax documents',
              'due_at_label': 'Friday, July 31 at 4:00 PM',
            },
          ),
        ],
      );
      expect(rendered, isNotNull);
      expect(rendered!.kind, 'task_created');
      expect(rendered.message, contains('Task created: Submit tax documents'));
      // The label is copied, never recomputed.
      expect(rendered.message, contains('Friday, July 31 at 4:00 PM'));
    });

    test('anything that failed goes to the model instead', () {
      final rendered = renderer.render(
        contract: contract(),
        report: cleanReport(failures: ['Could not reach the mail server']),
        records: [
          record(
            tool: 'create_task',
            result: const {'id': 't1', 'title': 'A task'},
          ),
        ],
      );
      expect(rendered, isNull);
    });

    test('an output code cannot honestly write is left to the model', () {
      final rendered = renderer.render(
        contract: contract(outputs: const {ResponseOutputType.recommendation}),
        report: cleanReport(),
        records: [
          record(
            tool: 'create_task',
            result: const {'id': 't1', 'title': 'A task'},
          ),
        ],
      );
      expect(rendered, isNull);
    });

    test('a denial explains itself without a model call', () {
      final rendered = renderer.render(
        contract: contract(),
        report: cleanReport(),
        records: [
          record(
            tool: 'send_email',
            status: ToolExecutionStatus.denied,
            error: 'Scheduled runs cannot send email.',
          ),
        ],
      );
      expect(rendered, isNotNull);
      expect(rendered!.kind, 'permission_denied');
      expect(rendered.message, contains('cannot send email'));
    });

    test('several of the same clean action are itemized', () {
      final rendered = renderer.render(
        contract: contract(outputs: const {
          ResponseOutputType.confirmation,
          ResponseOutputType.resultList,
        }),
        report: cleanReport(),
        records: [
          record(tool: 'create_task', result: const {'id': 'a', 'title': 'One'}),
          record(tool: 'create_task', result: const {'id': 'b', 'title': 'Two'}),
        ],
      );
      expect(rendered, isNotNull);
      expect(rendered!.message, contains('Tasks created (2)'));
      expect(rendered.message, contains('- One'));
    });

    test('mixed tools are left to the model', () {
      final rendered = renderer.render(
        contract: contract(),
        report: cleanReport(),
        records: [
          record(tool: 'create_task', result: const {'id': 'a', 'title': 'One'}),
          record(
              tool: 'create_reminder',
              result: const {'id': 'b', 'title': 'Two'}),
        ],
      );
      expect(rendered, isNull);
    });
  });

  group('AnswerPlan', () {
    test('renders a structured answer when prose was lost', () {
      final plan = AnswerPlan.fromJson(const {
        'direct_answer': 'Three things need you today.',
        'completed_actions': ['Digested 12 emails'],
        'warnings': ['One deadline had no date'],
        'suggested_next_action': 'Reply to Amy about the report refresh',
      });
      expect(plan, isNotNull);
      final rendered = plan!.render();
      expect(rendered, startsWith('Three things need you today.'));
      expect(rendered, contains('Done:'));
      expect(rendered, contains('- Digested 12 emails'));
      expect(rendered, contains('Next: Reply to Amy'));
    });

    test('an empty plan is null rather than an empty shell', () {
      expect(AnswerPlan.fromJson(const {'direct_answer': ''}), isNull);
    });
  });

  group('ToolView', () {
    const view = ToolView();

    test('a list result is projected to the fields that matter', () {
      final projected = view.project(
        toolName: 'list_tasks',
        arguments: const {},
        payload: const {
          'tasks': [
            {
              'id': 't1',
              'title': 'Submit tax documents',
              'status': 'Pending',
              'due_at_label': 'Friday',
              'description': 'A very long description that the model does '
                  'not need in order to list this task by name.',
              'created_at': '2026-07-01T09:00:00',
              'updated_at': '2026-07-02T09:00:00',
            },
          ],
          'total': 14,
        },
      ) as Map;

      final facts = (projected['tasks'] as List).first as Map;
      expect(facts['title'], 'Submit tax documents');
      expect(facts.containsKey('description'), isFalse);
      expect(facts.containsKey('updated_at'), isFalse);
      expect((projected['page'] as Map)['total'], 14);
      expect(projected['raw_record_refs'], ['t1']);
      expect(projected['summary'], isNotNull);
    });

    test('a completed task keeps the time it was completed', () {
      final projected = view.project(
        toolName: 'list_tasks',
        arguments: const {},
        payload: const {
          'tasks': [
            {
              'id': 't1',
              'title': 'Sent the invoice',
              'status': 'Completed',
              'completed_at': '2026-09-27T15:04:00.000',
              'completed_at_label': 'Sunday, September 27, 2026 at 15:04',
            },
          ],
        },
      ) as Map;
      final facts = (projected['tasks'] as List).single as Map;
      expect(facts['completed_at_label'],
          'Sunday, September 27, 2026 at 15:04');
      expect(facts['completed_at'], '2026-09-27T15:04:00.000');
    });

    test('a schedule keeps the times of its reminders', () {
      // Two lists in one payload. The event fields used to be applied to
      // the reminders, which have none of them, so each reminder reached
      // the model as a title with no time.
      final projected = view.project(
        toolName: 'list_schedule',
        arguments: const {},
        payload: const {
          'count': 1,
          'events': [
            {
              'id': 'e1',
              'title': 'Team B cleaning',
              'start_at': '2026-09-27T13:00:00.000',
              'start_at_label': 'Sunday, September 27, 2026 at 13:00',
              'status': 'Scheduled',
              'description': 'Not needed to list it.',
            },
          ],
          'reminders': [
            {
              'id': 'r1',
              'title': 'Car service',
              'remind_at': '2026-09-27T09:00:00.000',
              'remind_at_label': 'Sunday, September 27, 2026 at 09:00',
            },
          ],
        },
      ) as Map;

      final event = (projected['events'] as List).single as Map;
      expect(event['start_at_label'], 'Sunday, September 27, 2026 at 13:00');
      expect(event.containsKey('description'), isFalse);
      final reminder = (projected['reminders'] as List).single as Map;
      expect(reminder['title'], 'Car service');
      expect(reminder['remind_at_label'],
          'Sunday, September 27, 2026 at 09:00');
    });

    test('a schedule with reminders and no events is left alone', () {
      const payload = {
        'count': 0,
        'events': <Object>[],
        'reminders': [
          {'id': 'r1', 'title': 'Car service', 'remind_at': '2026-09-27T09:00'},
        ],
      };
      final projected = view.project(
        toolName: 'list_schedule',
        arguments: const {},
        payload: payload,
      );
      expect(projected, payload);
    });

    test('a tool whose payload IS the answer is never projected', () {
      const payload = {
        'emails': [
          {'id': 'm1', 'subject': 'Report', 'body': 'The full body text.'},
        ],
      };
      final projected = view.project(
        toolName: 'read_email_context',
        arguments: const {},
        payload: payload,
      ) as Map;
      final email = (projected['emails'] as List).first as Map;
      expect(email['body'], 'The full body text.');
    });

    test('a non-list payload passes through untouched', () {
      const payload = {'id': 't1', 'title': 'Created'};
      expect(
        view.project(
            toolName: 'create_task', arguments: const {}, payload: payload),
        same(payload),
      );
    });
  });

  group('token calibration', () {
    late AppDatabase database;

    setUp(() async {
      database = AppDatabase();
      await database.open(overridePath: inMemoryDatabasePath);
    });

    tearDown(() async => database.close());

    test('a single sample is not enough to move the factor', () async {
      final calibration = TokenCalibration(database);
      await calibration.record(const TokenSample(
        modelIdentifier: 'local-model',
        estimatedInput: 1000,
        actualInput: 1400,
      ));
      expect(await calibration.factorFor('local-model'), 1.0);
    });

    test('a consistent gap is learned and applied', () async {
      final calibration = TokenCalibration(database);
      for (var i = 0; i < 6; i++) {
        await calibration.record(const TokenSample(
          modelIdentifier: 'local-model',
          estimatedInput: 1000,
          actualInput: 1200,
        ));
      }
      final factor = await calibration.factorFor('local-model');
      expect(factor, closeTo(1.2, 0.01));
      expect(await calibration.adjust(500, 'local-model'), 600);
      // Models are tracked separately.
      expect(await calibration.factorFor('claude'), 1.0);
    });

    test('an absurd measurement cannot break the budget', () async {
      final calibration = TokenCalibration(database);
      for (var i = 0; i < 6; i++) {
        await calibration.record(const TokenSample(
          modelIdentifier: 'broken',
          estimatedInput: 10,
          actualInput: 100000,
        ));
      }
      expect(await calibration.factorFor('broken'),
          TokenCalibration.maxFactor);
    });

    test('output reservation scales with what was asked for', () {
      final confirmation = OutputReservation.forResponseBudget(180);
      final rundown = OutputReservation.forResponseBudget(1000);
      expect(rundown, greaterThan(confirmation));

      final available = OutputReservation.availableInput(
        contextWindow: 8000,
        reservedOutput: confirmation,
      );
      // A small confirmation should leave far more input room than the old
      // flat 75% share did.
      expect(available, greaterThan((8000 * 0.75).round()));
    });
  });

  group('behaviour trigger safeguards', () {
    late AppDatabase database;

    setUp(() async {
      database = AppDatabase();
      await database.open(overridePath: inMemoryDatabasePath);
    });

    tearDown(() async => database.close());

    BehaviorTrigger trigger({int maxFiringsPerDay = 8}) => BehaviorTrigger(
          behaviorId: 'b1',
          behaviorTitle: 'Digest new mail',
          event: BehaviorTrigger.eventNewMail,
          action: BehaviorTrigger.actionDigest,
          maxFiringsPerDay: maxFiringsPerDay,
        );

    test('the same event cannot fire the same rule twice', () async {
      final ledger = TriggerFiringLedger(database);
      expect(
        await ledger.claim(trigger: trigger(), eventId: 'sync_42'),
        isNull,
      );
      expect(
        await ledger.claim(trigger: trigger(), eventId: 'sync_42'),
        TriggerRefusal.alreadyFiredForEvent,
      );
      expect(
        await ledger.claim(trigger: trigger(), eventId: 'sync_43'),
        isNull,
      );
    });

    test('the daily cap is enforced across restarts', () async {
      final ledger = TriggerFiringLedger(database);
      for (var i = 0; i < 2; i++) {
        expect(
          await ledger.claim(
              trigger: trigger(maxFiringsPerDay: 2), eventId: 'sync_$i'),
          isNull,
        );
      }
      expect(
        await ledger.claim(
            trigger: trigger(maxFiringsPerDay: 2), eventId: 'sync_9'),
        TriggerRefusal.dailyLimitReached,
      );
      expect(await ledger.firingsToday('b1'), 2);
    });

    test('trigger work cannot fire the trigger that made it', () async {
      final ledger = TriggerFiringLedger(database);
      expect(
        await ledger.claim(
          trigger: trigger(),
          eventId: 'sync_1',
          triggeredByTriggerWork: true,
        ),
        TriggerRefusal.recursiveFiring,
      );
    });

    test('a trigger declares scope and a bounded write surface', () {
      final behavior = AgentBehavior(
        id: 'b1',
        behaviorKey: 'digest',
        title: 'Digest client mail',
        behaviorType: 'automation_rule',
        ruleText: 'digest client mail',
        status: 'Active',
        riskLevel: 'Low Risk',
        params: const {
          'trigger': {
            'on': 'new_mail',
            'action': 'digest',
            'max_firings_per_day': 4,
            'max_records_created_per_firing': 5,
          },
          'scope': {
            'senders': ['project_clients'],
            'exclude_topics': ['newsletter'],
          },
        },
        createdAt: DateTime.now(),
        updatedAt: DateTime.now(),
      );
      final parsed = BehaviorTrigger.fromBehavior(behavior)!;
      expect(parsed.maxFiringsPerDay, 4);
      expect(parsed.allowRecurringTasks, isFalse);
      expect(parsed.scope.admits(sender: 'project_clients@acme.test'), isTrue);
      expect(parsed.scope.admits(sender: 'someone@else.test'), isFalse);
      expect(
        parsed.scope.admits(
            sender: 'project_clients@acme.test',
            text: 'Weekly newsletter roundup'),
        isFalse,
      );

      final scope = parsed.writeScopeJson;
      expect(scope['allowed_effects'], isNot(contains('job.create')));
      expect(scope['allowed_effects'], isNot(contains('task.create_recurring')));
      expect(scope['max_records_per_run'], 5);
    });
  });

  group('service circuit breaker', () {
    late AppDatabase database;

    setUp(() async {
      database = AppDatabase();
      await database.open(overridePath: inMemoryDatabasePath);
    });

    tearDown(() async => database.close());

    test('a blip does not open the circuit', () async {
      final breaker = ServiceCircuitBreaker(database);
      await breaker.recordFailure(ServiceNames.mail);
      expect(await breaker.allows(ServiceNames.mail), isTrue);
    });

    test('repeated failures stop the calls and notify once', () async {
      final breaker = ServiceCircuitBreaker(database);
      for (var i = 0; i < ServiceCircuitBreaker.failureThreshold; i++) {
        await breaker.recordFailure(ServiceNames.mail);
      }
      final status = await breaker.statusOf(ServiceNames.mail);
      expect(status.state, CircuitState.open);
      expect(status.retryAfter, isNotNull);
      expect(await breaker.allows(ServiceNames.mail), isFalse);

      // Told once, not on every two-minute sync tick.
      expect(await breaker.shouldNotify(ServiceNames.mail), isTrue);
      expect(await breaker.shouldNotify(ServiceNames.mail), isFalse);
    });

    test('authentication failures open immediately', () async {
      final breaker = ServiceCircuitBreaker(database);
      final status = await breaker.recordFailure(
        ServiceNames.mail,
        kind: ToolFailureKind.authenticationRequired,
      );
      // A changed password will not fix itself; spending three attempts
      // proving that is pure waste.
      expect(status.state, CircuitState.open);
    });

    test('success resets everything, including the notified flag', () async {
      final breaker = ServiceCircuitBreaker(database);
      for (var i = 0; i < 4; i++) {
        await breaker.recordFailure(ServiceNames.mail);
      }
      await breaker.shouldNotify(ServiceNames.mail);
      await breaker.recordSuccess(ServiceNames.mail);

      final status = await breaker.statusOf(ServiceNames.mail);
      expect(status.state, CircuitState.closed);
      expect(status.consecutiveFailures, 0);
      expect(await breaker.allows(ServiceNames.mail), isTrue);
      expect(await breaker.unhealthy(), isEmpty);

      // A second outage is reported rather than swallowed.
      for (var i = 0; i < 4; i++) {
        await breaker.recordFailure(ServiceNames.mail);
      }
      expect(await breaker.shouldNotify(ServiceNames.mail), isTrue);
    });

    test('accounts fail independently', () async {
      final breaker = ServiceCircuitBreaker(database);
      for (var i = 0; i < 4; i++) {
        await breaker.recordFailure(ServiceNames.mail, accountId: 'a1');
      }
      expect(await breaker.allows(ServiceNames.mail, accountId: 'a1'),
          isFalse);
      expect(await breaker.allows(ServiceNames.mail, accountId: 'a2'), isTrue);
    });
  });

  group('completion metrics', () {
    late AppDatabase database;
    late ChatRepository chat;

    setUp(() async {
      database = AppDatabase();
      await database.open(overridePath: inMemoryDatabasePath);
      chat = ChatRepository(database);
    });

    tearDown(() => database.close());

    Future<void> turn(Map<String, Object?> metrics) =>
        chat.append('assistant', 'ok', meta: {'turn': metrics});

    test('action completion is measured separately from message completion',
        () async {
      // The failure this counter exists for: the message declared every
      // required output, so contract coverage reads perfect, while a third of
      // the work the user asked for has no evidence behind it.
      await turn({
        'required_actions': 2,
        'unresolved_required_actions': 0,
        'missing_outputs_after_repair': <String>[],
      });
      await turn({
        'required_actions': 1,
        'unresolved_required_actions': 1,
        'missing_outputs_after_repair': <String>[],
      });

      final metrics = await TurnMetrics.fromRecentTurns(chat);
      expect(metrics.contractCoverage, 1.0,
          reason: 'both messages were complete');
      expect(metrics.requiredActions, 3);
      expect(metrics.unresolvedRequiredActions, 1);
      expect(metrics.actionCompletionRate, closeTo(2 / 3, 0.001));
    });

    test('a turn with no planned actions counts as fully complete', () async {
      await turn({'missing_outputs_after_repair': <String>[]});
      final metrics = await TurnMetrics.fromRecentTurns(chat);
      expect(metrics.actionCompletionRate, 1.0);
    });

    test('capped turns are counted apart from failures', () async {
      await turn({'turn_capped': true});
      await turn(const {});
      final metrics = await TurnMetrics.fromRecentTurns(chat);
      expect(metrics.cappedTurns, 1);
      expect(metrics.cappedTurnRate, closeTo(0.5, 0.001));
      expect(metrics.verificationFailures, 0,
          reason: 'being cut off short is not the same as answering wrongly');
    });

    test('cache accounting distinguishes a reused prefix from a rewritten '
        'one', () async {
      // Writes without reads is a prefix being rebuilt every turn: it costs
      // 1.25x and returns nothing, and looks identical to caching working
      // from everywhere except this number.
      await turn({'cache_write_tokens': 8000, 'cache_read_tokens': 0});
      await turn({'cache_write_tokens': 8000, 'cache_read_tokens': 0});
      final cold = await TurnMetrics.fromRecentTurns(chat);
      expect(cold.cacheHitRate, 0.0);

      await turn({'cache_write_tokens': 0, 'cache_read_tokens': 32000});
      final warm = await TurnMetrics.fromRecentTurns(chat);
      expect(warm.cacheHitRate, closeTo(2 / 3, 0.001));
    });

    test('exact-tool abandonment is rated against exact-tool turns only',
        () async {
      await turn({'exact_tools_named': 3});
      await turn({'exact_tools_named': 2, 'exact_tool_scope_abandoned': true});
      // A turn that never used exact scoping is not evidence either way.
      await turn(const {});
      final metrics = await TurnMetrics.fromRecentTurns(chat);
      expect(metrics.exactToolTurns, 2);
      expect(metrics.exactToolScopeAbandoned, 1);
      expect(metrics.exactToolAbandonRate, closeTo(0.5, 0.001));
    });
  });

  group('ResponseGateway', () {
    const gateway = ResponseGateway();

    List<OutputConstraint> constraints(Map<String, Object?> params) =>
        OutputConstraint.fromBehavior(AgentBehavior(
          id: 'b1',
          behaviorKey: 'preference_rule:formatting',
          title: 'Formatting',
          behaviorType: 'preference_rule',
          ruleText: 'formatting',
          params: params,
          createdAt: DateTime(2026),
          updatedAt: DateTime(2026),
        ));

    test('fixes what code can fix and reports what it cannot', () {
      final outcome = gateway.apply(
        'Here you go:\n- one\n- two\n- three',
        constraints: constraints({'max_bullets': 2, 'max_words': 3}),
      );
      expect(outcome.text, isNot(contains('three')),
          reason: 'extra bullets are droppable without changing meaning');
      expect(outcome.wasRepairedLocally, isTrue);
      // Truncating prose would change meaning, so max_words stays a failure
      // for the caller to decide about rather than being chopped here.
      expect(outcome.unfixedFailures.map((f) => f.constraint.kind),
          contains('max_words'));
    });

    test('no evidence means no date check, not every date flagged', () {
      // An empty evidence string would report every date as invented, which on
      // a path with nothing to check against is worse than not checking.
      final outcome = gateway.apply('Your review is on March 3, 2026.');
      expect(outcome.unsupportedDates, isEmpty);
      expect(outcome.isClean, isTrue);
    });

    test('a date the evidence does not contain is reported', () {
      final outcome = gateway.apply(
        'Your review is on March 3, 2026.',
        evidence: 'Review scheduled for 2026-04-17.',
      );
      expect(outcome.unsupportedDates, ['2026-03-03']);
      // Reported, never rewritten - the gateway does not guess at the truth.
      expect(outcome.text, contains('March 3, 2026'));
    });

    test('a date that is in the evidence passes, however it is written', () {
      final outcome = gateway.apply(
        'Your review is on March 3, 2026.',
        evidence: 'next_run_at: 2026-03-03T09:00:00',
      );
      expect(outcome.unsupportedDates, isEmpty);
    });

    test('clipping lands on a word boundary', () {
      final outcome = gateway.apply(
        'The quarterly report needs review before the board meeting on Friday',
        maxChars: 30,
      );
      expect(outcome.wasClipped, isTrue);
      expect(outcome.text.length, lessThanOrEqualTo(31));
      expect(outcome.text, endsWith('…'));
      expect(outcome.text, isNot(contains('quarterl ')),
          reason: 'the last thing shown should be a whole word');
    });

    test('blank text passes through untouched', () {
      expect(gateway.apply('  ').text, '  ');
      expect(gateway.apply('').isClean, isTrue);
    });

    test('markdown the app cannot render is stripped', () {
      // Taken from the device: this is what the user's own email digest looked
      // like in a chat bubble, because nothing renders markdown.
      final outcome = gateway.apply(
        '### **Email Digest Rundown**\n'
        '**Processed:** 1 email\n\n'
        '#### **Summary:**\n'
        '- **Subject:** *STG - Email - Information*\n'
        '- ID: `7eb0689e-2148`\n'
        '- See [the portal](https://example.com)\n'
        '---\n'
        '> Note: nothing else pending',
      );
      expect(outcome.text, isNot(contains('#')));
      expect(outcome.text, isNot(contains('**')));
      expect(outcome.text, isNot(contains('`')));
      expect(outcome.text, isNot(contains('---')));
      // The words and the list structure survive.
      expect(outcome.text, contains('Email Digest Rundown'));
      expect(outcome.text, contains('- Subject: STG - Email - Information'));
      expect(outcome.text, contains('ID: 7eb0689e-2148'));
      expect(outcome.text, contains('the portal (https://example.com)'));
      expect(outcome.text, contains('Note: nothing else pending'));
    });

    test('underscores in tool names and placeholders are never touched', () {
      // A regex for `_emphasis_` would turn mark_email_digested into
      // markemaildigested - worse than the bug it would be fixing. This app's
      // text is full of such names.
      const text = 'Called sync_emails then mark_email_digested; the template '
          'uses {{due_at_label}}.';
      expect(gateway.apply(text).text, text);
    });

    test('arithmetic and bare bullets survive the emphasis strip', () {
      final outcome = gateway.apply('Budget is 2 * 3 units\n* first\n* second');
      expect(outcome.text, contains('2 * 3'));
      expect(outcome.text, contains('* first'));
    });

    test('a code fence keeps its contents verbatim', () {
      final outcome = gateway.apply('Run this:\n```\na = b ** 2\n```\nDone.');
      expect(outcome.text, contains('a = b ** 2'),
          reason: 'inside a fence stray punctuation is the content');
      expect(outcome.text, isNot(contains('```')));
    });

    test('a rule requiring JSON suppresses markdown stripping entirely', () {
      // Stripping punctuation out of a JSON document is corruption, not a
      // formatting fix.
      const json = '{"a": "*starred*", "b": "# hash"}';
      final outcome =
          gateway.apply(json, constraints: constraints({'require_json': true}));
      expect(outcome.text, json);
    });

    test('text already within its rules is returned unchanged', () {
      // Idempotence matters: the synthesis path already validated, and the
      // gateway runs again at delivery.
      const text = 'Created your task.';
      final once = gateway.apply(text, constraints: constraints({'max_bullets': 2}));
      final twice = gateway.apply(once.text,
          constraints: constraints({'max_bullets': 2}));
      expect(once.text, text);
      expect(twice.text, text);
      expect(once.wasRepairedLocally, isFalse);
    });
  });

  group('RequestDecomposition', () {
    const tools = {'create_task', 'send_email', 'list_tasks', 'create_reminder'};

    ContractAction action(String description) =>
        ContractAction(id: AgentId.contractAction(), description: description);

    RequestDecomposition analyze(String request, List<String> actions) =>
        RequestDecomposition.analyze(
          request: request,
          actions: [for (final a in actions) action(a)],
          knownToolNames: tools,
        );

    test('a dropped second ask is reported', () {
      // The mirror image of an unresolved action: this work was never planned,
      // so nothing downstream can notice it is missing.
      final result = analyze(
        'Create a task for the invoice and email John about it',
        ['create_task'],
      );
      expect(result.clauses, hasLength(2));
      expect(result.isUnderDecomposed, isTrue);
      expect(result.unaccountedClauses.single, contains('email John'));
    });

    test('a fully decomposed request reports nothing', () {
      final result = analyze(
        'Create a task for the invoice and email John about it',
        ['create_task', 'send_email to John'],
      );
      expect(result.clauses, hasLength(2));
      expect(result.isUnderDecomposed, isFalse);
    });

    test('a single ask can never be under-decomposed', () {
      for (final request in [
        'create a task for the invoice',
        'remind me to call the dentist tomorrow at 9',
        'what is on my schedule today',
      ]) {
        expect(analyze(request, ['create_task']).isUnderDecomposed, isFalse,
            reason: request);
      }
    });

    test('trailing qualifiers are not counted as further asks', () {
      // "and it should be high priority" asks for nothing on its own; counting
      // it would report a shortfall on every elaborated request.
      final result = analyze(
        'Create a task for the invoice and it should be high priority',
        ['create_task'],
      );
      expect(result.clauses, hasLength(1));
      expect(result.isUnderDecomposed, isFalse);
    });

    test('a turn with no planned actions is not reported here', () {
      // Routing produced nothing - already counted as a routing failure, and
      // reporting it again would bury the signal this exists for.
      expect(
        analyze('Create a task and email John', const []).isUnderDecomposed,
        isFalse,
      );
    });

    test('unpunctuated dictated input still splits on the joining words', () {
      // Dictation arrives with no punctuation at all, so sentence splitting
      // does nothing and the conjunctions carry the whole load.
      final result = analyze(
        'create a task for the invoice then email john about it also remind '
        'me tomorrow at 9',
        ['create_task'],
      );
      expect(result.clauses, hasLength(3));
      expect(result.unaccountedClauses, hasLength(2));
    });

    test('the verb vocabulary is shared with action resolution', () {
      // Two private copies of "what counts as a verb" would drift the first
      // time either was tuned.
      expect(ActionLexicon.verbOf('send_email'), 'send');
      expect(ActionLexicon.toolMatches(
          ActionLexicon.tokens('send an email to John'), 'send_email'),
          isTrue);
      expect(ActionLexicon.toolMatches(
          ActionLexicon.tokens('send an email to John'), 'sync_emails'),
          isFalse);
    });
  });

  group('regression limits', () {
    test('the capability catalogue is far cheaper than full schemas', () {
      // Guards the premise of progressive disclosure: if the catalogue ever
      // approaches the schemas it replaces, it has stopped paying for
      // itself.
      const catalogLine = '- create_task: Create a to-do task for the user';
      final catalogTokens = TokenEstimator.estimate(catalogLine) * 46;
      expect(catalogTokens, lessThan(RegressionLimits.maxCatalogTokens));
    });
  });
}
