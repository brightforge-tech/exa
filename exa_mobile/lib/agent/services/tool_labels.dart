/// Human wording for tool names.
///
/// Tool names are identifiers: `sync_messages`, `read_message_context`,
/// `mark_message_digested`. They are right for the model and the registry
/// and wrong for anything a person reads - yet they reached the user on
/// several paths: contract actions (which the router labels with tool
/// names) quoted in the synthesis prompt, the report builder's
/// "`sync_messages` completed" fallback, the `Done - I used: …` fallback,
/// the permission-denied list, and the pills under a chat bubble. One table
/// here, so every surface says the same thing.
///
/// Two forms per tool: [describe] is what the tool does, as an infinitive
/// phrase that reads after "could not" or "tried to" ("check for new chat
/// messages"); [pill] is the short past-tense label a chip can hold
/// ("Checked chats").
class ToolLabels {
  const ToolLabels._();

  /// (pill, description) per tool. Ordered as the registry declares them.
  static const _labels = <String, (String, String)>{
    'search': ('Searched', 'search the app'),
    'store_file': ('Stored file', 'store a file'),
    'write_file': ('Wrote file', 'write a file'),
    'list_files': ('Listed files', 'list files'),
    'read_file': ('Read file', 'read a file'),
    'delete_file': ('Deleted file', 'delete a file'),
    'sync_messages': ('Checked chats', 'check for new chat messages'),
    'list_chats': ('Listed chats', 'list chats'),
    'read_message_context': ('Read messages', 'read new chat messages'),
    'read_chat': ('Read chat', 'read a chat'),
    'mark_message_digested':
        ('Marked chats handled', 'mark chat messages as handled'),
    'reply_to_chat': ('Replied in chat', 'reply in a chat'),
    'find_contact': ('Looked up contact', 'look up a contact'),
    'send_sms': ('Sent text', 'send a text message'),
    'place_call': ('Called', 'make a phone call'),
    'send_whatsapp': ('Sent WhatsApp', 'send a WhatsApp message'),
    'sync_emails': ('Checked mail', 'check for new mail'),
    'list_mail_accounts': ('Listed mail accounts', 'list mail accounts'),
    'send_email': ('Sent email', 'send an email'),
    'list_day_plan': ('Viewed day plan', 'look at the day plan'),
    'plan_day_item': ('Planned item', 'add an item to the day plan'),
    'move_day_plan_item': ('Moved plan item', 'move a day-plan item'),
    'unplan_day_item': ('Unplanned item', 'take an item off the day plan'),
    'sync_device_calendar': ('Synced calendar', 'import the phone calendar'),
    'add_to_phone_calendar':
        ('Queued calendar event', 'queue an event for the phone calendar'),
    'read_email_context': ('Read mail', 'read new emails'),
    'mark_email_digested': ('Marked mail handled', 'mark emails as handled'),
    'delete_email': ('Deleted email', 'delete an email'),
    'create_scheduled_job': ('Scheduled job', 'schedule a recurring job'),
    'list_scheduled_jobs': ('Listed jobs', 'list scheduled jobs'),
    'pause_scheduled_job': ('Paused job', 'pause a scheduled job'),
    'resume_scheduled_job': ('Resumed job', 'resume a scheduled job'),
    'mute_scheduled_job': ('Muted job', 'mute a scheduled job'),
    'run_scheduled_job_now': ('Ran job', 'run a scheduled job now'),
    'delete_scheduled_job': ('Deleted job', 'delete a scheduled job'),
    'list_browser_tabs': ('Listed tabs', 'list browser tabs'),
    'read_current_browser_page':
        ('Read page', 'read the current browser page'),
    'read_browser_context': ('Read pages', 'read browser pages'),
    'summarize_browser_page': ('Summarized page', 'summarize a browser page'),
    'create_task': ('Created task', 'create a task'),
    'update_task': ('Updated task', 'update a task'),
    'complete_task': ('Completed task', 'mark a task done'),
    'delete_task': ('Deleted task', 'delete a task'),
    'list_tasks': ('Viewed tasks', 'look at the task list'),
    'create_reminder': ('Set reminder', 'set a reminder'),
    'update_reminder': ('Updated reminder', 'update a reminder'),
    'cancel_reminder': ('Cancelled reminder', 'cancel a reminder'),
    'list_reminders': ('Viewed reminders', 'look at the reminders'),
    'create_schedule_event': ('Added event', 'add an event to the schedule'),
    'update_schedule_event': ('Updated event', 'update a schedule event'),
    'list_schedule': ('Viewed schedule', 'look at the schedule'),
    'delete_schedule_event': ('Deleted event', 'delete a schedule event'),
    'open_screen': ('Opened screen', 'open a screen'),
    'create_dynamic_screen': ('Created screen', 'create a custom screen'),
    'delete_dynamic_screen': ('Deleted screen', 'delete a custom screen'),
    'save_screen': ('Saved screen', 'save a screen'),
    'define_collection': ('Defined collection', 'define a data collection'),
    'add_record': ('Added record', 'add a record'),
    'update_record': ('Updated record', 'update a record'),
    'delete_record': ('Deleted record', 'delete a record'),
    'list_collections': ('Listed collections', 'list collections'),
    'list_records': ('Listed records', 'list records'),
    'propose_behavior_change':
        ('Proposed rule', 'propose a behavior rule change'),
    'list_agent_behaviors': ('Listed rules', 'list behavior rules'),
    'pause_behavior': ('Paused rule', 'pause a behavior rule'),
    'activate_behavior': ('Activated rule', 'activate a behavior rule'),
    'update_behavior': ('Updated rule', 'update a behavior rule'),
    'rollback_behavior_version':
        ('Rolled back rule', 'roll back a behavior rule'),
    'evaluate_behavior': ('Evaluated rule', 'evaluate a behavior rule'),
    'expand_tools': ('Loaded tools', 'load more tools'),
  };

