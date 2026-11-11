import '../models/agent_ids.dart';
import '../models/turn_contract.dart';
import '../tools/tool_domains.dart';
import 'models/workflow_skill.dart';
import 'workflow_skill_repository.dart';

/// Seeds and maintains the built-in system skills. Seeding is idempotent:
/// a (name, version) that already exists is never rewritten - skill
/// versions referenced by historical traces stay immutable.
class SkillRegistry {
  SkillRegistry(this._repository);

  final WorkflowSkillRepository _repository;

  Future<void> seedSystemSkills() async {
    for (final skill in _systemSkills()) {
      final existing =
          await _repository.getByNameVersion(skill.name, skill.version);
      if (existing == null) {
        await _repository.insert(skill);
      }
    }
  }

  List<WorkflowSkill> _systemSkills() {
    final now = DateTime.now();

    return [
      // Email digestion needs language understanding to pull tasks and
      // meetings out of message bodies, so it runs guided: the recipe and
      // required outputs are fixed, the model performs the steps.
      WorkflowSkill(
        id: AgentId.skill(),
        name: 'digest_emails',
        description: 'Review new emails, extract tasks, meetings, and '
            'deadlines into the right tools, mark the emails digested, and '
            'give the user a concise rundown.',
        version: 1,
        mode: SkillExecutionMode.guided,
        requiredDomains: {
          ToolDomains.email,
          ToolDomains.tasks,
          ToolDomains.calendar,
        },
        requiredOutputs: const {
          ResponseOutputType.rundown,
          ResponseOutputType.taskList,
          ResponseOutputType.meetingList,
          ResponseOutputType.deadlineList,
          ResponseOutputType.attentionItems,
        },
        triggerExamples: const [
          'digest my emails',
          'digest my inbox',
          'go through my emails',
          'process my new emails',
          'review my emails and pull out tasks',
          'check my email and give me a rundown',
        ],
        steps: [
          const SkillStep(
            id: 'sync',
            name: 'Sync email',
            toolName: 'sync_emails',
            failurePolicy: SkillStepFailurePolicy.continueAndReport,
          ),
          const SkillStep(
            id: 'read',
            name: 'Read undigested email context',
            toolName: 'read_email_context',
            argumentTemplate: {'undigested_only': true},
            dependsOn: ['sync'],
            failurePolicy: SkillStepFailurePolicy.stop,
          ),
          const SkillStep(
            id: 'create_tasks',
            name: 'Create tasks from actionable emails',
            toolName: 'create_task',
            dependsOn: ['read'],
            condition: 'read.count > 0',
            failurePolicy: SkillStepFailurePolicy.continueAndReport,
          ),
          const SkillStep(
            id: 'create_events',
            name: 'Add confirmed meetings to the schedule',
            toolName: 'create_schedule_event',
            dependsOn: ['read'],
            condition: 'read.count > 0',
            failurePolicy: SkillStepFailurePolicy.continueAndReport,
            isOptional: true,
          ),
          const SkillStep(
            id: 'mark_digested',
            name: 'Mark processed emails digested',
            toolName: 'mark_email_digested',
            dependsOn: ['read'],
            condition: 'read.count > 0',
            failurePolicy: SkillStepFailurePolicy.continueAndReport,
          ),
        ],
        createdAt: now,
        updatedAt: now,
      ),

      // The scheduled daily review. Guided, like digest_emails, because the
      // email half needs language understanding - but its recipe goes on to
      // look at the day itself. It exists because the review used to run as
      // digest_emails: that recipe ends at "mark digested", and the router's
      // exact tool list never included list_schedule / list_tasks /
      // list_reminders, so "review today's schedule, open tasks and
      // reminders" was asked of a model that could not call anything to do
      // it. The orchestrator offers a guided skill's recipe tools even when
      // the router's list omits them, so every step here is callable.
      WorkflowSkill(
        id: AgentId.skill(),
        name: 'daily_review',
        description: 'Go through new email (tasks, meetings and deadlines '
            'into the right tools, emails marked handled), then look at '
            "today's schedule, open tasks and upcoming reminders, and give "
            'the user a short rundown with anything that needs attention.',
        version: 1,
        mode: SkillExecutionMode.guided,
        requiredDomains: {
          ToolDomains.email,
          ToolDomains.tasks,
          ToolDomains.calendar,
          ToolDomains.reminders,
        },
        requiredOutputs: const {
          ResponseOutputType.rundown,
          ResponseOutputType.taskList,
          ResponseOutputType.meetingList,
          ResponseOutputType.deadlineList,
          ResponseOutputType.attentionItems,
        },
        // "daily review" is the phrase the scheduled job uses; none of these
        // contain a digest_emails or prepare_daily_briefing trigger, so the
        // matcher cannot hand the turn to either of those instead.
        triggerExamples: const [
          'daily review',
          'run my daily review',
          'give me my daily review',
          'review my day',
          'morning review',
          'what needs my attention today',
        ],
        steps: [
          const SkillStep(
            id: 'sync',
            name: 'Sync email',
            toolName: 'sync_emails',
            failurePolicy: SkillStepFailurePolicy.continueAndReport,
          ),
          const SkillStep(
            id: 'read',
            name: 'Read new email',
            toolName: 'read_email_context',
            argumentTemplate: {'undigested_only': true},
            dependsOn: ['sync'],
            // Unlike digest_emails, mail trouble must not stop the review
            // of the day itself.
            failurePolicy: SkillStepFailurePolicy.continueAndReport,
          ),
          const SkillStep(
            id: 'create_tasks',
            name: 'Create tasks from actionable emails',
            toolName: 'create_task',
            dependsOn: ['read'],
            condition: 'read.count > 0',
            failurePolicy: SkillStepFailurePolicy.continueAndReport,
          ),
          const SkillStep(
            id: 'create_events',
            name: 'Add confirmed meetings to the schedule',
            toolName: 'create_schedule_event',
            dependsOn: ['read'],
            condition: 'read.count > 0',
            failurePolicy: SkillStepFailurePolicy.continueAndReport,
            isOptional: true,
          ),
          const SkillStep(
            id: 'mark_digested',
            name: 'Mark processed emails digested',
            toolName: 'mark_email_digested',
            dependsOn: ['read'],
            condition: 'read.count > 0',
            failurePolicy: SkillStepFailurePolicy.continueAndReport,
          ),
          const SkillStep(
            id: 'schedule',
            name: "Look at today's schedule",
            toolName: 'list_schedule',
            failurePolicy: SkillStepFailurePolicy.continueAndReport,
          ),
          const SkillStep(
            id: 'tasks',
            name: 'List open and overdue tasks',
            toolName: 'list_tasks',
            argumentTemplate: {'open_only': true},
            failurePolicy: SkillStepFailurePolicy.continueAndReport,
          ),
          const SkillStep(
            id: 'reminders',
            name: 'List upcoming reminders',
            toolName: 'list_reminders',
            argumentTemplate: {'status': 'Active'},
            failurePolicy: SkillStepFailurePolicy.continueAndReport,
          ),
        ],
        createdAt: now,
        updatedAt: now,
      ),

      // Screen-snippet analysis (overlay bubble). Guided: only the model can
      // see the image, so the recipe fixes what a snippet turn must produce -
      // a grounded summary AND exactly one proactive follow-up question - and
      // the contract/verifier enforce both. The lone tool step persists the
      // snippet so later turns ("remind me about that") can reference it via
      // the entity graph.
      WorkflowSkill(
        id: AgentId.skill(),
        name: 'analyze_snippet',
        description: 'Analyze a screenshot snippet the user captured with '
            'the floating bubble: describe concretely what it shows, extract '
            'the concrete entities in it (dates, times, people, places, '
            'flight numbers, amounts, order numbers), store the snippet '
            'image, and end with one specific follow-up question offering '
            'the most useful next action (e.g. a reminder, task, or '
            'calendar event based on what the snippet shows). Never create '
            'tasks, reminders, or events from a snippet unsolicited - offer '
            'first, act when the user agrees.',
        version: 1,
        mode: SkillExecutionMode.guided,
        requiredDomains: {
          ToolDomains.files,
          ToolDomains.tasks,
          ToolDomains.reminders,
          ToolDomains.calendar,
        },
        requiredOutputs: const {
          ResponseOutputType.summary,
          ResponseOutputType.followUpQuestion,
        },
        triggerExamples: const [
          'analyze this screenshot snippet i captured from my screen',
          'analyze this snippet',
          'analyze this screenshot',
          'what is in this screenshot',
          'look at what i captured',
        ],
        steps: [
          const SkillStep(
            id: 'store',
            name: 'Store the snippet image',
            toolName: 'store_file',
            failurePolicy: SkillStepFailurePolicy.continueAndReport,
          ),
        ],
        createdAt: now,
        updatedAt: now,
      ),

      // Fully deterministic: gather today's calendar, open tasks, and
      // active reminders; synthesis then writes the briefing.
      WorkflowSkill(
        id: AgentId.skill(),
        name: 'prepare_daily_briefing',
        description: "Collect today's schedule, open tasks, and active "
            'reminders, and brief the user with a prioritized plan for '
            'the day.',
        version: 1,
        mode: SkillExecutionMode.deterministic,
        requiredDomains: {
          ToolDomains.calendar,
          ToolDomains.tasks,
          ToolDomains.reminders,
        },
        requiredOutputs: const {
          ResponseOutputType.summary,
          ResponseOutputType.priorityPlan,
          ResponseOutputType.deadlineList,
          ResponseOutputType.attentionItems,
        },
        triggerExamples: const [
          'prepare my daily briefing',
          'brief me on my day',
          'what does my day look like',
          'plan my day',
          'morning briefing',
          'give me my daily brief',
        ],
        steps: [
          const SkillStep(
            id: 'schedule',
            name: "Read today's schedule",
            toolName: 'list_schedule',
            failurePolicy: SkillStepFailurePolicy.continueAndReport,
          ),
          const SkillStep(
            id: 'tasks',
            name: 'List open tasks',
            toolName: 'list_tasks',
            argumentTemplate: {'open_only': true},
            failurePolicy: SkillStepFailurePolicy.continueAndReport,
          ),
          const SkillStep(
            id: 'reminders',
            name: 'List active reminders',
            toolName: 'list_reminders',
            argumentTemplate: {'status': 'Active'},
            failurePolicy: SkillStepFailurePolicy.continueAndReport,
          ),
        ],
        createdAt: now,
        updatedAt: now,
      ),

      // Fully deterministic: find overdue work so the user can act on it.
      WorkflowSkill(
        id: AgentId.skill(),
        name: 'follow_up_overdue_tasks',
        description: 'Find overdue tasks and report what needs follow-up, '
            'with suggested next steps.',
        version: 1,
        mode: SkillExecutionMode.deterministic,
        requiredDomains: {ToolDomains.tasks},
        requiredOutputs: const {
          ResponseOutputType.taskList,
          ResponseOutputType.attentionItems,
          ResponseOutputType.nextSteps,
        },
        triggerExamples: const [
          'what tasks are overdue',
          'follow up on overdue tasks',
          'show me what i am behind on',
          'what am i overdue on',
          'check my overdue work',
        ],
        steps: [
          const SkillStep(
            id: 'overdue',
            name: 'List overdue tasks',
            toolName: 'list_tasks',
            argumentTemplate: {'overdue_only': true},
            failurePolicy: SkillStepFailurePolicy.stop,
          ),
        ],
        createdAt: now,
        updatedAt: now,
      ),
    ];
  }
}
