import 'dart:convert';

import '../../data/models/autonomy_level.dart';
import '../models/creation_provenance.dart';
import 'write_scope.dart';

/// Who (if anyone) is watching a turn.
///
/// This is a security boundary, not a hint: [CapabilityGate] denies unsafe
/// tools in [unattended] mode before the tool runs. Telling the model in a
/// prompt that nobody can approve anything improves its behaviour, but a
/// confused or prompt-injected model can still emit the call - so the
/// executor, not the prompt, is where this is enforced.
enum AgentRunMode {
  /// A user is present and can be asked to confirm.
  interactive,

  /// A scheduled/background run. Nobody can approve anything.
  unattended,
}

/// What a tool can do to the world, used to decide what an unattended run
/// may touch. A tool is classified by its worst effect.
enum ToolCapability {
  /// Reads local data only.
  read,

  /// Writes local app data (tasks, events, drafts, files).
  localWrite,

  /// Destroys local data irreversibly.
  destructive,

  /// Sends something to a person or an external service.
  outbound,

  /// Changes what the agent itself is allowed to do or will do later
  /// (behavior rules, scheduled jobs).
  selfModifying,

  /// Spends money.
  purchase,
}

/// Why a capability outside the active policy was refused.
///
/// The refusal text is what the model reads and acts on, so it has to describe
/// the real situation. "A scheduled run cannot approve this" is actively
/// misleading on an interactive turn that is merely waiting for the user to say
/// which task they meant, and a model told the wrong reason invents the wrong
/// recovery.
enum CapabilityRefusal {
  unattended,
  awaitingClarification,
  lockedDevice;

  String get code => switch (this) {
        unattended => 'unattended_capability',
        awaitingClarification => 'awaiting_clarification',
        lockedDevice => 'locked_device',
      };

  String reasonFor(String tool, ToolCapability capability) => switch (this) {
        unattended => _unattendedReason(tool, capability),
        awaitingClarification =>
          "This turn does not yet know what the user meant, so '$tool' - "
              'anything that changes something - is blocked until they say. '
              'You may still read. Look up the candidates, name them '
              'concretely, and end with exactly one question asking which they '
              'meant. Do not guess and do not act.',
        lockedDevice => _lockedDeviceReason(tool, capability),
      };

  static String _unattendedReason(String tool, ToolCapability capability) {
    final what = switch (capability) {
      ToolCapability.outbound =>
        'reaches other people or an external service',
      ToolCapability.destructive => 'permanently deletes data',
      ToolCapability.purchase => 'spends money',
      ToolCapability.selfModifying => 'changes your own rules or schedule',
      _ => 'is not available here',
    };
    final grantHint = capability == ToolCapability.outbound
        ? ' (A scheduled job may only do this when the user set it up with '
            "an explicit outbound grant for '$tool'; this one was not.)"
        : '';
    return "'$tool' $what, so it is blocked in a scheduled run where the "
        'user cannot approve it.$grantHint Do the rest of the task and say '
        'plainly in your summary that you skipped this and why.';
  }

  /// The phone is locked: whoever is typing has not proved they are the
  /// owner, so nothing that leaves the phone or cannot be undone runs.
  static String _lockedDeviceReason(String tool, ToolCapability capability) {
    final what = switch (capability) {
      ToolCapability.outbound => 'would reach other people or a service',
      ToolCapability.destructive => 'would permanently delete data',
      ToolCapability.purchase => 'would spend money',
      ToolCapability.selfModifying => 'would change your own rules or schedule',
      _ => 'is not available here',
    };
    return "'$tool' $what, and this request came from the lock screen, "
        'where the phone is still locked. Do not attempt it. Tell the user '
        'in one short sentence that they need to unlock the phone for that, '
        'and do whatever else they asked that you can.';
  }
}

