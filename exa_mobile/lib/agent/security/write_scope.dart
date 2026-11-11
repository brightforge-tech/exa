import 'dart:convert';

/// A specific thing a run can create or change, finer-grained than
/// `localWrite`.
///
/// `localWrite` was already much narrower than "anything", but it is still
/// too broad for a personal assistant running unattended: creating a
/// *recurring* task every morning is technically a local write, and it is
/// also exactly the surprise a user cannot explain. Effects let a job say
/// what it is for — "mark mail digested, create at most five tasks" — and
/// let everything else be refused by default.
enum WriteEffect {
  taskCreate,
  taskCreateRecurring,
  taskUpdateStatus,
  taskUpdate,
  reminderCreateOneTime,
  reminderCreateRecurring,
  reminderUpdate,
  emailCreateDraft,
  emailMarkDigested,
  emailSync,
  messageMarkDigested,
  messageSync,
  messageSend,
  calendarCreateEvent,
  calendarCreatePendingEvent,
  calendarUpdateEvent,
  calendarSync,
  dayPlanUpdate,
  fileStore,
  screenCreate,
  behaviorPropose,
  behaviorApply,
  jobCreate,
  jobModify,
  collectionDefine,
  recordCreate,
  recordUpdate;

  String get wireName => switch (this) {
        taskCreate => 'task.create',
        taskCreateRecurring => 'task.create_recurring',
        taskUpdateStatus => 'task.update_status',
        taskUpdate => 'task.update',
        reminderCreateOneTime => 'reminder.create_one_time',
        reminderCreateRecurring => 'reminder.create_recurring',
        reminderUpdate => 'reminder.update',
        emailCreateDraft => 'email.create_draft',
        emailMarkDigested => 'email.mark_digested',
        emailSync => 'email.sync',
        messageMarkDigested => 'message.mark_digested',
        messageSync => 'message.sync',
        messageSend => 'message.send',
        calendarCreateEvent => 'calendar.create_event',
        calendarCreatePendingEvent => 'calendar.create_pending_event',
        calendarUpdateEvent => 'calendar.update_event',
        calendarSync => 'calendar.sync',
        dayPlanUpdate => 'day_plan.update',
        fileStore => 'file.store',
        screenCreate => 'screen.create',
        behaviorPropose => 'behavior.propose',
        behaviorApply => 'behavior.apply',
        jobCreate => 'job.create',
        jobModify => 'job.modify',
        collectionDefine => 'collection.define',
        recordCreate => 'record.create',
        recordUpdate => 'record.update',
      };

  static WriteEffect? fromWireName(String name) {
    final normalized = name.trim();
    for (final effect in WriteEffect.values) {
      if (effect.wireName == normalized) return effect;
    }
    return null;
  }

  /// Effects that keep producing work after the run that created them.
  /// These are the ones behind "why is there a new task every morning?".
  bool get isRecurring =>
      this == taskCreateRecurring ||
      this == reminderCreateRecurring ||
      this == jobCreate ||
      this == jobModify;
}

/// Per-effect limits inside one run.
class WriteScopeRule {
  const WriteScopeRule({
    this.maxPerRun = 25,
    this.requiresSourceItem = false,
    this.allowRecurring = false,
  });

  /// How many of this effect one run may produce.
  final int maxPerRun;

  /// When true, each record must name the item it came from — an email, a
  /// task, an event. A job that extracts tasks from mail has a source for
  /// every task it creates; one that invents them does not.
  final bool requiresSourceItem;

  /// Whether this run may create something that repeats.
  final bool allowRecurring;

  Map<String, Object?> toJson() => {
        'max_per_run': maxPerRun,
        if (requiresSourceItem) 'requires_source_item': true,
        if (allowRecurring) 'allow_recurring': true,
      };

  static WriteScopeRule fromJson(Object? json) {
    if (json is! Map) return const WriteScopeRule();
    return WriteScopeRule(
      maxPerRun: (json['max_per_run'] as num?)?.toInt() ?? 25,
      requiresSourceItem: json['requires_source_item'] == true,
      allowRecurring: json['allow_recurring'] == true,
    );
  }
}

