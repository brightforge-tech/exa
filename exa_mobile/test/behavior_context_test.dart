import 'package:exa_mobile/agent/behaviors/behavior_context.dart';
import 'package:exa_mobile/agent/behaviors/notification_policy.dart';
import 'package:exa_mobile/agent/behaviors/schedule_defaults.dart';
import 'package:exa_mobile/agent/prompts/system_prompt.dart';
import 'package:exa_mobile/agent/tools/tool_domains.dart';
import 'package:exa_mobile/data/models/agent_behavior.dart';
import 'package:flutter_test/flutter_test.dart';

/// The shared behavior layer: which rules reach a given piece of work, how
/// they render into a prompt, and the typed rules that are enforced in code
/// rather than read as text.
void main() {
  AgentBehavior rule(
    String type,
    String text, {
    int priority = 100,
    Map<String, Object?> params = const {},
  }) {
    final now = DateTime(2026, 7, 27);
    return AgentBehavior(
      id: '$type-$text',
      behaviorKey: '$type-$text',
      title: text,
      behaviorType: type,
      ruleText: text,
      priority: priority,
      status: 'Active',
      params: params,
      createdAt: now,
      updatedAt: now,
    );
  }

  group('filtering', () {
    test('global rules reach every surface and domain', () {
      final context = BehaviorContext.fromBehaviors(
        [
          rule('preference_rule', 'Be brief'),
          rule('workflow_rule', 'Check email first'),
        ],
        surface: BehaviorSurface.notification,
        domains: {ToolDomains.tasks},
      );
      expect(context.behaviors, hasLength(2));
    });

    test('a typed rule only reaches turns touching its domain', () {
      final rules = [rule('email_review_rule', 'Flag invoices')];

      final onEmail = BehaviorContext.fromBehaviors(rules,
          domains: {ToolDomains.email});
      expect(onEmail.behaviors, hasLength(1));

      final onTasks = BehaviorContext.fromBehaviors(rules,
          domains: {ToolDomains.tasks});
      expect(onTasks.isEmpty, isTrue);
    });

    test('no routing information keeps every rule', () {
      final context = BehaviorContext.fromBehaviors(
        [rule('email_review_rule', 'Flag invoices')],
      );
      expect(context.behaviors, hasLength(1));
    });

    test('summary rules follow the surface, not a domain', () {
      final rules = [rule('summary_rule', 'Lead with meetings')];

      expect(
        BehaviorContext.fromBehaviors(rules,
                surface: BehaviorSurface.finalResponse,
                domains: {ToolDomains.tasks})
            .behaviors,
        hasLength(1),
      );
      expect(
        BehaviorContext.fromBehaviors(rules,
                surface: BehaviorSurface.chat, domains: {ToolDomains.tasks})
            .isEmpty,
        isTrue,
      );
    });

    test('safety rules survive every filter, including onlyTypes', () {
      final context = BehaviorContext.fromBehaviors(
        [
          rule('safety_rule', 'Never send email unprompted'),
          rule('email_review_rule', 'Flag invoices'),
        ],
        surface: BehaviorSurface.notification,
        domains: {ToolDomains.tasks},
        onlyTypes: const {'summary_rule'},
      );
      expect(context.behaviors, hasLength(1));
      expect(context.behaviors.single.behaviorType, 'safety_rule');
    });

    test('the cap drops the lowest-priority rules, keeping the rest', () {
      final many = [
        for (var i = 0; i < BehaviorContext.maxRules + 3; i++)
          rule('preference_rule', 'Rule $i', priority: i),
      ];
      final context = BehaviorContext.fromBehaviors(many);
      expect(context.behaviors, hasLength(BehaviorContext.maxRules));
      expect(context.droppedCount, 3);
      // Input arrives in priority order, so the survivors are the first ones.
      expect(context.behaviors.first.ruleText, 'Rule 0');
      expect(context.behaviors.last.ruleText,
          'Rule ${BehaviorContext.maxRules - 1}');
    });

    test('one oversized rule is still kept rather than dropping everything',
        () {
      final context = BehaviorContext.fromBehaviors(
        [rule('preference_rule', 'x' * (BehaviorContext.maxChars * 2))],
      );
      expect(context.behaviors, hasLength(1));
    });
  });

  group('rendering', () {
    test('renders each rule with its type', () {
      final block = BehaviorContext.fromBehaviors(
        [rule('preference_rule', 'Be brief')],
      ).render();
      expect(block, contains('- [preference_rule] Be brief'));
    });

    test('empty context renders nothing', () {
      expect(const BehaviorContext.empty().render(), isEmpty);
    });

    test('unattended runs are told no user is present', () {
      final block = BehaviorContext.fromBehaviors(
        [rule('preference_rule', 'Be brief')],
        unattended: true,
      ).render();
      expect(block, contains('Be brief'));
      expect(block, contains('running unattended'));

      final attended = BehaviorContext.fromBehaviors(
        [rule('preference_rule', 'Be brief')],
      ).render();
      expect(attended, isNot(contains('running unattended')));
    });

    test('an unattended run with no rules still gets the banner', () {
      final block =
          BehaviorContext.fromBehaviors(const [], unattended: true).render();
      expect(block, contains('running unattended'));
    });

    test('the system prompt carries the rules', () {
      final prompt = buildSystemPrompt(
        behaviors: BehaviorContext.fromBehaviors(
          [rule('preference_rule', 'Always answer in two bullets')],
        ).render(),
      );
      expect(prompt, contains('Always answer in two bullets'));
    });

    test('forSurface narrows without another load', () {
      final turn = BehaviorContext.fromBehaviors(
        [
          rule('preference_rule', 'Be brief'),
          rule('task_prioritization_rule', 'Urgent first'),
        ],
        domains: {ToolDomains.tasks},
      );
      expect(turn.behaviors, hasLength(2));

      final forWriting = turn.forSurface(BehaviorSurface.finalResponse,
          onlyTypes: BehaviorContext.styleTypes);
      expect(forWriting.behaviors, hasLength(1));
      expect(forWriting.behaviors.single.ruleText, 'Be brief');
    });
  });

  group('notification policy', () {
    NotificationPolicy policyFor(Map<String, Object?> quietHours) =>
        NotificationPolicy.fromBehaviors(
            [rule('notification_rule', 'Quiet please', params: {
              'quiet_hours': quietHours,
            })]);

    test('no rules means nothing is quiet', () {
      expect(NotificationPolicy.fromBehaviors(const []).hasQuietHours,
          isFalse);
      expect(NotificationPolicy.none.isQuiet(DateTime(2026, 7, 27, 3)),
          isFalse);
    });

    test('a window across midnight covers both sides', () {
      final policy = policyFor({'from': '22:00', 'to': '07:00'});
      expect(policy.isQuiet(DateTime(2026, 7, 27, 23, 30)), isTrue);
      expect(policy.isQuiet(DateTime(2026, 7, 27, 3)), isTrue);
      expect(policy.isQuiet(DateTime(2026, 7, 27, 12)), isFalse);
      expect(policy.isQuiet(DateTime(2026, 7, 27, 7)), isFalse);
    });

    test('a same-day window covers only that span', () {
      final policy = policyFor({'from': '09:00', 'to': '17:00'});
      expect(policy.isQuiet(DateTime(2026, 7, 27, 12)), isTrue);
      expect(policy.isQuiet(DateTime(2026, 7, 27, 20)), isFalse);
    });

    test('nextAudibleTime rolls to the end of the window', () {
      final policy = policyFor({'from': '22:00', 'to': '07:00'});
      expect(
        policy.nextAudibleTime(DateTime(2026, 7, 27, 23, 30)),
        DateTime(2026, 7, 28, 7),
      );
      expect(
        policy.nextAudibleTime(DateTime(2026, 7, 27, 3)),
        DateTime(2026, 7, 27, 7),
      );
      // Outside the window it is a no-op.
      final noon = DateTime(2026, 7, 27, 12);
      expect(policy.nextAudibleTime(noon), noon);
    });

    test('timed alerts are only deferred when the rule opts in', () {
      expect(policyFor({'from': '22:00', 'to': '07:00'}).includeTimedAlerts,
          isFalse);
      expect(
        policyFor({
          'from': '22:00',
          'to': '07:00',
          'include_timed_alerts': true,
        }).includeTimedAlerts,
        isTrue,
      );
    });

    test('unparseable or empty windows are ignored', () {
      expect(policyFor({'from': 'nonsense', 'to': '07:00'}).hasQuietHours,
          isFalse);
      expect(policyFor({'from': '22:00', 'to': '22:00'}).hasQuietHours,
          isFalse);
      expect(
          NotificationPolicy.fromBehaviors(
                  [rule('notification_rule', 'No params')]).hasQuietHours,
          isFalse);
    });
  });

  group('schedule defaults', () {
    test('reads lead time and duration from the rule', () {
      final defaults = ScheduleDefaults.fromBehaviors([
        rule('schedule_rule', 'Short meetings', params: {
          'default_lead_minutes': 15,
          'default_duration_minutes': 30,
        }),
      ]);
      expect(defaults.leadMinutes, 15);
      expect(defaults.durationMinutes, 30);
    });

    test('the highest-priority rule wins per field', () {
      final defaults = ScheduleDefaults.fromBehaviors([
        rule('schedule_rule', 'First',
            priority: 1, params: {'default_lead_minutes': 5}),
        rule('schedule_rule', 'Second', priority: 2, params: {
          'default_lead_minutes': 30,
          'default_duration_minutes': 45,
        }),
      ]);
      expect(defaults.leadMinutes, 5);
      // Not set by the higher-priority rule, so the next one supplies it.
      expect(defaults.durationMinutes, 45);
    });

    test('nonsense values are ignored', () {
      final defaults = ScheduleDefaults.fromBehaviors([
        rule('schedule_rule', 'Bad', params: {
          'default_lead_minutes': -5,
          'default_duration_minutes': 'soon',
        }),
      ]);
      expect(defaults.isEmpty, isTrue);
    });
  });

  group('params storage', () {
    test('round-trips through a row', () {
      final original = rule('notification_rule', 'Quiet', params: {
        'quiet_hours': {'from': '22:00', 'to': '07:00'},
      });
      final restored = AgentBehavior.fromRow(original.toRow());
      expect((restored.params['quiet_hours'] as Map)['from'], '22:00');
    });

    test('a rule with no params reads back empty, not null', () {
      final restored =
          AgentBehavior.fromRow(rule('preference_rule', 'Be brief').toRow());
      expect(restored.params, isEmpty);
    });

    test('corrupt params degrade to empty instead of throwing', () {
      expect(AgentBehavior.parseParams('{not json'), isEmpty);
      expect(AgentBehavior.parseParams('[1,2,3]'), isEmpty);
      expect(AgentBehavior.parseParams(null), isEmpty);
    });
  });
}