/// The set of capabilities a run may exercise.
class CapabilityPolicy {
  const CapabilityPolicy({
    required this.allowedCapabilities,
    this.canRunNestedJobs = true,
    this.refusal = CapabilityRefusal.unattended,
  });

  /// Everything is permitted; the confirmation gate remains the check for
  /// high-risk tools.
  static const interactive = CapabilityPolicy(
    allowedCapabilities: {
      ToolCapability.read,
      ToolCapability.localWrite,
      ToolCapability.destructive,
      ToolCapability.outbound,
      ToolCapability.selfModifying,
      ToolCapability.purchase,
    },
  );

  /// The v3 default ([AutonomyLevel.full]): everything is permitted in
  /// every run mode, nested jobs included, and the orchestrator also stops
  /// asking for confirmation. What still applies under it: job blocks and
  /// allow-lists (the user's own configuration of a job), the write ledger's
  /// per-run caps (a runaway loop is a bug, not a policy), and content-trust
  /// labelling (an email is still data, not an instruction).
  static const autonomous = CapabilityPolicy(
    allowedCapabilities: {
      ToolCapability.read,
      ToolCapability.localWrite,
      ToolCapability.destructive,
      ToolCapability.outbound,
      ToolCapability.selfModifying,
      ToolCapability.purchase,
    },
  );

  /// The default for a background run in guarded mode: it may read and
  /// produce local work (tasks, events, drafts, notifications) but may not
  /// message anyone, delete anything, spend money, or rewrite its own rules
  /// and schedule while nobody is watching.
  static const unattended = CapabilityPolicy(
    allowedCapabilities: {
      ToolCapability.read,
      ToolCapability.localWrite,
    },
    canRunNestedJobs: false,
  );

  /// A turn that has not established what the user meant. It may look things
  /// up - which is how it can name the candidates instead of asking a bare
  /// "which one?" - and may change nothing at all.
  ///
  /// Deliberately narrower than [unattended], which still permits local
  /// writes: the point here is not "nobody can approve this", it is "we do not
  /// yet know what to do", and a local write on the wrong reading is exactly
  /// the surprise this prevents.
  static const readOnly = CapabilityPolicy(
    allowedCapabilities: {ToolCapability.read},
    canRunNestedJobs: false,
    refusal: CapabilityRefusal.awaitingClarification,
  );

  /// A turn typed or spoken on the lock screen. The user is present - they
  /// can confirm, the turn is interactive - but they have not unlocked the
  /// phone, so anyone holding it could be the one asking. Reads and local
  /// work (a reminder, a task, a note about a snippet) are what the lock
  /// screen is for; sending anything, deleting anything, or changing the
  /// agent's own rules waits for an unlock. Same surface as [unattended],
  /// for a different reason, and its refusal says that reason.
  static const lockScreen = CapabilityPolicy(
    allowedCapabilities: {
      ToolCapability.read,
      ToolCapability.localWrite,
    },
    canRunNestedJobs: false,
    refusal: CapabilityRefusal.lockedDevice,
  );

  final Set<ToolCapability> allowedCapabilities;

  /// Whether the run may trigger other jobs (a job that runs jobs can loop).
  final bool canRunNestedJobs;

  /// How a refusal under this policy is explained to the model.
  final CapabilityRefusal refusal;

  static CapabilityPolicy forRunMode(AgentRunMode mode) =>
      mode == AgentRunMode.unattended ? unattended : interactive;

  bool allows(ToolCapability capability) =>
      allowedCapabilities.contains(capability);
}

/// Per-job tool allow/block lists, stored on the job as `permissions_json`.
///
/// A job may be given a narrower surface than the run mode allows - e.g.
/// "may create a draft, may not send it". Blocks always beat allows.
class JobPermissions {
  const JobPermissions({
    this.allowedTools = const {},
    this.blockedTools = const {},
    this.outboundGrants = const {},
  });

  static const none = JobPermissions();