/// What a run may write, and how much of it.
class WriteScope {
  const WriteScope({
    required this.allowedEffects,
    this.rules = const {},
    this.maxRecordsPerRun = 50,
    this.enforced = true,
  });

  /// No restriction beyond the capability policy — an interactive turn,
  /// where the user is present and every consequential tool already asks.
  static const unrestricted = WriteScope(
    allowedEffects: {},
    enforced: false,
  );

  /// The default for a scheduled run that did not declare its own scope.
  ///
  /// It can do the work background jobs legitimately do — digest mail,
  /// capture tasks, draft replies, propose a rule, queue a calendar event
  /// for approval — and nothing that repeats. Recurring work, job changes
  /// and behaviour activation are absent by design: those are how an
  /// unattended run turns one surprise into a daily one.
  static const unattendedDefault = WriteScope(
    allowedEffects: {
      WriteEffect.taskCreate,
      WriteEffect.taskUpdateStatus,
      WriteEffect.taskUpdate,
      WriteEffect.reminderCreateOneTime,
      WriteEffect.reminderUpdate,
      WriteEffect.emailCreateDraft,
      WriteEffect.emailMarkDigested,
      WriteEffect.emailSync,
      // Reading chat traffic and working through the queue is the same
      // bookkeeping a mail digest does. `message.send` is deliberately
      // absent: answering someone in the user's name is not something a
      // scheduled run does, and the capability gate refuses it too.
      WriteEffect.messageMarkDigested,
      WriteEffect.messageSync,
      WriteEffect.calendarCreateEvent,
      WriteEffect.calendarCreatePendingEvent,
      WriteEffect.calendarUpdateEvent,
      WriteEffect.calendarSync,
      // A morning job may lay out the day: the cards are on one screen, they
      // move nothing the user committed to, and dragging one off undoes it.
      WriteEffect.dayPlanUpdate,
      WriteEffect.fileStore,
      WriteEffect.screenCreate,
      WriteEffect.behaviorPropose,
    },
  );

  /// The scope of an unattended run under full autonomy: every effect,
  /// recurring included, with only the per-run caps left as loop-breakers.
  /// A job's own declared scope does not apply in that mode; the caps are
  /// deliberately generous so real work is never cut short, and deliberately
  /// finite so a model stuck in a loop is. Static final rather than const
  /// because it spans the whole enum.
  static final autonomous = WriteScope(
    allowedEffects: WriteEffect.values.toSet(),
    rules: {
      for (final effect in WriteEffect.values)
        effect: const WriteScopeRule(maxPerRun: 100, allowRecurring: true),
    },
    maxRecordsPerRun: 200,
  );

  final Set<WriteEffect> allowedEffects;
  final Map<WriteEffect, WriteScopeRule> rules;

  /// Backstop across all effects, so a run cannot produce fifty of one
  /// thing and fifty of another.
  final int maxRecordsPerRun;

  /// False for interactive turns: the scope is carried but not applied.
  final bool enforced;

  WriteScopeRule ruleFor(WriteEffect effect) =>
      rules[effect] ?? const WriteScopeRule();

  bool allows(WriteEffect effect) =>
      !enforced || allowedEffects.contains(effect);

  Map<String, Object?> toJson() => {
        'allowed_effects': [
          for (final effect in allowedEffects) effect.wireName,
        ],
        if (rules.isNotEmpty)
          'write_scope': {
            for (final entry in rules.entries)
              entry.key.wireName: entry.value.toJson(),
          },
        'max_records_per_run': maxRecordsPerRun,
      };

  String? encode() => enforced ? jsonEncode(toJson()) : null;

