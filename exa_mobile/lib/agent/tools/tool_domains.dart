/// Named groups of related agent tools.
///
/// The registry holds ~46 tools; sending every definition on every request
/// wastes tokens and dilutes the model's attention. Each turn instead runs a
/// two-stage process: a small routing call ([DomainRouter]) picks the domains
/// the request needs, and only those domains' tools (plus the always-on
/// [core] domain) are exposed to the agent loop. The `expand_tools` meta-tool
/// lets the model pull in another domain mid-turn if routing was too narrow.
class ToolDomains {
  ToolDomains._();

  /// Always exposed regardless of routing: cross-domain search and screen
  /// navigation are useful for nearly every request.
  static const String core = 'core';

  static const String tasks = 'tasks';
  static const String reminders = 'reminders';
  static const String calendar = 'calendar';
  static const String email = 'email';
  static const String messages = 'messages';
  static const String files = 'files';
  static const String browser = 'browser';
  static const String backgroundJobs = 'background_jobs';
  static const String dynamicUi = 'dynamic_ui';
  static const String behaviorRules = 'behavior_rules';
  static const String phone = 'phone';

  /// Reading and driving other apps on the phone through the accessibility
  /// service (this build's OS-level device control).
  static const String screen = 'screen';

  /// Domains the router (and `expand_tools`) may select, with the one-line
  /// descriptions the model sees when choosing.
  static const Map<String, String> selectable = {
    tasks: 'create, list, update, complete, or delete to-do tasks',
    reminders:
        'timed reminders that notify the user (create, update, cancel, list)',
    calendar: "schedule events, the user's day or agenda, the phone "
        'calendar, and the daily planning board (setting aside time to do a '
        'task, planning or rearranging a day)',
    email: 'sync, read, digest, or send email',
    messages: 'chat messages from WhatsApp and other messaging apps - '
        'reading a chat, digesting new messages, or replying to one',
    files: 'stored files - keeping a document or generated digest for '
        'later, listing, reading, deleting',
    browser: 'pages and tabs open in the in-app browser, or pages the user '
        'shared to Exa',
    backgroundJobs:
        'recurring background jobs (daily summaries, reviews, syncs)',
    dynamicUi: 'build custom app screens, views, and dashboards - and '
        'whole small features with their own data (a note-taking app, an '
        'expense log, a tracker), via collections and records',
    behaviorRules:
        "the assistant's own saved rules, preferences, and routines",
    phone: 'the phone itself - texting (SMS) someone, calling someone, '
        'sending a WhatsApp message to a person, or looking up a contact\'s '
        'number',
    screen: 'read and operate any other app on the phone (Outlook, WhatsApp, '
        'a banking app): see what is on screen, tap, type, swipe, open an '
        'app, or take a screenshot',
  };

  /// One domain per line, `name: description` — used in the router prompt
  /// and the `expand_tools` description.
  static String describeAll() =>
      selectable.entries.map((e) => '${e.key}: ${e.value}').join('\n');
}
