import 'action_lexicon.dart';
import '../models/turn_contract.dart';

/// What a request asked for, compared against what the contract planned.
///
/// [ContractActionResolver] catches an action the turn planned and has no
/// evidence for. Nothing catches the opposite: a request the router never
/// decomposed. "Create a task for the invoice and email John about it" routed
/// as one action narrows the contract before any work starts, and every check
/// downstream then agrees with the narrowed version - the resolver finds
/// evidence for the one action it was given, verification passes, and contract
/// coverage reads 100% for a request half of which was never considered.
///
/// This is deliberately **diagnostic only**. It reports a shortfall so the
/// false-positive rate can be measured against real traffic before anything
/// depends on it; a clause splitter that quietly inflated escalation or
/// blocked turns while getting English wrong would be worse than the gap it
/// closes.
class RequestDecomposition {
  const RequestDecomposition({
    required this.clauses,
    required this.unaccountedClauses,
  });

  static const none = RequestDecomposition(clauses: [], unaccountedClauses: []);

  /// Clauses of the request that read as asking for something.
  final List<String> clauses;

  /// Those no planned action appears to cover.
  final List<String> unaccountedClauses;

  bool get isUnderDecomposed => unaccountedClauses.isNotEmpty;

  Map<String, Object?> toJson() => {
        'clauses': clauses.length,
        'unaccounted': unaccountedClauses,
      };

  /// Splits [request] into clauses, keeps the ones that ask for work, and
  /// reports those whose words appear in no planned action.
  ///
  /// [knownToolNames] contributes the registry's own verbs, so a tool added
  /// later is recognized without editing a list here.
  static RequestDecomposition analyze({
    required String request,
    required List<ContractAction> actions,
    Set<String> knownToolNames = const {},
  }) {
    final imperatives = <String>[];
    final toolVerbs = <String>{
      for (final name in knownToolNames) ?ActionLexicon.verbOf(name),
    };
    for (final clause in splitClauses(request)) {
      final ordered = orderedTokens(clause);
      if (ordered.isEmpty) continue;
      if (!ActionLexicon.looksImperative(ordered, extraVerbs: toolVerbs)) {
        continue;
      }
      imperatives.add(clause);
    }
    // A single-clause request cannot be under-decomposed, and a turn with no
    // planned actions at all is a routing failure already counted elsewhere -
    // reporting it here as well would drown the signal this exists for.
    if (imperatives.length < 2 || actions.isEmpty) {
      return RequestDecomposition(
          clauses: imperatives, unaccountedClauses: const []);
    }

    final actionTokens = [
      for (final action in actions) ActionLexicon.tokens(action.description),
    ];
    final unaccounted = <String>[];
    for (final clause in imperatives) {
      final clauseTokens = ActionLexicon.tokens(clause);
      final covered = actionTokens.any((tokens) =>
          tokens.isNotEmpty && tokens.intersection(clauseTokens).isNotEmpty);
      if (!covered) unaccounted.add(clause);
    }
    return RequestDecomposition(
      clauses: imperatives,
      unaccountedClauses: unaccounted,
    );
  }

  /// Breaks a request on the joins people actually use between two asks.
  ///
  /// Kept crude on purpose. Note that dictated input arrives with no
  /// punctuation at all (see the transcribe feature), so sentence splitting
  /// carries most of the weight on typed requests and almost none on spoken
  /// ones - which is a reason to read this signal by input source rather than
  /// in aggregate.
  static List<String> splitClauses(String request) {
    final parts = request.split(RegExp(
      r'(?:[.;!?\n]+)|(?:,?\s+\b(?:and then|and also|and|then|also|plus)\b\s+)',
      caseSensitive: false,
    ));
    return [
      for (final part in parts)
        if (part.trim().isNotEmpty) part.trim(),
    ];
  }

  /// Content tokens of a clause **in order**, so "leads with a verb" is
  /// answerable. [ActionLexicon.tokens] returns an unordered set.
  static List<String> orderedTokens(String clause) => clause
      .toLowerCase()
      .split(RegExp(r'[^a-z0-9]+'))
      .where((token) =>
          token.length > 2 && !ActionLexicon.stopwords.contains(token))
      .map(ActionLexicon.singular)
      .toList();
}