  /// Tolerant decode. Anything unparseable falls back to
  /// [unattendedDefault] rather than to "unrestricted": a malformed scope
  /// must never widen what a job can do.
  static WriteScope decode(Object? value, {WriteScope? fallback}) {
    final defaults = fallback ?? unattendedDefault;
    Object? json = value;
    if (value is String) {
      if (value.trim().isEmpty) return defaults;
      try {
        json = jsonDecode(value);
      } catch (_) {
        return defaults;
      }
    }
    if (json is! Map) return defaults;

    final raw = json['allowed_effects'];
    // A payload that says nothing about effects (every job created before
    // scopes existed) keeps the default. Only an explicit list narrows it -
    // otherwise adding this feature would silently stop existing jobs from
    // writing anything at all.
    if (raw is! List) return defaults;

    final effects = <WriteEffect>{};
    for (final name in raw.whereType<String>()) {
      final effect = WriteEffect.fromWireName(name);
      if (effect != null) effects.add(effect);
    }
    final rules = <WriteEffect, WriteScopeRule>{};
    final rawRules = json['write_scope'];
    if (rawRules is Map) {
      for (final entry in rawRules.entries) {
        final effect = WriteEffect.fromWireName('${entry.key}');
        if (effect != null) {
          rules[effect] = WriteScopeRule.fromJson(entry.value);
        }
      }
    }
    // An explicit empty list is a job that meant to write nothing, not one
    // that meant to write everything.
    return WriteScope(
      allowedEffects: effects,
      rules: rules,
      maxRecordsPerRun:
          (json['max_records_per_run'] as num?)?.toInt() ?? 50,
    );
  }

  /// The scope a job actually runs under: [decode]d from its
  /// `permissions_json`, widened by the effects of any outbound tools the job
  /// was granted (`outbound_grants`, see `JobPermissions`).
  ///
  /// Without this a grant would be half a grant: the capability gate would
  /// let `send_sms` through and the write ledger - whose unattended default
  /// deliberately omits `message.send` - would refuse it one line later. The
  /// grant is the user's decision; the ledger still counts what it sends.
  static WriteScope forJob(Object? permissionsJson, {WriteScope? fallback}) {
    final base = decode(permissionsJson, fallback: fallback);
    Object? json = permissionsJson;
    if (json is String) {
      try {
        json = json.trim().isEmpty ? null : jsonDecode(json);
      } catch (_) {
        json = null;
      }
    }
    final grants = json is Map ? json['outbound_grants'] : null;
    if (grants is! List || grants.isEmpty || !base.enforced) return base;
    final widened = {...base.allowedEffects};
    for (final tool in grants.whereType<String>()) {
      final effect = effectOf(tool, const {});
      if (effect != null) widened.add(effect);
    }
    if (widened.length == base.allowedEffects.length) return base;
    return WriteScope(
      allowedEffects: widened,
      rules: base.rules,
      maxRecordsPerRun: base.maxRecordsPerRun,
    );
  }

  /// The effect a tool call produces, decided from the tool and its
  /// arguments. A reminder with a recurrence rule is a different effect
  /// from one without, which is the whole point.
  static WriteEffect? effectOf(String tool, Map<String, Object?> arguments) {
    bool repeats() {
      final rule = arguments['recurrence_rule'] ?? arguments['recurrence'];
      return rule is String && rule.trim().isNotEmpty;
    }

    return switch (tool) {
      'create_task' => repeats()
          ? WriteEffect.taskCreateRecurring
          : WriteEffect.taskCreate,
      'complete_task' => WriteEffect.taskUpdateStatus,
      'update_task' => WriteEffect.taskUpdate,
      'create_reminder' => repeats()
          ? WriteEffect.reminderCreateRecurring
          : WriteEffect.reminderCreateOneTime,
      'update_reminder' || 'cancel_reminder' => WriteEffect.reminderUpdate,
      'mark_email_digested' => WriteEffect.emailMarkDigested,
      'sync_emails' => WriteEffect.emailSync,
      'send_email' => WriteEffect.emailCreateDraft,
      'mark_message_digested' => WriteEffect.messageMarkDigested,
      'sync_messages' => WriteEffect.messageSync,
      'reply_to_chat' => WriteEffect.messageSend,
      // A text or a WhatsApp message is a message sent in the user's name,
      // whatever the transport. A call leaves no record to scope.
      'send_sms' || 'send_whatsapp' => WriteEffect.messageSend,
      'create_schedule_event' => WriteEffect.calendarCreateEvent,
      'add_to_phone_calendar' => WriteEffect.calendarCreatePendingEvent,
      'update_schedule_event' => WriteEffect.calendarUpdateEvent,
      'sync_device_calendar' => WriteEffect.calendarSync,
      'plan_day_item' || 'move_day_plan_item' || 'unplan_day_item' =>
        WriteEffect.dayPlanUpdate,
      'store_file' || 'write_file' => WriteEffect.fileStore,
      'create_dynamic_screen' || 'save_screen' => WriteEffect.screenCreate,
      'propose_behavior_change' => WriteEffect.behaviorPropose,
      'activate_behavior' ||
      'update_behavior' ||
      'pause_behavior' ||
      'rollback_behavior_version' =>
        WriteEffect.behaviorApply,
      'create_scheduled_job' => WriteEffect.jobCreate,
      'pause_scheduled_job' ||
      'resume_scheduled_job' ||
      'mute_scheduled_job' ||
      'delete_scheduled_job' =>
        WriteEffect.jobModify,
      'define_collection' => WriteEffect.collectionDefine,
      'add_record' => WriteEffect.recordCreate,
      'update_record' => WriteEffect.recordUpdate,
      _ => null,
    };
  }

