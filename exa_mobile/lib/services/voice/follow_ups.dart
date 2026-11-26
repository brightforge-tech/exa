import 'dart:convert';

import 'package:exa_voice/exa_voice.dart';

import '../../agent/models/tool_execution_record.dart';
import '../../data/repositories/settings_repository.dart';

/// Something Exa could not settle on its own and wants to ask about: an
/// event with no date, a task it is not sure is one, two readings of the
/// same message.
class FollowUpQuestion {
  const FollowUpQuestion({
    required this.id,
    required this.title,
    required this.question,
    this.details = '',
    this.reason = 'unclear',
    required this.createdAt,
  });

  final String id;

  /// What the item is ("Team offsite").
  final String title;

  /// What Exa needs to know ("What date is the offsite?").
  final String question;

  /// What Exa already knows, and where it came from.
  final String details;

  /// `missing_date`, `missing_time`, `unclear`, `confirm`.
  final String reason;
  final DateTime createdAt;

  Map<String, Object?> toJson() => {
        'id': id,
        'title': title,
        'question': question,
        if (details.isNotEmpty) 'details': details,
        'reason': reason,
        'created_at': createdAt.toIso8601String(),
      };

  static FollowUpQuestion? fromJson(Object? raw) {
    if (raw is! Map) return null;
    final id = raw['id'];
    final title = raw['title'];
    final question = raw['question'];
    if (id is! String || title is! String || question is! String) return null;
    return FollowUpQuestion(
      id: id,
      title: title,
      question: question,
      details: raw['details'] as String? ?? '',
      reason: raw['reason'] as String? ?? 'unclear',
      createdAt: DateTime.tryParse(raw['created_at'] as String? ?? '') ??
          DateTime.now(),
    );
  }
}

/// The open questions, kept in settings: a short list, read and written
/// whole, with no history worth a table of its own.
class FollowUpStore {
  FollowUpStore(this._settings);

  final SettingsRepository _settings;

  static const key = 'voice_follow_up_questions';

  /// Older questions drop off: a question nobody answered in a week is not
  /// worth asking any more, and the list is spoken aloud.
  static const maxQuestions = 20;
  static const maxAge = Duration(days: 7);

  Future<List<FollowUpQuestion>> list() async {
    final raw = await _settings.getValue(key);
    if (raw == null || raw.isEmpty) return [];
    try {
      final cutoff = DateTime.now().subtract(maxAge);
      return [
        for (final item in jsonDecode(raw) as List)
          if (FollowUpQuestion.fromJson(item) case final q?
              when q.createdAt.isAfter(cutoff))
            q,
      ];
    } catch (_) {
      return [];
    }
  }

  Future<void> _save(List<FollowUpQuestion> questions) => _settings.setValue(
        key,
        jsonEncode([
          for (final q in questions.take(maxQuestions)) q.toJson(),
        ]),
      );

  /// Adds [question] unless the same item is already waiting, newest first.
  Future<FollowUpQuestion> add(FollowUpQuestion question) async {
    final existing = await list();
    final same = existing.where((q) =>
        q.title.toLowerCase().trim() == question.title.toLowerCase().trim());
    if (same.isNotEmpty) return same.first;
    await _save([question, ...existing]);
    return question;
  }

  Future<bool> resolve(String id) async {
    final existing = await list();
    final kept = [for (final q in existing) if (q.id != id) q];
    if (kept.length == existing.length) return false;
    await _save(kept);
    return true;
  }

  Future<void> clear() => _settings.setValue(key, '[]');
}

/// One thing Exa added, as the user should hear it.
class AddedItem {
  const AddedItem({required this.kind, required this.title, this.when});

  /// `task`, `reminder` or `event`.
  final String kind;
  final String title;

  /// The tool result's own date label, never one worked out here.
  final String? when;

  String get _article => kind.startsWith(RegExp('[aeiou]')) ? 'an' : 'a';

  String get spoken => when == null || when!.isEmpty
      ? '$_article $kind, $title'
      : '$_article $kind, $title, ${kind == 'task' ? 'due' : 'for'} $when';

  String get line => when == null || when!.isEmpty
      ? '${_capital(kind)}: $title'
      : '${_capital(kind)}: $title ($when)';