  /// When non-empty, ONLY these tools may change anything. Reads are never
  /// held to the list: a job narrowed to "create tasks from my chats" still
  /// has to look at the tasks and the schedule it already has, or it files
  /// duplicates and books clashes - the very thing the list was meant to
  /// prevent. A listed tool also admits other local edits of the same kind
  /// of record - allowing `create_schedule_event` allows
  /// `update_schedule_event` - because a job that may add an event has to
  /// be able to move the one it added when the next message reschedules
  /// it. Anything the job must not do goes in [blockedTools].
  final Set<String> allowedTools;

  /// Never allowed, even if listed in [allowedTools] or permitted by the
  /// run mode.
  final Set<String> blockedTools;

  /// Outbound tools this job may use unattended - `send_sms`, `place_call`,
  /// `send_whatsapp`, `send_email`, ... - because the user asked for exactly
  /// that when they scheduled it ("text Mum every Friday at five").
  ///
  /// This is the one place a job can be *wider* than its run mode, and it is
  /// deliberately narrow: each grant names one tool, it is made at creation
  /// time by a tool that asks the user to confirm, it is shown on the Jobs
  /// screen, and it still yields to [blockedTools], [allowedTools] and the
  /// external-content gate (a message the job read cannot talk it into
  /// sending one). Nothing else - destructive, self-modifying, purchase -
  /// can be granted this way.
  final Set<String> outboundGrants;

  bool get isEmpty =>
      allowedTools.isEmpty && blockedTools.isEmpty && outboundGrants.isEmpty;

  /// Whether [tool] may act outbound in an unattended run.
  bool grantsOutbound(String tool) => outboundGrants.contains(tool);

  Map<String, Object?> toJson() => {
        if (allowedTools.isNotEmpty) 'allowed_tools': allowedTools.toList(),
        if (blockedTools.isNotEmpty) 'blocked_tools': blockedTools.toList(),
        if (outboundGrants.isNotEmpty)
          'outbound_grants': outboundGrants.toList(),
      };

  String? encode() => isEmpty ? null : jsonEncode(toJson());

  /// Tolerant decode: malformed permissions must not silently widen what a
  /// job can do, so anything unparseable becomes [none] and the caller's
  /// run mode remains the only limit.
  static JobPermissions decode(Object? value) {
    if (value is String && value.isNotEmpty) {
      try {
        return fromJson(jsonDecode(value));
      } catch (_) {
        return none;
      }
    }
    return value is Map ? fromJson(value) : none;
  }

  static JobPermissions fromJson(Object? json) {
    if (json is! Map) return none;
    Set<String> list(String key) {
      final value = json[key];
      if (value is! List) return const {};
      return value.whereType<String>().toSet();
    }

    return JobPermissions(
      allowedTools: list('allowed_tools'),
      blockedTools: list('blocked_tools'),
      outboundGrants: list('outbound_grants'),
    );
  }
}

/// The answer from [CapabilityGate].
class CapabilityDecision {
  const CapabilityDecision.allowed()
      : isAllowed = true,
        code = null,
        reason = null;

  const CapabilityDecision.denied(this.code, this.reason) : isAllowed = false;

  final bool isAllowed;

  /// Stable machine code for diagnostics (`unattended_capability`,
  /// `awaiting_clarification`, `locked_device`, `job_tool_blocked`,
  /// `job_tool_not_allowed`, `nested_job`).
  final String? code;

  /// Explanation handed back to the model in place of the tool result.
  final String? reason;
}

/// Decides whether a tool call may run at all, before it runs.
///
/// Precedence, highest first - a lower level can never widen a higher one:
///   1. system safety (this gate)
///   2. capability restrictions (run mode)
///   3. job-specific permissions
///   4. everything below (behaviors, preferences, defaults) is advisory
class CapabilityGate {
  const CapabilityGate();

