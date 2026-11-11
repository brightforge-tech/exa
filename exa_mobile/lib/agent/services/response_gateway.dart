import '../behaviors/output_validator.dart';
import 'date_consistency.dart';

/// What the gateway did to one message.
class GatewayOutcome {
  const GatewayOutcome({
    required this.text,
    this.unfixedFailures = const [],
    this.unsupportedDates = const [],
    this.wasClipped = false,
    this.wasRepairedLocally = false,
  });

  /// The text to actually deliver.
  final String text;

  /// Measurable rules the text broke that code could not fix. Only these are
  /// worth a repair round trip; the rest were corrected here.
  final List<OutputFailure> unfixedFailures;

  /// Dates the text states that the evidence does not contain. Empty when no
  /// evidence was supplied - absence of evidence is not evidence of invention.
  final List<String> unsupportedDates;

  final bool wasClipped;
  final bool wasRepairedLocally;

  bool get isClean =>
      unfixedFailures.isEmpty && unsupportedDates.isEmpty;
}

/// The one place a user-visible string passes through on its way out.
///
/// Output discipline used to apply to exactly one path: the synthesized (or
/// deterministically rendered) chat message. Everything else reached the user
/// unchecked -
///
///  * the fast path, where a turn that called no tools forwards the model's
///    own text verbatim. That is the *most common* kind of turn, so the user's
///    formatting rules were being applied to the minority of messages;
///  * the `'Done.'` / `'Done - I used: …'` fallback;
///  * the provider errors (missing API key, unusable provider, vision
///    unavailable, `_friendlyApiError`) and the catch-all;
///  * a background job's rewritten one-line report, which is model-written and
///    was guarded only by a prompt saying "never invent detail";
///  * notification bodies.
///
/// So "responses from every facet line up with the base instructions and the
/// learned behaviour" was true of the chat synthesizer and aspirational
/// everywhere else. This makes it structural: there is one function, and
/// adding a check here reaches every surface at once.
///
/// It deliberately does **not** call a model. Everything here is measurable in
/// code, which is what lets it run on paths where a round trip would be absurd
/// (an API-key error) or impossible (a background isolate with no provider).
class ResponseGateway {
  const ResponseGateway();

  /// Android collapses a notification body well before this; past it the text
  /// is being stored to be truncated by someone else.
  static const notificationBodyChars = 500;

  /// [constraints] are the measurable behaviour rules for this surface.
  ///
  /// [evidence] is everything the turn actually knows - the request, the
  /// execution report, tool output. Supply it and stated dates are checked
  /// against it; leave it null and the date check is skipped entirely. Null is
  /// the honest value on paths with nothing to check against: an empty string
  /// would flag every date as invented.
  ///
  /// [maxChars] clips for surfaces with a hard display limit. Applied last,
  /// since it is a property of where the text is going rather than of the text.
  GatewayOutcome apply(
    String text, {
    List<OutputConstraint> constraints = const [],
    String? evidence,
    int? maxChars,
  }) {
    if (text.trim().isEmpty) {
      return GatewayOutcome(text: text);
    }

    // Markdown first, so everything after it measures the text the user will
    // actually read. Skipped when a rule demands JSON - stripping punctuation
    // out of a JSON document is not a formatting fix, it is corruption.
    final requiresJson =
        constraints.any((constraint) => constraint.kind == 'require_json');
    var working = requiresJson ? text : plainText(text);

    // Then fix what code can fix, so the date check and the clip both see the
    // text the user will actually get.
    final validation = const OutputValidator().validate(working, constraints);
    working = validation.repairedText ?? working;

    final unsupported = evidence == null
        ? const <String>[]
        : DateConsistency.unsupportedDates(
            message: working, evidence: evidence);

    final (clipped, wasClipped) = _clip(working, maxChars);
    return GatewayOutcome(
      text: clipped,
      unfixedFailures: validation.failures,
      unsupportedDates: unsupported,
      wasClipped: wasClipped,
      wasRepairedLocally: validation.wasRepairedLocally,
    );
  }

  /// Strips the markdown syntax nothing here renders.
  ///
  /// Exa's chat bubbles, notification bodies and job briefings are all plain
  /// `Text`; no markdown renderer is wired into the app. A local model emits
  /// `#### **Summary:**` and backticked ids by habit regardless, so on the
  /// device the user's own digests read as literal markup. Prompting against it
  /// helps and does not hold - hence doing it here, where every surface passes.
  ///
  /// What survives is what reads fine as plain text: bullets (`- item`),
  /// numbered lists, line structure, and the words. What goes is the syntax:
  /// heading hashes, emphasis asterisks, backticks, link brackets, blockquote
  /// markers and rules.
  ///
  /// **Underscore emphasis is deliberately left alone.** `_x_` is legal
  /// markdown, but this app's text is full of `sync_emails`,
  /// `mark_email_digested` and `{{due_at_label}}` - and a regex that turns
  /// `mark_email_digested` into `markemaildigested` would be a far worse bug
  /// than the one being fixed. Asterisks carry virtually all real emphasis in
  /// model output anyway.
  static String plainText(String text) {
    final lines = text.split('\n');
    final out = <String>[];
    var inFence = false;
    for (final line in lines) {
      if (RegExp(r'^\s*```').hasMatch(line)) {
        // Drop the fence marker but keep the code inside verbatim: it is the
        // one place where stray punctuation is the content.
        inFence = !inFence;
        continue;
      }
      if (inFence) {
        out.add(line);
        continue;
      }
      // A horizontal rule is pure decoration once unrendered.
      if (RegExp(r'^\s*([-*_])\1{2,}\s*$').hasMatch(line)) continue;
      var work = line
          .replaceAll(RegExp(r'^\s{0,3}#{1,6}\s+'), '')
          .replaceAll(RegExp(r'^\s*>\s?'), '');
      // Images before links, so ![alt](url) does not leave a stray '!'.
      work = work
          .replaceAllMapped(
              RegExp(r'!\[([^\]]*)\]\([^)]*\)'), (m) => m.group(1) ?? '')
          .replaceAllMapped(RegExp(r'\[([^\]]+)\]\(([^)]+)\)'),
              (m) => '${m.group(1)} (${m.group(2)})')
          .replaceAllMapped(RegExp(r'\*\*([^*]+)\*\*'), (m) => m.group(1)!)
          // Single-asterisk emphasis, but only when the asterisks hug the
          // text: leaves "2 * 3" and an unclosed "* bullet" untouched.
          .replaceAllMapped(
              RegExp(r'(?<!\S)\*(\S(?:[^*\n]*\S)?)\*(?!\S)'),
              (m) => m.group(1)!)
          .replaceAllMapped(RegExp(r'`([^`\n]+)`'), (m) => m.group(1)!);
      out.add(work.trimRight());
    }
    return out
        .join('\n')
        .replaceAll(RegExp(r'\n{3,}'), '\n\n')
        .trim();
  }

  /// Clips at a word boundary where one is close by, so the last thing the
  /// user sees is a word rather than half of one.
  static (String, bool) _clip(String text, int? maxChars) {
    if (maxChars == null || text.length <= maxChars) return (text, false);
    final hard = text.substring(0, maxChars);
    final lastSpace = hard.lastIndexOf(RegExp(r'\s'));
    final cut = lastSpace > maxChars - 40 ? hard.substring(0, lastSpace) : hard;
    return ('${cut.trimRight()}…', true);
  }
}