  static String _capital(String s) =>
      s.isEmpty ? s : '${s[0].toUpperCase()}${s.substring(1)}';

  static const _kindByTool = {
    'create_task': 'task',
    'create_reminder': 'reminder',
    'create_schedule_event': 'event',
    'add_to_phone_calendar': 'event',
  };

  static const _labelKeys = [
    'due_at_label',
    'remind_at_label',
    'start_at_label',
    'start_label',
  ];

  /// What a run created, read from its execution records - what actually
  /// happened, never what the model said happened.
  static List<AddedItem> fromRecords(Iterable<ToolExecutionRecord> records) {
    final items = <AddedItem>[];
    for (final record in records) {
      final kind = _kindByTool[record.toolName];
      if (kind == null || record.status != ToolExecutionStatus.success) {
        continue;
      }
      if (record.wasDeduplicated) continue;
      final data = _itemMap(record.rawResult);
      final title = (data?['title'] ?? record.arguments['title'])?.toString();
      if (title == null || title.trim().isEmpty) continue;
      String? when;
      for (final key in _labelKeys) {
        final value = data?[key];
        if (value is String && value.isNotEmpty) {
          when = value;
          break;
        }
      }
      items.add(AddedItem(kind: kind, title: title.trim(), when: when));
    }
    return items;
  }

  /// The created record inside a tool result, wherever the tool put it.
  static Map<Object?, Object?>? _itemMap(Object? raw) {
    if (raw is! Map) return null;
    if (raw['title'] is String) return raw;
    for (final key in const ['task', 'reminder', 'event', 'item', 'data']) {
      final inner = raw[key];
      if (inner is Map) {
        final found = _itemMap(inner);
        if (found != null) return found;
      }
    }
    return null;
  }
}

/// Tells the user what Exa did and asked on its own: a notification with
/// "Talk about it", and - when the user switched it on and it is not quiet
/// hours - the voice session itself, over the lock screen, saying it aloud.
class FollowUpAnnouncer {
  FollowUpAnnouncer({
    required this.settings,
    this.voice = const ExaVoice(),
    this.isQuietNow,
  });

  final SettingsRepository settings;
  final ExaVoice voice;
  final Future<bool> Function()? isQuietNow;

  static const notifyKey = 'voice_notify_new_items';
  static const announceKey = 'voice_announce_aloud';

  /// Notifications about what Exa added: on unless switched off.
  Future<bool> notifyEnabled() async =>
      (await settings.getValue(notifyKey)) != 'false';

  /// Speaking them aloud: off unless switched on - a phone that starts
  /// talking by itself has to be something the user asked for.
  Future<bool> announceEnabled() async =>
      (await settings.getValue(announceKey)) == 'true';

  static const _notificationBase = 7600;

  /// What happened to the last announcement, for the settings screen:
  /// `<iso time>|<outcome>|<title>`. "Say it out loud did nothing" has to be
  /// answerable without a debugger.
  static const lastAnnouncementKey = 'voice_last_announcement';

  /// Announces one run's outcome. Returns whether anything was posted.
  Future<bool> announce({
    required List<AddedItem> added,
    required List<FollowUpQuestion> questions,
    required String source,
  }) async {
    if (added.isEmpty && questions.isEmpty) return false;
    final message = compose(added: added, questions: questions, source: source);
    if (!await notifyEnabled()) {
      await _record('notifications_off', message.title);
      return false;
    }
    final aloud = await announceEnabled();
    var quiet = false;
    if (aloud) {
      try {
        quiet = await isQuietNow?.call() ?? false;
      } catch (_) {
        quiet = false;
      }
    }
    final id = _notificationBase +
        (DateTime.now().millisecondsSinceEpoch ~/ 1000) % 300;
    final delivered = await voice.postFollowUp(
      notificationId: id,
      title: message.title,
      body: message.body,
      prompt: message.prompt,
      speak: message.speak,
      followUpId: questions.isEmpty ? null : questions.first.id,
      ring: aloud && !quiet,
    );
    await _record(
      delivered == null
          ? 'unavailable'
          : quiet
              ? 'quiet_hours'
              : !aloud
                  ? 'notified'
                  : delivered,
      message.title,
    );
    return delivered != null;
  }

