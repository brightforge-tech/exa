import 'package:exa_mobile/agent/models/agent_execution_report.dart';
import 'package:exa_mobile/agent/models/agent_ids.dart';
import 'package:exa_mobile/agent/models/synthesized_response.dart';
import 'package:exa_mobile/agent/models/turn_contract.dart';
import 'package:exa_mobile/agent/orchestrator/domain_router.dart';
import 'package:exa_mobile/agent/orchestrator/execution_path.dart';
import 'package:exa_mobile/agent/orchestrator/turn_frame.dart';
import 'package:exa_mobile/agent/services/relevance_validator.dart';
import 'package:exa_mobile/agent/services/synthesis_policy.dart';
import 'package:exa_mobile/agent/services/turn_verifier.dart';
import 'package:exa_mobile/agent/tools/tool_domains.dart';
import 'package:flutter_test/flutter_test.dart';

DomainRoutingResult routing({
  Set<String>? domains = const {ToolDomains.tasks},
  List<ContractAction> actions = const [],
  Set<ResponseOutputType> outputs = const {},
  bool requiresConfirmation = false,
  String? risk,
  String? primaryGoal,
}) =>
    DomainRoutingResult(
      domains: domains,
      actions: actions,
      responseOutputs: outputs,
      requiresConfirmation: requiresConfirmation,
      requiresSynthesis: false,
      risk: risk,
      primaryGoal: primaryGoal,
    );

CompletionContract contract({
  List<ContractAction> actions = const [],
  // ignore: unused_element_parameter
  Set<ResponseOutputType> outputs = const {},
  String request = 'Digest my emails',
  List<String> constraints = const [],
  bool requiresSynthesis = true,
}) =>
    CompletionContract(
      id: AgentId.contract(),
      agentTurnId: 'turn_1',
      originalRequest: request,
      domains: const {ToolDomains.email},
      actions: actions,
      requiredOutputs: outputs,
      constraints: constraints,
      requiresConfirmation: false,
      requiresSynthesis: requiresSynthesis,
      requiresVerification: false,
      createdAt: DateTime.now(),
    );

