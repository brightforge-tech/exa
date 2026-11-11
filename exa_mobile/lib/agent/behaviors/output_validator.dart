import 'dart:convert';

import '../../data/models/agent_behavior.dart';

/// A measurable requirement on the final message, taken from a behavior
/// rule's params. These are checked in code: asking a model whether it
/// obeyed "at most two bullets" costs a round trip and is less reliable
/// than counting the bullets.
class OutputConstraint {
  const OutputConstraint({
    required this.kind,
    required this.value,
    required this.behaviorId,
    required this.description,
  });

  /// One of: max_words, max_sentences, max_bullets, exact_bullets,
  /// require_json, no_markdown_tables, require_heading.
  final String kind;
  final Object? value;
  final String behaviorId;

  /// Human-readable requirement, reused in the repair prompt.
  final String description;

  static const kinds = {
    'max_words',
    'max_sentences',
    'max_bullets',
    'exact_bullets',
    'require_json',
    'no_markdown_tables',
    'require_heading',
  };

  /// Reads constraints out of a rule's params. Unknown keys are ignored
  /// here (they may be for another consumer) - only the measurable ones
  /// become constraints.
  static List<OutputConstraint> fromBehavior(AgentBehavior behavior) {
    final constraints = <OutputConstraint>[];
    for (final entry in behavior.params.entries) {
      if (!kinds.contains(entry.key)) continue;
      final value = entry.value;
      final description = switch (entry.key) {
        'max_words' => 'at most $value words',
        'max_sentences' => 'at most $value sentences',
        'max_bullets' => 'at most $value bullet points',
        'exact_bullets' => 'exactly $value bullet points',
        'require_json' => 'a valid JSON object only',
        'no_markdown_tables' => 'no markdown tables',
        'require_heading' => 'a heading line',
        _ => entry.key,
      };
      if ((entry.key == 'require_json' ||
              entry.key == 'no_markdown_tables' ||
              entry.key == 'require_heading') &&
          value != true) {
        continue;
      }
      constraints.add(OutputConstraint(
        kind: entry.key,
        value: value,
        behaviorId: behavior.id,
        description: description,
      ));
    }
    return constraints;
  }
}

class OutputFailure {
  const OutputFailure(this.constraint, this.detail);

  final OutputConstraint constraint;
  final String detail;

  @override
  String toString() => '${constraint.description} (found $detail)';
}

class OutputValidation {
  const OutputValidation(this.failures, this.repairedText);

  final List<OutputFailure> failures;

  /// Set when the text could be corrected in code, making a repair call
  /// unnecessary.
  final String? repairedText;

  bool get isValid => failures.isEmpty;
  bool get wasRepairedLocally => repairedText != null;
}

/// Checks a final message against the measurable constraints, and fixes
/// what can be fixed without a model.
///
/// Only failures this cannot repair deterministically justify spending a
/// repair round trip.
class OutputValidator {
  const OutputValidator();

  OutputValidation validate(
      String text, List<OutputConstraint> constraints) {
    if (constraints.isEmpty || text.trim().isEmpty) {
      return const OutputValidation([], null);
    }
    var working = text;
    final failures = <OutputFailure>[];

    for (final constraint in constraints) {
      switch (constraint.kind) {
        case 'max_bullets':
        case 'exact_bullets':
          final limit = _intOf(constraint.value);
          if (limit == null) break;
          final bullets = _bulletLines(working);
          if (constraint.kind == 'max_bullets' && bullets.length > limit) {
            // Deterministically fixable: keep the first N bullets.
            working = _keepBullets(working, limit);
          } else if (constraint.kind == 'exact_bullets' &&
              bullets.length != limit) {
            if (bullets.length > limit) {
              working = _keepBullets(working, limit);
            } else {
              failures.add(OutputFailure(
                  constraint, '${bullets.length} bullet points'));
            }
          }
        case 'max_words':
          final limit = _intOf(constraint.value);
          if (limit == null) break;
          final words = _words(working);
          if (words > limit) {
            // Truncating prose changes meaning, so this is a real failure
            // the model must fix - not something to chop mid-sentence.
            failures.add(OutputFailure(constraint, '$words words'));
          }
        case 'max_sentences':
          final limit = _intOf(constraint.value);
          if (limit == null) break;
          final sentences = _sentences(working);
          if (sentences.length > limit) {
            failures.add(
                OutputFailure(constraint, '${sentences.length} sentences'));
          }
        case 'no_markdown_tables':
          if (_hasMarkdownTable(working)) {
            working = _stripTables(working);
          }
        case 'require_heading':
          if (!_hasHeading(working)) {
            failures.add(const OutputFailure(
                OutputConstraint(
                  kind: 'require_heading',
                  value: true,
                  behaviorId: '',
                  description: 'a heading line',
                ),
                'no heading'));
          }
        case 'require_json':
          if (!_isJsonObject(working)) {
            final extracted = _extractJsonObject(working);
            if (extracted != null) {
              working = extracted;
            } else {
              failures.add(OutputFailure(constraint, 'prose, not JSON'));
            }
          }
      }
    }

    return OutputValidation(
      failures,
      working == text ? null : working,
    );
  }

  static int? _intOf(Object? value) =>
      value is int ? value : int.tryParse('${value ?? ''}');

  static List<String> _bulletLines(String text) => text
      .split('\n')
      .where((line) =>
          RegExp(r'^\s*([-*•]|\d+[.)])\s+').hasMatch(line))
      .toList();

  static String _keepBullets(String text, int limit) {
    final lines = text.split('\n');
    final kept = <String>[];
    var seen = 0;
    for (final line in lines) {
      final isBullet =
          RegExp(r'^\s*([-*•]|\d+[.)])\s+').hasMatch(line);
      if (isBullet) {
        seen++;
        if (seen > limit) continue;
      }
      kept.add(line);
    }
    return kept.join('\n').trimRight();
  }

  static int _words(String text) =>
      text.trim().split(RegExp(r'\s+')).where((w) => w.isNotEmpty).length;

  static List<String> _sentences(String text) => text
      .split(RegExp(r'(?<=[.!?])\s+'))
      .map((s) => s.trim())
      .where((s) => s.isNotEmpty)
      .toList();

  static bool _hasMarkdownTable(String text) =>
      RegExp(r'^\s*\|.*\|\s*$', multiLine: true).hasMatch(text);

  static String _stripTables(String text) => text
      .split('\n')
      .where((line) => !RegExp(r'^\s*\|.*\|\s*$').hasMatch(line))
      .join('\n')
      .replaceAll(RegExp(r'\n{3,}'), '\n\n')
      .trim();

  static bool _hasHeading(String text) =>
      RegExp(r'^\s*#{1,6}\s+\S', multiLine: true).hasMatch(text) ||
      RegExp(r'^\s*\*\*[^*]+\*\*\s*$', multiLine: true).hasMatch(text);

  static bool _isJsonObject(String text) {
    try {
      return jsonDecode(text.trim()) is Map;
    } catch (_) {
      return false;
    }
  }

  static String? _extractJsonObject(String text) {
    final start = text.indexOf('{');
    final end = text.lastIndexOf('}');
    if (start < 0 || end <= start) return null;
    final candidate = text.substring(start, end + 1);
    return _isJsonObject(candidate) ? candidate : null;
  }
}