  /// Tools whose worst effect is not "read". Anything unlisted is treated
  /// as [ToolCapability.localWrite] when it writes and [read] otherwise -
  /// see [capabilityOf], which fails closed for unknown names.
  static const capabilities = <String, ToolCapability>{
    // Reaches a person or an external service.
    'send_email': ToolCapability.outbound,
    // Puts words in the user's name into someone else's chat, and a chat
    // message cannot be unsent the way a draft can be discarded. Being
    // outbound also means an unattended run cannot reach it at all - which
    // matters more here than for mail, because chat capture is the one
    // source where a stranger in a group can put text in front of Exa.
    'reply_to_chat': ToolCapability.outbound,
    'add_to_phone_calendar': ToolCapability.outbound,
    // Phone access. A text, a call or a WhatsApp message reaches a person
    // in the user's name; all three ask for confirmation interactively and
    // need a per-job outbound grant to run from a schedule.
    'send_sms': ToolCapability.outbound,
    'place_call': ToolCapability.outbound,
    'send_whatsapp': ToolCapability.outbound,
    // Screen control. Reading the screen is a read; tapping, typing, swiping
    // and pressing a system button change local UI state (a localWrite).
    // They are deliberately NOT outbound: driving an app's own screen is the
    // user's own hands, not Exa reaching an external service - the app
    // decides whether a tap sends anything, exactly as it does for a person.
    // A scheduled run still gets only read + localWrite by default, so it can
    // read a screen but an unattended run that has also read outside content
    // is held back from consequential taps by the same external-content gate.
    'read_screen': ToolCapability.read,
    'screen_screenshot': ToolCapability.read,
    'tap_screen': ToolCapability.localWrite,
    'type_text': ToolCapability.localWrite,
    'swipe_screen': ToolCapability.localWrite,
    'press_button': ToolCapability.localWrite,
    'open_app': ToolCapability.localWrite,
    // Irreversible local destruction.
    'delete_task': ToolCapability.destructive,
    'delete_email': ToolCapability.destructive,
    'delete_file': ToolCapability.destructive,
    'delete_schedule_event': ToolCapability.destructive,
    'delete_scheduled_job': ToolCapability.destructive,
    'delete_dynamic_screen': ToolCapability.destructive,
    'delete_record': ToolCapability.destructive,
    // Changes what the agent will do later.
    'propose_behavior_change': ToolCapability.selfModifying,
    'update_behavior': ToolCapability.selfModifying,
    'activate_behavior': ToolCapability.selfModifying,
    'pause_behavior': ToolCapability.selfModifying,
    'rollback_behavior_version': ToolCapability.selfModifying,
    'create_scheduled_job': ToolCapability.selfModifying,
    'pause_scheduled_job': ToolCapability.selfModifying,
    'resume_scheduled_job': ToolCapability.selfModifying,
    'mute_scheduled_job': ToolCapability.selfModifying,
    'run_scheduled_job_now': ToolCapability.selfModifying,
    // Local writes.
    'create_task': ToolCapability.localWrite,
    'update_task': ToolCapability.localWrite,
    'complete_task': ToolCapability.localWrite,
    'create_reminder': ToolCapability.localWrite,
    'update_reminder': ToolCapability.localWrite,
    // Sets status to Canceled rather than deleting; reversible and visible
    // on the Reminders screen, so it is an ordinary local write.
    'cancel_reminder': ToolCapability.localWrite,
    'create_schedule_event': ToolCapability.localWrite,
    'update_schedule_event': ToolCapability.localWrite,
    // Planning board cards: local, visible on one screen, and undone by
    // dragging them off. Nothing they touch is a deadline or a commitment.
    'plan_day_item': ToolCapability.localWrite,
    'move_day_plan_item': ToolCapability.localWrite,
    'unplan_day_item': ToolCapability.localWrite,
    'sync_device_calendar': ToolCapability.localWrite,
    'sync_emails': ToolCapability.localWrite,
    'mark_email_digested': ToolCapability.localWrite,
    'sync_messages': ToolCapability.localWrite,
    'mark_message_digested': ToolCapability.localWrite,
    'store_file': ToolCapability.localWrite,
    'write_file': ToolCapability.localWrite,
    'create_dynamic_screen': ToolCapability.localWrite,
    'save_screen': ToolCapability.localWrite,
    // Collections and their records: local data behind agent-built
    // features. Editing a record is reversible from its detail view;
    // deleting one is not, and is classified destructive above.
    'define_collection': ToolCapability.localWrite,
    'add_record': ToolCapability.localWrite,
    'update_record': ToolCapability.localWrite,
    'evaluate_behavior': ToolCapability.localWrite,
    'summarize_browser_page': ToolCapability.localWrite,
    'read_current_browser_page': ToolCapability.localWrite,
    // Reads.
    'list_tasks': ToolCapability.read,
    'list_reminders': ToolCapability.read,
    'list_schedule': ToolCapability.read,
    'list_day_plan': ToolCapability.read,
    'list_files': ToolCapability.read,
    'list_scheduled_jobs': ToolCapability.read,
    'list_agent_behaviors': ToolCapability.read,
    'list_mail_accounts': ToolCapability.read,
    'list_browser_tabs': ToolCapability.read,
    'read_email_context': ToolCapability.read,
    'read_message_context': ToolCapability.read,
    'read_chat': ToolCapability.read,
    // Chat media is read through read_message_context's media_id argument,
    // not through a tool of its own: a name here without matching entries
    // in ToolLabels, QuietTurn, the synthesizer and the grounding tables
    // would leak the raw tool name onto surfaces a person reads.
    'list_chats': ToolCapability.read,
    'read_browser_context': ToolCapability.read,
    'read_file': ToolCapability.read,
    'search': ToolCapability.read,
    'open_screen': ToolCapability.read,
    'list_collections': ToolCapability.read,
    'list_records': ToolCapability.read,
    // The user's own address book - theirs, not outside content.
    'find_contact': ToolCapability.read,
  };

