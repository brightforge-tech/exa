/// How Exa talks to the person using it.
///
/// The synthesis and repair calls are the two places a model writes the
/// message the user actually reads, and both get their material in system
/// vocabulary: required outputs as wire names, contract actions that are
/// literally tool names, and the execution report as JSON. Left to itself a
/// model writes that vocabulary straight back - "Confirmation: sync_messages
/// completed, and two read_message_context operations are recorded" - which
/// is a status report for the developer, not a message to the user. These
/// rules are appended to both prompts so the voice is decided once.
class ResponseVoice {
  const ResponseVoice._();

  /// Vocabulary that belongs to the machinery and never to the message.
  /// Tests use it to check that prompts and rendered fallbacks do not leak
  /// it; it is deliberately short and literal.
  static const internalTerms = [
    'execution report',
    'action phase',
    'included_outputs',
    'includes_failure_report',
    'tools_called',
    'actions_completed',
  ];

  static const rules = '''
How to write the message:
- You are writing to the person who uses this app, on their phone. Write the
  way a capable human assistant would text them: plain everyday words, short
  sentences, lead with the outcome.
- Never mention tool names, function names or internal machinery: no
  "sync_messages", "execution report", "action phase", "contract", "outputs",
  "claims", "batch", "operations", "recorded", ids or JSON field names. Say
  what happened in human terms: "I checked your WhatsApp chats", "I marked
  those emails as handled".
- The required outputs are a checklist for you, not headings. Never write
  labels such as "Confirmation:", "Rundown:", "Task list:" or
  "Failure/limitation:". Cover each item in natural prose.
- When an item has nothing to report, one short sentence covers it ("Nothing
  new needs a task or a meeting."). Never write an empty labeled section, and
  never explain what information you were or were not given.
- When something could not be done, say what it means for the reader in plain
  words ("I couldn't mark those chats as handled, so I'll look at them again
  next time"), not which internal step failed.
- When nothing needed doing, say so in a line or two and stop.
- Never promise something you will do later ("I'll make sure it's there next
  time", "I'll keep an eye on it"). This message is the end of the work, and
  nothing will act on a promise made in it. Say what was done and what was
  not.''';
}