  Future<void> _record(String outcome, String title) async {
    try {
      await settings.setValue(lastAnnouncementKey,
          '${DateTime.now().toIso8601String()}|$outcome|$title');
    } catch (_) {
      // A diagnostic that cannot be written must not cost the announcement.
    }
  }

  /// The last announcement: when, how it went out, and what it was about.
  Future<({DateTime at, String outcome, String title})?> lastAnnouncement()
      async {
    final raw = await settings.getValue(lastAnnouncementKey);
    if (raw == null) return null;
    final parts = raw.split('|');
    if (parts.length < 3) return null;
    final at = DateTime.tryParse(parts[0]);
    if (at == null) return null;
    return (at: at, outcome: parts[1], title: parts.sublist(2).join('|'));
  }

  /// A sample announcement, exactly as a real one goes out, so the user can
  /// hear what "say it out loud" does without waiting for a digest.
  Future<String?> test() async {
    final message = compose(
      added: const [
        AddedItem(kind: 'task', title: 'Try out Exa\'s announcements'),
      ],
      questions: const [],
      source: 'a test',
    );
    final aloud = await announceEnabled();
    final delivered = await voice.postFollowUp(
      notificationId: _notificationBase + 299,
      title: message.title,
      body: message.body,
      prompt: message.prompt,
      speak: message.speak,
      ring: aloud,
    );
    await _record(delivered ?? 'unavailable', '${message.title} (test)');
    return delivered;
  }

  /// The words of one announcement. Pure, so they can be tested.
  static ({String title, String body, String speak, String prompt}) compose({
    required List<AddedItem> added,
    required List<FollowUpQuestion> questions,
    required String source,
  }) {
    final counts = <String, int>{};
    for (final item in added) {
      counts[item.kind] = (counts[item.kind] ?? 0) + 1;
    }
    String plural(String kind, int n) =>
        n == 1 ? (kind == 'event' ? 'an event' : 'a $kind') : '$n ${kind}s';
    final addedPhrase = [
      for (final entry in counts.entries) plural(entry.key, entry.value),
    ].join(' and ');

    final title = added.isEmpty
        ? (questions.length == 1
            ? 'Exa has a question'
            : 'Exa has ${questions.length} questions')
        : questions.isEmpty
            ? 'Exa added $addedPhrase'
            : 'Exa added $addedPhrase and has a question';

    final body = [
      for (final item in added) item.line,
      for (final q in questions) '${q.title}: ${q.question}',
    ].join('\n');

    final spokenAdded = added.isEmpty
        ? ''
        : added.length <= 3
            ? 'I added ${_list([for (final i in added) i.spoken])}.'
            : 'I added $addedPhrase from $source.';
    final spokenQuestion = questions.isEmpty
        ? (added.isEmpty ? '' : ' Is there anything you want me to change?')
        : ' ${questions.first.question}';
    final speak = '$spokenAdded$spokenQuestion'.trim();

    final prompt = StringBuffer()
      ..writeln('[Follow-up from $source - written by the app, not the '
          'user.] You are now talking with the user by voice.');
    if (added.isNotEmpty) {
      prompt.writeln('You added on your own:');
      for (final item in added) {
        prompt.writeln('- ${item.line}');
      }
    }
    if (questions.isNotEmpty) {
      prompt.writeln('Open questions you flagged:');
      for (final q in questions) {
        prompt.writeln('- [${q.id}] ${q.title}: ${q.question}'
            '${q.details.isEmpty ? '' : ' (${q.details})'}');
      }
    }
    prompt.writeln('You already said aloud: "$speak". Wait for their '
        'answer; then make the change they ask for with your tools, ask the '
        'next most useful question (a missing date or time, a reminder '
        'before an event, who is involved), one at a time, and when a '
        'flagged question is settled call resolve_follow_up with its id. '
        'Keep every reply to a sentence or two - it is read aloud.');
    return (title: title, body: body, speak: speak, prompt: prompt.toString());
  }

  static String _list(List<String> parts) {
    if (parts.length <= 1) return parts.join();
    return '${parts.sublist(0, parts.length - 1).join(', ')} and ${parts.last}';
  }
}