  /// An unknown tool is assumed to be as dangerous as the strictest class
  /// this gate knows about. A tool added later without being classified is
  /// then unavailable to unattended runs until someone classifies it -
  /// which is the safe direction to fail in.
  static ToolCapability capabilityOf(String toolName) =>
      capabilities[toolName] ?? ToolCapability.outbound;

  CapabilityDecision authorize({
    required String tool,
    required Map<String, Object?> arguments,
    AgentRunMode runMode = AgentRunMode.interactive,
    JobPermissions jobPermissions = JobPermissions.none,
    CapabilityPolicy? policy,
    WriteScopeLedger? writeLedger,
    bool externalContentInScope = false,
    bool bypassExternalContentGate = false,
  }) {
    final effective = policy ?? CapabilityPolicy.forRunMode(runMode);
    final capability = capabilityOf(tool);

    // Job blocks are absolute.
    if (jobPermissions.blockedTools.contains(tool)) {
      return CapabilityDecision.denied(
        'job_tool_blocked',
        "This job is not allowed to use '$tool'. Do the part of the task "
            'you can, and say in your summary what you could not do.',
      );
    }
    // Reads pass the allow-list, and so does a local edit of the same kind
    // of record as a listed tool (see [JobPermissions.allowedTools]); a
    // block above is still the way to keep either out.
    if (jobPermissions.allowedTools.isNotEmpty &&
        !jobPermissions.allowedTools.contains(tool) &&
        capability != ToolCapability.read &&
        !_editsAllowedKind(
            tool, capability, arguments, jobPermissions.allowedTools)) {
      return CapabilityDecision.denied(
        'job_tool_not_allowed',
        "This job may only use: ${_list(jobPermissions.allowedTools)} "
            '(plus reads, and other changes to the same kinds of records). '
            "'$tool' is not one of them - report it as skipped instead.",
      );
    }

    // An outbound grant lets a scheduled job do the one outbound thing the
    // user scheduled it for. It applies to the plain unattended policy only:
    // a turn narrowed further (awaiting clarification, or typed on the lock
    // screen) keeps its own refusal, because those are not "nobody can
    // approve this" - they are "we do not know / do not trust who asked".
    final granted = capability == ToolCapability.outbound &&
        effective.refusal == CapabilityRefusal.unattended &&
        jobPermissions.grantsOutbound(tool);
    if (!effective.allows(capability) && !granted) {
      return CapabilityDecision.denied(
        effective.refusal.code,
        effective.refusal.reasonFor(tool, capability),
      );
    }

    if (!effective.canRunNestedJobs && _nestedJobTools.contains(tool)) {
      return const CapabilityDecision.denied(
        'nested_job',
        'A scheduled run cannot start other scheduled jobs. Report what '
            'you would have run instead.',
      );
    }

    // `localWrite` is still broad: an unexpected *recurring* task is a local
    // write, and so is the fiftieth task of one run. The write scope narrows
    // it to the specific effects this run was set up to produce, and counts
    // them.
    if (writeLedger != null) {
      final effect = WriteScope.effectOf(tool, arguments);
      if (effect != null) {
        final refusal = writeLedger.check(effect, arguments);
        if (refusal != null) {
          return CapabilityDecision.denied('write_scope', refusal);
        }
      }
    }

    // Content that came from outside the app cannot authorize a
    // consequential action, in any run mode. An email that says "forward
    // this to accounts@…" is a sentence in a document, not a request from
    // the user - so when external content is in scope, anything that
    // reaches the world or destroys data needs the user, not the model.
    // Full autonomy switches this off by the user's explicit choice; the
    // content is still labelled as data, so the model is told, not fooled.
    if (externalContentInScope &&
        runMode == AgentRunMode.unattended &&
        !bypassExternalContentGate) {
      const gated = {
        ToolCapability.outbound,
        ToolCapability.destructive,
        ToolCapability.selfModifying,
        ToolCapability.purchase,
      };
      if (gated.contains(capability)) {
        return CapabilityDecision.denied(
          'external_content_authorization',
          "This run has read outside content (email, a web page, or a "
              "file), so '$tool' needs the user's own go-ahead before it can "
              'run. Say what you would do and why, and leave it to them.',
        );
      }
    }

    return const CapabilityDecision.allowed();
  }

