import '../models/agent_execution_report.dart';
import '../models/synthesized_response.dart';
import '../models/turn_contract.dart';
import '../orchestrator/turn_frame.dart';
import 'tool_labels.dart';

/// One part of the response that nothing in the turn accounts for.
class IrrelevantSection {
  const IrrelevantSection({required this.text, required this.reason});

  final String text;
  final String reason;

  Map<String, Object?> toJson() => {'text': text, 'reason': reason};
}

class RelevanceValidationResult {
  const RelevanceValidationResult({
    required this.sectionCount,
    required this.supportedCount,
    required this.unsupported,
    required this.coverage,
    required this.requiresRepair,
  });

  static const passed = RelevanceValidationResult(
    sectionCount: 0,
    supportedCount: 0,
    unsupported: [],
    coverage: 1,
    requiresRepair: false,
  );

  final int sectionCount;
  final int supportedCount;
  final List<IrrelevantSection> unsupported;

  /// Fraction of the response's sections that map to something the turn
  /// actually did or owes. 1.0 when there is nothing to check.
  final double coverage;

  /// True only when the drift is large enough to be worth a round trip.
  final bool requiresRepair;

  bool get isClean => unsupported.isEmpty;

  Map<String, Object?> toJson() => {
        'sections': sectionCount,
        'supported': supportedCount,
        'coverage': double.parse(coverage.toStringAsFixed(3)),
        if (unsupported.isNotEmpty)
          'unsupported': [for (final s in unsupported) s.toJson()],
      };
}

/// Deterministic check that the response stays on the subject of the turn.
///
/// Every section of the final message must map to one of four things:
///   1. a required output,
///   2. an action the turn executed,
///   3. an important warning, or
///   4. a directly relevant next step.
///
/// Verification already asks "is this true?"; this asks "was this asked
/// for?" — which is the failure that produces technically correct but
/// irrelevant background padding. It is deliberately lenient: a section is
/// flagged only when it shares *nothing* with the turn's vocabulary, and a
/// repair is requested only when most of the message drifted. The cost of a
/// false positive (a wasted repair call) is higher than the cost of letting
/// one stray sentence through.
class RelevanceValidator {
  const RelevanceValidator();

  /// Below this fraction of supported sections the message is mostly
  /// padding and worth repairing.
  static const double repairThreshold = 0.5;

  /// Sections shorter than this many content words are never flagged —
  /// "Done." and "Anything else?" are legitimate.
  static const int minimumSectionTokens = 6;

  RelevanceValidationResult validate({
    required SynthesizedResponse response,
    required CompletionContract contract,
    required AgentExecutionReport report,
    TurnFrame? frame,
  }) {
    final message = response.message.trim();
    if (message.isEmpty) return RelevanceValidationResult.passed;

    final vocabulary = _relevantVocabulary(
      contract: contract,
      report: report,
      frame: frame,
    );
    // Nothing to compare against (no actions, no goal) — do not invent a
    // judgement.
    if (vocabulary.length < 3) return RelevanceValidationResult.passed;

    final sections = splitSections(message);
    if (sections.isEmpty) return RelevanceValidationResult.passed;

    final unsupported = <IrrelevantSection>[];
    var supported = 0;
    var unsupportedChars = 0;

    for (final section in sections) {
      final tokens = TurnFrameBuilder.contentTokens(section);
      if (tokens.length < minimumSectionTokens ||
          _hasWarningOrNextStepMarker(section) ||
          tokens.any(vocabulary.contains)) {
        supported++;
        continue;
      }
      unsupportedChars += section.length;
      unsupported.add(IrrelevantSection(
        text: section.length > 160 ? '${section.substring(0, 160)}...' : section,
        reason: 'Does not map to a required output, an executed action, a '
            'warning, or a next step.',
      ));
    }

    final coverage = supported / sections.length;
    return RelevanceValidationResult(
      sectionCount: sections.length,
      supportedCount: supported,
      unsupported: unsupported,
      coverage: coverage,
      // Two independent signals must agree before spending a repair call:
      // most sections drifted AND they are the bulk of what the user reads.
      requiresRepair: unsupported.length >= 2 &&
          coverage < repairThreshold &&
          unsupportedChars > message.length * 0.4,
    );
  }

  /// Everything the turn legitimately talks about: the goal, the actions it
  /// planned, what it actually did, what it created, and what it warned
  /// about.
  static Set<String> _relevantVocabulary({
    required CompletionContract contract,
    required AgentExecutionReport report,
    TurnFrame? frame,
  }) {
    final vocabulary = <String>{};
    void add(String? text) {
      if (text == null || text.isEmpty) return;
      vocabulary.addAll(TurnFrameBuilder.contentTokens(text));
    }

    add(contract.originalRequest);
    for (final action in contract.actions) {
      add(action.description);
    }
    for (final constraint in contract.constraints) {
      add(constraint);
    }
    for (final output in contract.requiredOutputs) {
      add(output.wireName.replaceAll('_', ' '));
    }
    add(frame?.primaryGoal);
    if (frame != null) {
      vocabulary.addAll(frame.retrievalTerms);
      for (final entity in frame.entities) {
        add(entity.name);
      }
      if (frame.timeScope != null) add(frame.timeScope!.label);
    }

    for (final completed in report.actionsCompleted) {
      add(completed);
    }
    for (final failed in report.actionsFailed) {
      add(failed);
    }
    for (final warning in report.warnings) {
      add(warning);
    }
    for (final uncertain in report.uncertainItems) {
      add(uncertain);
    }
    for (final tool in report.toolsCalled) {
      add(tool.replaceAll('_', ' '));
      // The human wording the synthesizer is told to use for the same
      // tool, so "checked your chats" is on-topic for sync_messages. Without
      // this the check rewards the very tool-name echo the prompt forbids.
      add(ToolLabels.describe(tool));
      add(ToolLabels.pill(tool));
    }
    for (final group in [
      report.tasksCreated,
      report.eventsCreated,
      report.eventsModified,
      report.emailDigestItems,
      report.filesAffected,
      report.screensCreated,
      report.rulesChanged,
    ]) {
      for (final item in group) {
        for (final value in item.values) {
          if (value is String) add(value);
        }
      }
    }
    return vocabulary;
  }

  static final _markers = RegExp(
    r'\b(warning|caution|note that|heads up|could not|couldn.t|failed|'
    r'skipped|blocked|next step|next steps|you may want|want me to|'
    r'shall i|should i|let me know|nothing else|no action)\b',
    caseSensitive: false,
  );

  static bool _hasWarningOrNextStepMarker(String section) =>
      _markers.hasMatch(section) || section.trimRight().endsWith('?');

  /// Splits a message into the units a reader perceives as separate points:
  /// bullets and list rows first, then paragraphs.
  static List<String> splitSections(String message) {
    final sections = <String>[];
    for (final block in message.split(RegExp(r'\n\s*\n'))) {
      final lines = block.split('\n');
      final bullets = [
        for (final line in lines)
          if (RegExp(r'^\s*(?:[-*•]|\d+[.)])\s+').hasMatch(line)) line,
      ];
      if (bullets.length >= 2) {
        // A bulleted block: each row is its own point, and any lead-in text
        // above it is another.
        final lead = lines
            .where((line) => !RegExp(r'^\s*(?:[-*•]|\d+[.)])\s+').hasMatch(line))
            .join(' ')
            .trim();
        if (lead.isNotEmpty) sections.add(lead);
        sections.addAll(bullets.map((line) => line.trim()));
        continue;
      }
      final text = block.trim();
      if (text.isNotEmpty) sections.add(text);
    }
    return sections;
  }
}