AgentExecutionReport report({
  List<String> completed = const [],
  List<String> failed = const [],
  List<String> warnings = const [],
  List<Map<String, dynamic>> tasksCreated = const [],
}) =>
    AgentExecutionReport(
      originalRequest: 'Digest my emails',
      toolsCalled: const [],
      actionsCompleted: completed,
      actionsFailed: failed,
      tasksCreated: tasksCreated,
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
  group('TurnFrameBuilder', () {
    const builder = TurnFrameBuilder();

    test('uses the router goal when it gives one', () {
      final frame = builder.build(
        userText: 'go through my inbox please',
        routing: routing(primaryGoal: 'Digest new email'),
      );
      expect(frame.primaryGoal, 'Digest new email');
    });

    test('falls back to the request when the router gives no goal', () {
      final frame = builder.build(
        userText: 'Remind me to call the dentist tomorrow. Thanks.',
        routing: routing(),
      );
      expect(frame.primaryGoal, 'Remind me to call the dentist tomorrow');
    });

    test('deterministic risk cannot be lowered by the router', () {
      final frame = builder.build(
        userText: 'delete all my completed tasks',
        routing: routing(risk: 'low'),
      );
      expect(frame.risk, TurnRisk.high);
    });

    test('the router may raise risk above the deterministic read', () {
      final frame = builder.build(
        userText: 'tidy up my list',
        routing: routing(risk: 'high'),
      );
      expect(frame.risk, TurnRisk.high);
    });

    test('parses a time scope and leaves unknown phrasing unscoped', () {
      final now = DateTime(2026, 7, 27, 10);
      final scoped = TurnFrameBuilder.parseTimeScope("what's on today?", now);
      expect(scoped?.label, 'today');
      expect(scoped!.contains(DateTime(2026, 7, 27, 18)), isTrue);
      expect(scoped.contains(DateTime(2026, 7, 28, 9)), isFalse);

      expect(
        TurnFrameBuilder.parseTimeScope('what happened in Q3', now),
        isNull,
      );
    });

    test('a topic shift is detected from content drift', () {
      final first = builder.build(
        userText: 'summarize the invoice project status',
        routing: routing(domains: const {ToolDomains.tasks}),
      );
      final second = builder.build(
        userText: 'when is my dentist appointment',
        routing: routing(domains: const {ToolDomains.calendar}),
        previousTopicTokens: first.topicTokens,
        previousTopicId: first.activeTopicId,
      );
      expect(second.topicShifted, isTrue);

      final sameTopic = builder.build(
        userText: 'and the invoice project deadline?',
        routing: routing(domains: const {ToolDomains.tasks}),
        previousTopicTokens: first.topicTokens,
        previousTopicId: first.activeTopicId,
      );
      expect(sameTopic.topicShifted, isFalse);
    });

    test('a rundown gets a bigger response budget than a confirmation', () {
      final confirmation = builder.build(
        userText: 'mark that done',
        routing: routing(outputs: const {ResponseOutputType.confirmation}),
      );
      final rundown = builder.build(
        userText: 'give me a full rundown of the week',
        routing: routing(outputs: const {
          ResponseOutputType.rundown,
          ResponseOutputType.taskList,
        }),
      );
      expect(rundown.responseTokenBudget,
          greaterThan(confirmation.responseTokenBudget));
    });

    test('evidence is required when the answer is a list of facts', () {
      final frame = builder.build(
        userText: 'list my deadlines',
        routing: routing(outputs: const {ResponseOutputType.deadlineList}),
      );
      expect(frame.evidencePolicy, EvidencePolicy.requireEvidence);
    });

    test('the wider time phrases resolve, and unknown ones still fail open',
        () {
      // Monday 2026-07-27.
      final now = DateTime(2026, 7, 27, 10);
      TimeRange? scope(String text) =>
          TurnFrameBuilder.parseTimeScope(text, now);

      // A weekday must mean the same day here as `upcomingWeekdayMap` gives
      // the action prompt, or "what's on Friday?" gets no filter while the
      // reminder it creates gets the right date.
      expect(scope("what's on friday?")?.label, 'friday');
      expect(scope("what's on friday?")!.contains(DateTime(2026, 7, 31, 9)),
          isTrue);
      expect(scope('anything this weekend?')?.label, 'this weekend');
      expect(scope('anything this weekend?')!.contains(DateTime(2026, 8, 1, 12)),
          isTrue);
      expect(scope('what do I have next month')?.label, 'next month');
      expect(scope('due by end of the month')?.label, 'end of the month');
      expect(scope('remind me in 2 hours')?.label, 'in 2 hours');

      expect(scope('what happened in Q3'), isNull);
      expect(scope('sometime soon'), isNull);
    });
  });

  group('ambiguity detection', () {
    const builder = TurnFrameBuilder();

    List<UnresolvedSlot> slotsFor(
      String text, {
      Set<String>? domains = const {ToolDomains.tasks},
      Set<String> priorEntities = const {'task_1'},
    }) =>
        builder
            .build(
              userText: text,
              routing: routing(domains: domains),
              priorTurnEntityIds: priorEntities,
            )
            .unresolved;

    test('a bare reference with nothing at all in scope is blocking', () {
      final slots = slotsFor('delete it', priorEntities: const {});
      expect(slots.map((s) => s.name), contains('referent'));
      expect(slots.single.blocking, isTrue,
          reason: '"delete" makes this high risk, and there is nothing to '
              'resolve "it" against');
    });

    test('the previous turn\'s entity resolves a bare reference', () {
      // The regression that matters most: "remind me to stretch" then "now
      // cancel it" is about as resolvable as a follow-up gets. The entity
      // graph can be empty (fresh install, or no intelligence layer), so
      // testing it alone would turn this into a question.
      expect(
        slotsFor('now cancel it',
            domains: const {ToolDomains.reminders},
            priorEntities: const {'reminder_284'}),
        isEmpty,
      );
    });

    test('a reminder with no time is always blocking', () {
      final slots = slotsFor('remind me about the dentist',
          domains: const {ToolDomains.reminders});
      final time = slots.firstWhere((s) => s.name == 'time');
      expect(time.blocking, isTrue,
          reason: 'unlike a referent there is no most-likely reading to fall '
              'back on - any time chosen is invented');
    });

    test('a stated time satisfies the slot, in any of its forms', () {
      for (final text in [
        'remind me about the dentist tomorrow at 9am',
        'remind me about the dentist at 15:00',
        'remind me about the dentist on friday',
        'remind me about the dentist in 30 minutes',
        'remind me about the dentist on june 3',
        'remind me about the dentist tonight',
        'set a reminder for the dentist on the 15th',
      ]) {
        expect(
          slotsFor(text, domains: const {ToolDomains.reminders})
              .where((s) => s.name == 'time'),
          isEmpty,
          reason: text,
        );
      }
    });

    test('a question about reminders is not a reminder missing a time', () {
      // Detection must not fire on requests that create nothing.
      expect(
        slotsFor('what reminders do I have',
            domains: const {ToolDomains.reminders}),
        isEmpty,
      );
    });

    test('two time scopes in one request are flagged but not blocking', () {
      final slots = slotsFor('move my meeting tomorrow to next week',
          domains: const {ToolDomains.calendar});
      final scope = slots.firstWhere((s) => s.name == 'time_scope');
      expect(scope.blocking, isFalse,
          reason: 'one of the two is usually the subject and the other '
              'incidental; saying which was used is enough');
      expect(scope.question, contains('tomorrow'));
      expect(scope.question, contains('next week'));
    });

    test('a blocking slot sets askFirst, which the turn acts on', () {
      final frame = builder.build(
        userText: 'delete it',
        routing: routing(),
      );
      expect(frame.hasBlockingAmbiguity, isTrue);
      expect(frame.assumptionPolicy, AssumptionPolicy.askFirst);
    });

    test('an unattended run never asks - it assumes and discloses', () {
      // The outage this prevents: the user's every-30-minutes email digest
      // reads "Sync new emails and Digest them", the pronoun tripped the
      // bare-reference rule, "email" made it high risk, and the job went
      // read-only to ask a question nobody could answer - so sync_emails was
      // refused with awaiting_clarification run after run.
      final frame = builder.build(
        userText: 'delete it',
        routing: routing(),
        unattended: true,
      );
      expect(frame.assumptionPolicy, AssumptionPolicy.assumeAndDisclose);
      expect(frame.hasBlockingAmbiguity, isTrue,
          reason: 'the slot still escalates the turn for closer verification; '
              'only the stop-and-ask is withdrawn');
    });

    test('a pronoun with its own antecedent is not a dangling reference', () {
      // The real instruction from the device. "them" is the emails, named in
      // the same sentence - no previous turn is needed to read it.
      final frame = builder.build(
        userText: 'Sync new emails and Digest them every 30 minutes. '
            'Summarize the emails in point form and create any tasks from the '
            'emails that need creating.',
        routing: routing(domains: const {ToolDomains.email}),
      );
      expect(frame.unresolved.where((s) => s.name == 'referent'), isEmpty);
    });

    test('a request that opens on the pronoun still counts as reaching back',
        () {
      for (final text in ['delete it', 'now cancel it', 'remove those']) {
        final frame = builder.build(userText: text, routing: routing());
        expect(frame.unresolved.where((s) => s.name == 'referent'), isNotEmpty,
            reason: text);
      }
    });
  });

  group('RelevanceValidator', () {
    const validator = RelevanceValidator();

    test('an on-topic answer is clean', () {
      final result = validator.validate(
        response: const SynthesizedResponse(
          message: 'Created the task "Submit tax documents", due Friday.',
          includedOutputs: {ResponseOutputType.confirmation},
        ),
        contract: contract(request: 'create a task to submit tax documents'),
        report: report(
          completed: ['Created task Submit tax documents'],
          tasksCreated: [
            {'id': 't1', 'title': 'Submit tax documents'},
          ],
        ),
      );
      expect(result.isClean, isTrue);
      expect(result.requiresRepair, isFalse);
    });

    test('unrelated background padding is flagged', () {
      final result = validator.validate(
        response: const SynthesizedResponse(
          message: 'Created the task "Submit tax documents".\n\n'
              'Incidentally, the Renaissance began in Florence during the '
              'fourteenth century and spread gradually northwards across '
              'Europe over the following two hundred years.\n\n'
              'Botanists classify tomatoes as berries because they develop '
              'from a single ovary containing many seeds inside fleshy '
              'pericarp tissue.',
          includedOutputs: {ResponseOutputType.confirmation},
        ),
        contract: contract(request: 'create a task to submit tax documents'),
        report: report(
          completed: ['Created task Submit tax documents'],
          tasksCreated: [
            {'id': 't1', 'title': 'Submit tax documents'},
          ],
        ),
      );
      expect(result.unsupported.length, 2);
      expect(result.requiresRepair, isTrue);
    });

    test('warnings and questions are never flagged as off-topic', () {
      final result = validator.validate(
        response: const SynthesizedResponse(
          message: 'Created the task.\n\n'
              'Warning: two of the messages referenced a deadline without '
              'giving an actual date, so nothing was scheduled for them.',
          includedOutputs: {ResponseOutputType.confirmation},
        ),
        contract: contract(request: 'create a task from my email'),
        report: report(completed: ['Created task']),
      );
      expect(result.isClean, isTrue);
    });

    test('a single short line is never flagged', () {
      final result = validator.validate(
        response: const SynthesizedResponse(
          message: 'Done.',
          includedOutputs: {ResponseOutputType.confirmation},
        ),
        contract: contract(request: 'mark the invoice task complete'),
        report: report(completed: ['Completed task Invoice']),
      );
      expect(result.isClean, isTrue);
    });

    test('bulleted lists split into one section per row', () {
      final sections = RelevanceValidator.splitSections(
          'Here is the plan:\n- first item\n- second item\n- third item');
      expect(sections.length, 4);
      expect(sections.first, 'Here is the plan:');
    });
  });

  group('SynthesisPolicy', () {
    const policy = SynthesisPolicy();

    // The orchestrator's fast path skips synthesis when a turn ran no tools
    // and produced its own text. On a real device the model used that path
    // to answer "open the settings screen" with "the Settings screen is now
    // open" - having never called open_screen. Zero tool calls meant no
    // synthesis, which meant no verification, so nothing checked the claim.
    test('a planned action left unresolved still owes a checked answer', () {
      final planned = contract(
        request: 'open the settings screen',
        // Exactly what the router produces for single-step navigation: an
        // action, no required outputs, and no synthesis flag.
        requiresSynthesis: false,
        actions: [
          ContractAction(id: 'a1', description: 'Open the settings screen'),
        ],
      );
      expect(
        policy.requiresSynthesis(
          contract: planned,
          report: report(),
          toolCallCount: 0,
          domainCount: 0,
        ),
        isTrue,
      );
    });

    test('a purely conversational turn keeps the fast path', () {
      expect(
        policy.requiresSynthesis(
          contract: contract(request: 'thanks!', requiresSynthesis: false),
          report: report(),
          toolCallCount: 0,
          domainCount: 0,
        ),
        isFalse,
      );
    });
  });

  group('TurnVerifier: acting versus claiming', () {
    const verifier = TurnVerifier();

    // Observed on a real device: asked to open a screen, the model replied
    // "the jobs screen is now open" and never called open_screen. The
    // action resolver marks unmatched actions completed when a turn has no
    // records at all, so `isResolved` cannot catch it - this can.
    test('a turn that planned actions and ran nothing is flagged', () {
      final result = verifier.verify(
        contract: contract(
          request: 'open the jobs screen',
          actions: [
            ContractAction(id: 'a1', description: "Open the 'jobs screen'"),
          ],
        ),
        report: report(),
        response: const SynthesizedResponse(
          message: 'The jobs screen is now open.',
          includedOutputs: {},
        ),
        records: const [],
      );
      expect(
        result.issues.map((issue) => issue.code),
        contains('action_claimed_without_execution'),
      );
      expect(result.requiresRepair, isTrue);
    });

    test('disclosing it is enough - no repair demanded', () {
      final result = verifier.verify(
        contract: contract(
          request: 'open the jobs screen',
          actions: [
            ContractAction(id: 'a1', description: "Open the 'jobs screen'"),
          ],
        ),
        report: report(),
        response: const SynthesizedResponse(
          message: "I couldn't open that screen.",
          includedOutputs: {},
          includesFailureReport: true,
        ),
        records: const [],
      );
      expect(
        result.issues.map((issue) => issue.code),
        isNot(contains('action_claimed_without_execution')),
      );
    });

    test('a conversational turn is never accused', () {
      // No tool domain routed, so an "action" the router phrased for an
      // explanation must not be treated as unperformed work.
      final conversational = CompletionContract(
        id: AgentId.contract(),
        agentTurnId: 'turn_1',
        originalRequest: 'explain how digests work',
        domains: const {ToolDomains.core},
        actions: [
          ContractAction(id: 'a1', description: 'Explain digests'),
        ],
        requiredOutputs: const {},
        requiresConfirmation: false,
        requiresSynthesis: false,
        requiresVerification: false,
        createdAt: DateTime.now(),
      );
      final result = verifier.verify(
        contract: conversational,
        report: report(),
        response: const SynthesizedResponse(
          message: 'A digest reads new mail and pulls out the actions.',
          includedOutputs: {},
        ),
        records: const [],
      );
      expect(
        result.issues.map((issue) => issue.code),
        isNot(contains('action_claimed_without_execution')),
      );
    });
  });

  group('ExecutionPathPlanner', () {
    const planner = ExecutionPathPlanner();
    const builder = TurnFrameBuilder();

    test('one risk signal alone does not escalate', () {
      final frame = builder.build(
        userText: 'delete the invoice task',
        routing: routing(),
      );
      final decision = planner.decide(
        frame: frame,
        contract: contract(),
        routing: routing(),
      );
      expect(decision.isEscalated, isFalse);
    });

    test('two independent signals escalate', () {
      final frame = builder.build(
        userText: 'delete it',
        routing: null,
      );
      final decision = planner.decide(
        frame: frame,
        contract: contract(),
        routing: null,
      );
      expect(decision.isEscalated, isTrue);
      expect(decision.signals, contains('low_routing_confidence'));
    });

    test('an explicit no-tools route takes the conversational path', () {
      final noTools = routing(domains: const {});
      final frame = builder.build(userText: 'thanks!', routing: noTools);
      final decision = planner.decide(
        frame: frame,
        contract: contract(request: 'thanks!'),
        routing: noTools,
      );
      expect(decision.path, ExecutionPath.conversational);
    });

    test('an absent domain decision never shortcuts', () {
      final allTools = routing(domains: null);
      final frame = builder.build(userText: 'hello', routing: allTools);
      final decision = planner.decide(
        frame: frame,
        contract: contract(request: 'hello'),
        routing: allTools,
      );
      expect(decision.path, isNot(ExecutionPath.conversational));
    });
  });
}