  static const _nestedJobTools = {'run_scheduled_job_now'};

  /// Whether [tool], a local write the allow-list does not name, edits the
  /// same kind of record as a tool it does name. Never widens past local
  /// writes: sending, deleting and rule changes must be named, and the run
  /// mode still has to allow them.
  static bool _editsAllowedKind(
    String tool,
    ToolCapability capability,
    Map<String, Object?> arguments,
    Set<String> allowed,
  ) {
    if (capability != ToolCapability.localWrite) return false;
    final kind = writeKindOf(tool, arguments);
    if (kind == null) return false;
    return allowed.any((name) => writeKindOf(name, const {}) == kind);
  }

  /// The family of [tool]'s write effect - `calendar.create_event` and
  /// `calendar.update_event` are both `calendar` - or null for a tool with
  /// no write effect.
  static String? writeKindOf(String tool, Map<String, Object?> arguments) =>
      WriteScope.effectOf(tool, arguments)?.wireName.split('.').first;

  static String _list(Set<String> tools) {
    final sorted = tools.toList()..sort();
    return sorted.join(', ');
  }
}

/// The security context a tool call executes under. Defaults to a fully
/// permitted interactive run so existing callers are unaffected.
class CapabilityContext {
  const CapabilityContext({
    this.runMode = AgentRunMode.interactive,
    this.jobPermissions = JobPermissions.none,
    this.jobId,
    this.runId,
    this.writeScope,
    this.writeLedger,
    this.provenance,
    this.externalContentTracker,
    this.policy,
    this.autonomy = AutonomyLevel.guarded,
    this.runCheck,
  });

