/// Catches a final response that states a date the evidence does not
/// contain.
///
/// The failure this exists for: a model whose internal sense of "today" is
/// its training cutoff decides that a correctly stored 2026 date is a
/// mistake, and helpfully "corrects" it in prose - announcing tasks as due
/// in 2024 while the database (rightly) holds 2026. The tool calls are
/// perfect; only the sentence describing them is wrong, which is the worst
/// version of this bug because the user has no reason to distrust it.
///
/// The check is deliberately narrow. It only looks at dates carrying an
/// explicit year, because those are the ones a model invents wholesale;
/// "due Friday" or "next week" are left alone. Every date the evidence
/// mentions anywhere - tool results, email bodies, the user's own request -
/// counts as supported, so restating something the user said is never
/// flagged.
class DateConsistency {
  const DateConsistency._();

  static const _months = {
    'january': 1,
    'february': 2,
    'march': 3,
    'april': 4,
    'may': 5,
    'june': 6,
    'july': 7,
    'august': 8,
    'september': 9,
    'october': 10,
    'november': 11,
    'december': 12,
  };

  /// `August 1, 2024` / `1 August 2024` / `2024-08-01`, in any casing.
  static final _monthNames = _months.keys.join('|');
  static final _monthFirst = RegExp(
      '\\b($_monthNames)\\s+(\\d{1,2})(?:st|nd|rd|th)?,?\\s+(\\d{4})\\b',
      caseSensitive: false);
  static final _dayFirst = RegExp(
      '\\b(\\d{1,2})(?:st|nd|rd|th)?\\s+($_monthNames),?\\s+(\\d{4})\\b',
      caseSensitive: false);
  /// `2026-08-01`, and the date half of `2026-08-01T09:00:00`.
  ///
  /// The trailing guard is `(?!\d)` rather than `\b` on purpose. `\b` requires
  /// a non-word character after the day, and `T` is a word character - so a
  /// full ISO *timestamp* matched nothing, and every scheduling field Exa
  /// stores is a timestamp. The evidence for "due August 1, 2026" is usually
  /// `due_at: 2026-08-01T23:59:00`, which meant a correctly stated date could
  /// be reported as invented: a critical verification issue, a wasted repair
  /// round trip, and now a discarded job briefing. `(?!\d)` still refuses to
  /// take `2026-08-011` as the 1st.
  static final _iso = RegExp(r'\b(\d{4})-(\d{2})-(\d{2})(?!\d)');

  /// Every explicit calendar date in [text], normalized to `yyyy-mm-dd` so
  /// the same day written three different ways compares equal.
  static Set<String> extractDates(String text) {
    final found = <String>{};
    void add(int year, int month, int day) {
      if (month < 1 || month > 12 || day < 1 || day > 31) return;
      found.add('$year-${month.toString().padLeft(2, '0')}-'
          '${day.toString().padLeft(2, '0')}');
    }

    for (final match in _monthFirst.allMatches(text)) {
      add(int.parse(match.group(3)!), _months[match.group(1)!.toLowerCase()]!,
          int.parse(match.group(2)!));
    }
    for (final match in _dayFirst.allMatches(text)) {
      add(int.parse(match.group(3)!), _months[match.group(2)!.toLowerCase()]!,
          int.parse(match.group(1)!));
    }
    for (final match in _iso.allMatches(text)) {
      add(int.parse(match.group(1)!), int.parse(match.group(2)!),
          int.parse(match.group(3)!));
    }
    return found;
  }

  /// Dates [message] asserts that appear nowhere in [evidence].
  ///
  /// [evidence] should be everything the turn actually knows: the execution
  /// report, the user's request, and any tool output. A date absent from all
  /// of it was invented.
  static List<String> unsupportedDates({
    required String message,
    required String evidence,
  }) {
    final stated = extractDates(message);
    if (stated.isEmpty) return const [];
    final supported = extractDates(evidence);
    final unsupported = stated.difference(supported).toList()..sort();
    return unsupported;
  }
}
