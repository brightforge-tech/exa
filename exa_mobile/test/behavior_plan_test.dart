import 'package:exa_mobile/agent/behaviors/behavior_plan.dart';
import 'package:exa_mobile/agent/behaviors/output_validator.dart';
import 'package:exa_mobile/agent/behaviors/token_estimator.dart';
import 'package:exa_mobile/agent/tools/tool_domains.dart';
import 'package:exa_mobile/data/models/agent_behavior.dart';
import 'package:flutter_test/flutter_test.dart';

/// Phase-specific resolution, deterministic conflict handling, token
/// budgets, and the code-enforced rules that never reach a prompt.
void main() {
  AgentBehavior rule(
    String type,
    String text, {
    int priority = 100,
    String source = 'explicit',
    String? conflictGroup,
    String? scopeIntent,
    String enforcementMode = 'advisory',
    double confidence = 1.0,
    Map<String, Object?> params = const {},
    DateTime? expiresAt,
    DateTime? confirmedAt,
    String? id,
  }) {
    final now = DateTime(2026, 7, 27);
    return AgentBehavior(
      id: id ?? '$type:$text',
      behaviorKey: '$type:$text',
      title: text,
      behaviorType: type,
      ruleText: text,
      priority: priority,
      status: 'Active',
      source: source,
      conflictGroup: conflictGroup,
      scopeIntent: scopeIntent,
      enforcementMode: enforcementMode,
      confidence: confidence,
      params: params,
      expiresAt: expiresAt,
      lastConfirmedAt: confirmedAt,
      createdAt: now,
      updatedAt: now,
    );
  }

  group('phase separation', () {
    test('writing rules reach the writer, not the planner', () {
      final plan = BehaviorPlan.compile([
        rule('summary_rule', 'Lead with meetings'),
      ]);
      expect(plan.synthesisBlock, contains('Lead with meetings'));
      expect(plan.plannerBlock, isNot(contains('Lead with meetings')));
      expect(plan.actionBlock, isNot(contains('Lead with meetings')));
    });

    test('tool and decision rules reach the planner, not the writer', () {
      final plan = BehaviorPlan.compile(
        [rule('email_review_rule', 'Flag invoices from suppliers')],
        domains: {ToolDomains.email},
      );
      expect(plan.plannerBlock, contains('Flag invoices'));
      expect(plan.actionBlock, contains('Flag invoices'));
      expect(plan.synthesisBlock, isNot(contains('Flag invoices')));
    });

    test('repair gets only safety rules, not the whole rule set', () {
      final plan = BehaviorPlan.compile([
        rule('preference_rule', 'Be warm and chatty'),
        rule('safety_rule', 'Never invent a completed action'),
      ]);
      expect(plan.repairBlock, contains('Never invent'));
      expect(plan.repairBlock, isNot(contains('warm and chatty')));
    });

    test('safety rules appear in every phase', () {
      final plan = BehaviorPlan.compile([
        rule('safety_rule', 'Never send money'),
      ]);
      for (final phase in AgentPhase.values) {
        expect(plan.blockFor(phase), contains('Never send money'),
            reason: phase.name);
      }
    });

    test('the unattended banner goes to the acting phases only', () {
      final plan =
          BehaviorPlan.compile([rule('preference_rule', 'Be brief')],
              unattended: true);
      expect(plan.plannerBlock, contains('running unattended'));
      expect(plan.actionBlock, contains('running unattended'));
      expect(plan.synthesisBlock, isNot(contains('running unattended')));
    });
  });

  group('code-enforced rules', () {
    test('are kept out of every prompt but still drive the app', () {
      final plan = BehaviorPlan.compile([
        rule('notification_rule', 'No alerts after 22:00',
            enforcementMode: 'code_enforced',
            params: {
              'quiet_hours': {'from': '22:00', 'to': '07:00'},
            }),
        rule('schedule_rule', 'Meetings are 30 minutes',
            enforcementMode: 'code_enforced',
            params: {'default_duration_minutes': 30}),
      ]);

      for (final phase in AgentPhase.values) {
        expect(plan.blockFor(phase), isNot(contains('22:00')),
            reason: phase.name);
      }
      // ...but the deterministic consumers still get them.
      expect(plan.notificationPolicy.hasQuietHours, isTrue);
      expect(plan.scheduleDefaults.durationMinutes, 30);
      expect(
        plan.trace.excluded.map((d) => d.reason),
        contains(contains('enforced in code')),
      );
    });
  });

  group('conflict resolution', () {
    test('one winner per conflict group, deterministically', () {
      final specific = rule('summary_rule', 'Keep status updates to 3 lines',
          conflictGroup: 'response_shape', scopeIntent: 'status updates');
      final general = rule('summary_rule', 'Always explain in detail',
          conflictGroup: 'response_shape', priority: 1);

      // Same inputs in either order resolve the same way.
      for (final input in [
        [specific, general],
        [general, specific]
      ]) {
        final plan = BehaviorPlan.compile(input);
        expect(plan.synthesisBlock, contains('3 lines'));
        expect(plan.synthesisBlock, isNot(contains('explain in detail')));
      }
    });

    test('explicit beats inferred', () {
      final plan = BehaviorPlan.compile([
        rule('summary_rule', 'Inferred: be terse',
            source: 'inferred', conflictGroup: 'response_shape'),
        rule('summary_rule', 'Explicit: be thorough',
            source: 'explicit', conflictGroup: 'response_shape'),
      ]);
      expect(plan.synthesisBlock, contains('Explicit'));
      expect(plan.synthesisBlock, isNot(contains('Inferred')));
    });

    test('the loser is recorded with a reason', () {
      final plan = BehaviorPlan.compile([
        rule('summary_rule', 'Winner',
            source: 'explicit', conflictGroup: 'response_shape'),
        rule('summary_rule', 'Loser',
            source: 'inferred', conflictGroup: 'response_shape'),
      ]);
      final excluded =
          plan.trace.excluded.firstWhere((d) => d.title == 'Loser');
      expect(excluded.reason, contains('lost conflict'));
      expect(excluded.conflictGroup, 'response_shape');
      expect(plan.trace.toJson()['excluded'], isNotEmpty);
    });

    test('a user rule cannot displace a system safety rule', () {
      final plan = BehaviorPlan.compile([
        AgentBehavior(
          id: 'sys',
          behaviorKey: 'sys',
          title: 'System',
          behaviorType: 'safety_rule',
          ruleText: 'Never send email without approval',
          source: 'system',
          conflictGroup: 'sending',
          status: 'Active',
          createdAt: DateTime(2026),
          updatedAt: DateTime(2026),
        ),
        rule('safety_rule', 'Just send things without asking',
            conflictGroup: 'sending', scopeIntent: 'email'),
      ]);
      expect(plan.actionBlock, contains('without approval'));
      expect(plan.trace.warnings, isNotEmpty);
    });
  });

  group('governance', () {
    test('expired rules do not apply', () {
      final plan = BehaviorPlan.compile([
        rule('preference_rule', 'Only for the Rowan project',
            expiresAt: DateTime(2026, 7, 1)),
      ], now: DateTime(2026, 7, 27));
      expect(plan.actionBlock, isEmpty);
      expect(plan.trace.excluded.single.reason, 'expired');
    });

    test('duplicate rules collapse so safety rules cannot grow unbounded',
        () {
      final plan = BehaviorPlan.compile([
        rule('safety_rule', 'Never send email without asking.', id: 'a'),
        rule('safety_rule', 'never send email without asking', id: 'b'),
        rule('safety_rule', 'Never send email without asking!', id: 'c'),
      ]);
      expect('Never send email'.allMatches(plan.actionBlock).length, 1);
      expect(plan.trace.excluded.where((d) => d.reason.contains('duplicate')),
          hasLength(2));
    });

    test('an unknown rule type fails closed and is reported', () {
      final plan = BehaviorPlan.compile([
        rule('mystery_rule', 'Do something undefined'),
      ]);
      for (final phase in AgentPhase.values) {
        expect(plan.blockFor(phase), isEmpty, reason: phase.name);
      }
      expect(plan.trace.warnings.single, contains('unsupported type'));
    });
  });

  group('token budget', () {
    test('a long rule list is trimmed to the phase budget', () {
      final many = [
        for (var i = 0; i < 40; i++)
          rule('preference_rule',
              'Rule number $i with enough words to cost real tokens '
                  'when rendered into the prompt',
              priority: i, id: 'rule-$i'),
      ];
      final plan = BehaviorPlan.compile(many);
      final used = TokenEstimator.estimate(plan.actionBlock);
      expect(
          used,
          lessThanOrEqualTo(
              BehaviorTokenBudget.forPhase(AgentPhase.action).maxTokens +
                  20));
      expect(plan.trace.excluded.map((d) => d.reason),
          contains(contains('token budget')));
    });

    test('a small context window gets a smaller budget', () {
      final big = BehaviorTokenBudget.forPhase(AgentPhase.action).maxTokens;
      final small =
          BehaviorTokenBudget.forPhase(AgentPhase.action, contextWindow: 4096)
              .maxTokens;
      expect(small, lessThan(big));
      expect(small, greaterThan(0));
    });

    test('mandatory rules survive a full budget', () {
      final many = [
        for (var i = 0; i < 40; i++)
          rule('preference_rule', 'Filler rule $i with plenty of words '
              'to consume the budget entirely', priority: i, id: 'f$i'),
        rule('safety_rule', 'Never delete without asking',
            priority: 999, id: 'safety'),
      ];
      final plan = BehaviorPlan.compile(many);
      expect(plan.actionBlock, contains('Never delete without asking'));
    });

    test('estimates track length and never return zero for real text', () {
      expect(TokenEstimator.estimate(''), 0);
      expect(TokenEstimator.estimate('hello'), greaterThan(0));
      expect(TokenEstimator.estimate('a much longer sentence with words'),
          greaterThan(TokenEstimator.estimate('short')));
    });
  });

  group('output constraints', () {
    const validator = OutputValidator();

    List<OutputConstraint> constraintsFor(Map<String, Object?> params) =>
        OutputConstraint.fromBehavior(
            rule('summary_rule', 'shape', params: params));

    test('extra bullets are trimmed in code, without a repair call', () {
      final result = validator.validate(
        '- one\n- two\n- three\n- four',
        constraintsFor({'max_bullets': 2}),
      );
      expect(result.isValid, isTrue);
      expect(result.wasRepairedLocally, isTrue);
      expect(result.repairedText, '- one\n- two');
    });

    test('markdown tables are stripped in code', () {
      final result = validator.validate(
        'Here is the data:\n| a | b |\n| 1 | 2 |\nThat is all.',
        constraintsFor({'no_markdown_tables': true}),
      );
      expect(result.isValid, isTrue);
      expect(result.repairedText, isNot(contains('|')));
      expect(result.repairedText, contains('That is all.'));
    });

    test('a word limit is a real failure - truncating would change meaning',
        () {
      final result = validator.validate(
        List.filled(60, 'word').join(' '),
        constraintsFor({'max_words': 20}),
      );
      expect(result.isValid, isFalse);
      expect(result.failures.single.toString(), contains('at most 20 words'));
      expect(result.wasRepairedLocally, isFalse);
    });

    test('JSON is extracted from surrounding prose', () {
      final result = validator.validate(
        'Sure! {"ok": true} hope that helps',
        constraintsFor({'require_json': true}),
      );
      expect(result.isValid, isTrue);
      expect(result.repairedText, '{"ok": true}');
    });

    test('a compliant response is left untouched', () {
      final result = validator.validate(
        '- one\n- two',
        constraintsFor({'max_bullets': 2}),
      );
      expect(result.isValid, isTrue);
      expect(result.wasRepairedLocally, isFalse);
    });

    test('constraints are collected from the plan', () {
      final plan = BehaviorPlan.compile([
        rule('summary_rule', 'Two bullets max',
            enforcementMode: 'output_validated',
            params: {'max_bullets': 2}),
      ]);
      expect(plan.validators, hasLength(1));
      expect(plan.validators.single.kind, 'max_bullets');
    });
  });
}
