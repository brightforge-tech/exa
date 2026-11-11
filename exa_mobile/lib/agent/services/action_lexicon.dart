/// The shared vocabulary for reasoning about actions in text.
///
/// Two places need the same answers and must not drift apart:
/// [ContractActionResolver], deciding whether a tool call is evidence for a
/// contract action, and [RequestDecomposition], deciding whether a clause of
/// the request asks for something. Two private copies of "what counts as a
/// verb" would diverge the first time either was tuned.
class ActionLexicon {
  const ActionLexicon._();

  static const stopwords = {
    'the', 'a', 'an', 'and', 'or', 'of', 'to', 'for', 'from', 'with',
    'my', 'me', 'in', 'on', 'all', 'any', 'new', 'user', 'users',
  };

  /// Meaningful, singular-normalized tokens of a label or a phrase.
  static Set<String> tokens(String text) => text
      .toLowerCase()
      .split(RegExp(r'[^a-z0-9]+'))
      .where((token) => token.length > 2 && !stopwords.contains(token))
      .map(singular)
      .toSet();

  static String singular(String token) =>
      token.length > 3 && token.endsWith('s')
          ? token.substring(0, token.length - 1)
          : token;

  /// The leading segment of a `verb_noun` tool name, normalized the way
  /// [tokens] normalizes. Null when it carries no meaning alone.
  static String? verbOf(String toolName) {
    for (final segment in toolName.toLowerCase().split(RegExp(r'[^a-z0-9]+'))) {
      if (segment.isEmpty) continue;
      return segment.length > 2 ? singular(segment) : null;
    }
    return null;
  }

  /// Whether a successful call to [toolName] is evidence for work described by
  /// [descriptionTokens].
  ///
  /// Tool names are `verb_noun`, and the verb is what decides whether the
  /// thing happened - `send_email`, `sync_emails` and `read_email_context` all
  /// share `email` and mean three different things. So the verb must appear,
  /// plus one further token agreeing with it.
  static bool toolMatches(Set<String> descriptionTokens, String toolName) {
    final nameTokens = tokens(toolName);
    if (nameTokens.isEmpty) return false;
    final overlap = descriptionTokens.intersection(nameTokens);
    final verb = verbOf(toolName);
    // A verb too short to survive tokenization cannot be gated on; require
    // real overlap instead of a single shared token.
    if (verb == null || !nameTokens.contains(verb)) return overlap.length >= 2;
    if (!descriptionTokens.contains(verb)) return false;
    // A one-word tool (`search`) is fully identified by its verb.
    return nameTokens.length == 1 || overlap.length >= 2;
  }

  /// Verbs that make a clause a request for work.
  ///
  /// Tool verbs alone are too narrow: `send_email` contributes `send`, but
  /// people write "email John", and a clause that asks for something and is
  /// not recognized is a clause the decomposition check cannot see. These are
  /// the everyday imperatives, which is enough for a diagnostic.
  static const requestVerbs = {
    'add', 'make', 'create', 'set', 'put',
    'remind', 'schedule', 'book', 'move', 'reschedule', 'change', 'update',
    'delete', 'remove', 'cancel', 'clear', 'archive',
    'send', 'email', 'reply', 'respond', 'forward', 'draft', 'message',
    'find', 'search', 'look', 'show', 'open', 'list', 'check', 'pull',
    'read', 'review', 'summarize', 'summarise', 'digest', 'analyze',
    'analyse', 'compare', 'explain',
    'save', 'store', 'write', 'file', 'note',
    'mark', 'complete', 'finish', 'flag', 'tick',
    'sync', 'import', 'export', 'refresh',
    'tell', 'give', 'let',
  };

  /// Whether [clauseTokens] opens with something that asks for work.
  ///
  /// Only the first few content tokens count: "…and it should be done by
  /// Friday" mentions no verb worth acting on, while "email John about it"
  /// leads with one. Looking anywhere in the clause would count every
  /// trailing qualifier as another request.
  static bool looksImperative(
    List<String> clauseTokens, {
    Set<String> extraVerbs = const {},
  }) {
    for (final token in clauseTokens.take(3)) {
      if (requestVerbs.contains(token) || extraVerbs.contains(token)) {
        return true;
      }
    }
    return false;
  }
}