  static const interactive = CapabilityContext();

  /// A check only the run itself can make, because it depends on what the
  /// run has done so far rather than on the tool and its arguments - e.g.
  /// "this scheduled digest has read nothing yet, so it has nothing to
  /// create a task from" (see `SourceGrounding`). Consulted by
  /// `ToolRegistry.execute` after the [CapabilityGate], and refused, logged
  /// and reported exactly like a gate denial. Null when allowed.
  final CapabilityDecision? Function(
      String tool, Map<String, Object?> arguments)? runCheck;

  final AgentRunMode runMode;
  final JobPermissions jobPermissions;
  final String? jobId;

  /// The occurrence this run belongs to, so records it creates can be
  /// traced back to (and undone as) one run.
  final String? runId;

  /// What this run may write. Null falls back to the run mode's default:
  /// unrestricted interactively, [WriteScope.unattendedDefault] otherwise.
  final WriteScope? writeScope;

  /// Per-run counters for the scope. Supplied by the caller that owns the
  /// run; interactive turns pass one only when they want the counters.
  final WriteScopeLedger? writeLedger;

  /// Stamped onto every record this run creates.
  final CreationProvenance? provenance;

  /// Set when this run has read content from outside the app. Mutable
  /// because it becomes true partway through a turn - the moment an email
  /// body or web page enters the context, later tool calls are no longer
  /// operating on trusted input alone.
  final ExternalContentTracker? externalContentTracker;

  /// Narrows this run below what its mode would allow. Null keeps the run
  /// mode's own policy. Set to [CapabilityPolicy.readOnly] by a turn that has
  /// not established what the user meant - the restriction is enforced here,
  /// in the gate, rather than asked for in the prompt.
  final CapabilityPolicy? policy;

  /// The user's autonomy setting for this turn. Defaults to guarded so a
  /// context built without one (tests, direct registry callers) keeps v2's
  /// gates; the orchestrator sets it from Settings on every run.
  final AutonomyLevel autonomy;

  /// Full autonomy: confirmation-gated tools run without asking.
  bool get autoApproveConfirmations => autonomy.isFull;

  /// Full autonomy: the per-domain switches in Settings > Agent permissions
  /// are not applied.
  bool get bypassUserPermissionGate => autonomy.isFull;

  /// Full autonomy: outside content in scope no longer blocks consequential
  /// actions in unattended runs.
  bool get bypassExternalContentGate => autonomy.isFull;

  bool get isUnattended => runMode == AgentRunMode.unattended;

  WriteScope get effectiveWriteScope =>
      writeScope ??
      (isUnattended ? WriteScope.unattendedDefault : WriteScope.unrestricted);

  bool get hasSeenExternalContent =>
      externalContentTracker?.seen ?? false;

  CreationProvenance get effectiveProvenance =>
      provenance ??
      CreationProvenance(
        originType: isUnattended ? 'scheduled_job' : 'agent_turn',
        originJobId: jobId,
        originRunId: runId,
        authorizationSource: isUnattended ? 'job_permissions' : 'interactive',
      );
}

/// Tracks whether untrusted content has entered a run.
///
/// Deliberately a tiny mutable object rather than a flag on the context:
/// the context is created once at the top of a turn, while the fact it
/// records only becomes true partway through, when a tool returns an email
/// body or a web page.
class ExternalContentTracker {
  ExternalContentTracker();

  var _seen = false;
  var _injectionFindings = 0;
  final Set<String> _sources = {};

  bool get seen => _seen;
  int get injectionFindings => _injectionFindings;
  Set<String> get sources => Set.unmodifiable(_sources);

  void markSeen(String source, {int injectionFindings = 0}) {
    _seen = true;
    _sources.add(source);
    _injectionFindings += injectionFindings;
  }
}