  /// Past-tense verbs for tools the table does not know. A new tool gets a
  /// readable chip on day one instead of its identifier.
  static const _pastTense = {
    'create': 'Created',
    'update': 'Updated',
    'complete': 'Completed',
    'delete': 'Deleted',
    'cancel': 'Cancelled',
    'list': 'Listed',
    'read': 'Read',
    'mark': 'Marked',
    'store': 'Stored',
    'save': 'Saved',
    'pause': 'Paused',
    'resume': 'Resumed',
    'run': 'Ran',
    'propose': 'Proposed',
    'rollback': 'Rolled back',
    'activate': 'Activated',
    'evaluate': 'Evaluated',
    'summarize': 'Summarized',
    'sync': 'Synced',
    'send': 'Sent',
    'open': 'Opened',
    'add': 'Added',
    'move': 'Moved',
    'plan': 'Planned',
    'unplan': 'Unplanned',
    'reply': 'Replied',
    'define': 'Defined',
    'mute': 'Muted',
    'search': 'Searched',
    'write': 'Wrote',
    'expand': 'Loaded',
  };

  /// Whether [text] is a tool-style identifier rather than a phrase: all
  /// lowercase word characters joined by underscores, no spaces.
  static bool isIdentifier(String text) =>
      RegExp(r'^[a-z][a-z0-9]*(_[a-z0-9]+)*$').hasMatch(text.trim());

  /// What the tool does, as a lowercase infinitive phrase: "check for new
  /// chat messages". Unknown tools fall back to their name with the
  /// underscores read as spaces, which is at least pronounceable.
  static String describe(String toolName) {
    final known = _labels[toolName];
    if (known != null) return known.$2;
    return _words(toolName);
  }

  /// Short past-tense chip label: "Checked chats". Unknown tools get their
  /// verb conjugated and the rest of the name read as words.
  static String pill(String toolName) {
    final known = _labels[toolName];
    if (known != null) return known.$1;
    final parts = toolName.split('_').where((p) => p.isNotEmpty).toList();
    if (parts.isEmpty) return toolName;
    final verb = _pastTense[parts.first];
    if (verb == null) return _capitalize(_words(toolName));
    final rest = parts.skip(1).join(' ');
    return rest.isEmpty ? verb : '$verb $rest';
  }

  /// A contract action label made readable. The router labels actions with
  /// tool names ("mark_message_digested"); a skill step or a human already
  /// wrote a phrase ("Read undigested email context"), which passes through.
  static String humanizeAction(String description) {
    final trimmed = description.trim();
    if (trimmed.isEmpty) return trimmed;
    return isIdentifier(trimmed) ? describe(trimmed) : trimmed;
  }

  static String _words(String toolName) =>
      toolName.split('_').where((p) => p.isNotEmpty).join(' ');

  static String _capitalize(String text) =>
      text.isEmpty ? text : text[0].toUpperCase() + text.substring(1);
}
