import '../entities/entity_repository.dart';
import '../services/context_budget.dart';
import 'memory_repository.dart';
import 'models/agent_memory.dart';

/// The names the user's own requests use, handed to the router.
///
/// The router is where a request is actually interpreted, and it sees the raw
/// text plus the previous turn's entities. So "add it to the Q3 doc" or "chase
/// the Peterson thing" is uninterpretable: the router has no way to know those
/// are things, and routes on the surrounding verbs alone. Retrieval does know,
/// and runs afterwards - by design, since the frame has to define what counts
/// as relevant before anything is fetched.
///
/// This is deliberately **a vocabulary, not evidence**. Only names cross the
/// boundary - never the claim a memory makes, never a value the answer could
/// repeat back. That is what keeps it from being early retrieval wearing a
/// different hat: a name cannot pad the memory block, cannot become an
/// unsourced statement in the response, and cannot be wrong in a way that
/// survives the turn. It only makes a proper noun recognizable as one.
class RequestLexicon {
  const RequestLexicon._();

  /// Names above this length are almost certainly a sentence that slipped
  /// through, not a name.
  static const maxNameLength = 48;

  /// The memory kinds whose subjects are stable enough to be worth naming.
  /// Episodes and temporary state are excluded: a name that stops mattering
  /// tomorrow is noise in a prompt that is re-sent every turn.
  static const _namedKinds = {
    MemoryKind.explicitPreference,
    MemoryKind.projectState,
    MemoryKind.verifiedFact,
  };

  /// Builds the lexicon lines. Never throws: a lexicon that cannot be built is
  /// a slightly less informed router, not a failed turn.
  static Future<List<String>> build({
    required EntityRepository entities,
    required MemoryRepository memories,
    int maxTokens = 150,
  }) async {
    final names = <String, String>{};

    try {
      for (final entity in await entities.listRecent()) {
        final name = entity.displayName.trim();
        if (!_isName(name)) continue;
        names.putIfAbsent(name.toLowerCase(), () => '${entity.type.wireName}: $name');
      }
    } catch (_) {
      // No entity graph yet (fresh install) is the normal state, not an error.
    }

    try {
      for (final memory in await memories.listApplicable()) {
        if (!_namedKinds.contains(memory.kind)) continue;
        for (final name in properNamesIn(memory.content)) {
          names.putIfAbsent(name.toLowerCase(), () => 'known: $name');
        }
      }
    } catch (_) {}

    final lines = names.values.toList();
    if (lines.isEmpty) return const [];
    // Hard budget: this rides on every routing call, and a lexicon that grows
    // with the user's history would quietly become the largest thing in the
    // cheapest prompt in the pipeline.
    return TextBudget.fit(lines.join('\n'), maxTokens).split('\n')
      ..removeWhere((line) => line.trim().isEmpty);
  }

  /// Capitalized runs and quoted phrases in [text] - the shapes a name takes
  /// in a sentence.
  ///
  /// Sentence-initial words are skipped: "Prefers dark mode" would otherwise
  /// contribute "Prefers", and a lexicon of ordinary verbs teaches the router
  /// nothing while costing it tokens.
  static Set<String> properNamesIn(String text) {
    final found = <String>{};
    for (final match in RegExp(r'"([^"]{2,48})"').allMatches(text)) {
      final value = match.group(1)!.trim();
      if (_isName(value)) found.add(value);
    }
    for (final sentence in text.split(RegExp(r'(?<=[.!?])\s+|\n'))) {
      final words = sentence.trim().split(RegExp(r'\s+'));
      final run = <String>[];
      for (var i = 0; i < words.length; i++) {
        final word = words[i].replaceAll(RegExp(r'^[^\w]+|[^\w]+$'), '');
        final capitalized = word.length > 1 &&
            word[0].toUpperCase() == word[0] &&
            word[0].toLowerCase() != word[0];
        // i == 0 is the sentence's own first word, which is capitalized by
        // grammar rather than because it names anything.
        if (capitalized && i > 0) {
          run.add(word);
          continue;
        }
        if (run.isNotEmpty) {
          final value = run.join(' ');
          if (_isName(value)) found.add(value);
          run.clear();
        }
      }
      if (run.isNotEmpty) {
        final value = run.join(' ');
        if (_isName(value)) found.add(value);
      }
    }
    return found;
  }

  static bool _isName(String value) =>
      value.length > 1 &&
      value.length <= maxNameLength &&
      // A name has at most a few words; more than that is a phrase, and a
      // phrase is a claim in disguise.
      value.split(RegExp(r'\s+')).length <= 4;
}