  /// Argument keys that name the record a write came from. Used for
  /// `requires_source_item` and for creation provenance.
  static const sourceItemKeys = {
    'email_id', 'email_ids', 'source_email_id', 'task_id', 'event_id',
    'file_id', 'attachment_id', 'source_id', 'source_record_id', 'message_id',
  };

  static String? sourceItemIn(Map<String, Object?> arguments) {
    for (final key in sourceItemKeys) {
      final value = arguments[key];
      if (value is String && value.trim().isNotEmpty) return value.trim();
      if (value is List && value.isNotEmpty) {
        final first = value.first;
        if (first is String && first.trim().isNotEmpty) return first.trim();
      }
    }
    return null;
  }
}

/// Counts what one run has already written, so per-effect and overall caps
/// can be enforced across the whole run rather than per call.
class WriteScopeLedger {
  WriteScopeLedger(this.scope);

  final WriteScope scope;
  final Map<WriteEffect, int> _counts = {};
  var _total = 0;

  /// Effects that were refused, for the run's report.
  final List<String> blocked = [];

  int countOf(WriteEffect effect) => _counts[effect] ?? 0;
  int get total => _total;

  /// Decides whether [effect] may run now. Returns null when allowed, or
  /// the reason to hand back to the model when not.
  String? check(WriteEffect effect, Map<String, Object?> arguments) {
    if (!scope.enforced) return null;
    final rule = scope.ruleFor(effect);

    if (!scope.allows(effect)) {
      final reason = effect.isRecurring
          ? "'${effect.wireName}' creates something that keeps happening, "
              'which a scheduled run may not do without being set up for it. '
              'Do the one-off part and say in your summary what you skipped.'
          : "This run is not allowed to do '${effect.wireName}'. Do the rest "
              'of the task and report this as skipped.';
      blocked.add(effect.wireName);
      return reason;
    }
    if (effect.isRecurring && !rule.allowRecurring) {
      blocked.add(effect.wireName);
      return "Creating recurring work is not authorized for this run. "
          'Create a single one instead, or tell the user what you would set '
          'up.';
    }
    if (_total >= scope.maxRecordsPerRun) {
      blocked.add(effect.wireName);
      return 'This run has already created ${scope.maxRecordsPerRun} '
          'records, which is its limit. Summarize what was done instead of '
          'creating more.';
    }
    if (countOf(effect) >= rule.maxPerRun) {
      blocked.add(effect.wireName);
      return "This run has already done '${effect.wireName}' "
          '${rule.maxPerRun} times, which is its limit. Report the rest '
          'rather than creating more.';
    }
    if (rule.requiresSourceItem &&
        WriteScope.sourceItemIn(arguments) == null) {
      blocked.add(effect.wireName);
      return "This run may only create records tied to a specific item it "
          'processed. Include the id of the email, task, or event this came '
          'from, or skip it.';
    }
    return null;
  }

  /// Records a write that actually happened.
  void record(WriteEffect effect) {
    _counts[effect] = countOf(effect) + 1;
    _total++;
  }
}
