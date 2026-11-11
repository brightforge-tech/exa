/// Approximate token counts without a tokenizer.
///
/// The app talks to several providers (Claude, an OpenAI-compatible local
/// endpoint, on-device Gemma/Qwen) whose tokenizers differ and none of which
/// is available offline in Dart. Characters alone are a poor proxy - "URL,
/// JSON and code are dense, prose is not" - so this blends two signals that
/// bracket real BPE behaviour:
///
///   * ~3.6 characters per token for ordinary prose;
///   * ~1.3 tokens per whitespace-delimited word, since punctuation and
///     sub-word splits add to the raw word count.
///
/// Taking the larger of the two errs toward over-counting, which is the
/// right direction for a budget: it trims a rule too early rather than
/// silently blowing the context. Measured against Claude's tokenizer on
/// rule-like English text this lands within roughly 10-15%.
class TokenEstimator {
  const TokenEstimator._();

  static const double _charsPerToken = 3.6;

  /// Structured text tokenizes far denser than prose: braces, quotes,
  /// colons and ISO timestamps each cost a token or more, so JSON lands
  /// nearer 2.7 characters per token. Tool definitions and tool results -
  /// the two largest things in a turn - are both JSON, and estimating them
  /// as prose under-counts by a third, which is the difference between a
  /// request that fits and one the server rejects.
  static const double _jsonCharsPerToken = 2.7;
  static const double _tokensPerWord = 1.3;

  static int estimate(String text) {
    if (text.isEmpty) return 0;
    final perChar = _looksStructured(text) ? _jsonCharsPerToken : _charsPerToken;
    final byChars = (text.length / perChar).ceil();
    final words = text.trim().split(RegExp(r'\s+')).where((w) => w.isNotEmpty);
    final byWords = (words.length * _tokensPerWord).ceil();
    return byChars > byWords ? byChars : byWords;
  }

  /// Cheap structural sniff: enough punctuation density to be JSON rather
  /// than a sentence. Sampled, so a megabyte of tool definitions costs no
  /// more to classify than a line does.
  static bool _looksStructured(String text) {
    final sample = text.length > 400 ? text.substring(0, 400) : text;
    var marks = 0;
    for (final unit in sample.codeUnits) {
      // { } [ ] " : ,
      if (unit == 0x7b ||
          unit == 0x7d ||
          unit == 0x5b ||
          unit == 0x5d ||
          unit == 0x22 ||
          unit == 0x3a ||
          unit == 0x2c) {
        marks++;
      }
    }
    return marks / sample.length > 0.06;
  }

  /// Estimated cost of rendering one rule as a prompt line, including the
  /// `- [type] ` prefix and the newline.
  static int estimateRuleLine(String behaviorType, String ruleText) =>
      estimate('- [$behaviorType] $ruleText\n');
}

/// Which model call a behavior block is being built for. Each needs a
/// different slice of the rules - the planner does not need writing tone,
/// and the writer does not need tool policy.
enum AgentPhase {
  /// Domain routing and contract building.
  planner,

  /// The tool-using loop.
  action,

  /// The no-tool call that writes the user-facing message.
  synthesis,

  /// The single repair attempt after validation failed.
  repair,
}

/// Per-phase ceiling on behavior tokens.
///
/// Small local models are the binding constraint: on a 4k-8k context, a
/// behavior block that is a few hundred tokens in every one of three calls
/// is a real cost. Budgets scale down with the context window rather than
/// being fixed.
class BehaviorTokenBudget {
  const BehaviorTokenBudget(this.maxTokens);

  final int maxTokens;

  /// Defaults sized for a comfortable context (>= 32k).
  static const _defaults = <AgentPhase, int>{
    AgentPhase.planner: 400,
    AgentPhase.action: 350,
    AgentPhase.synthesis: 300,
    // Repair only needs the constraints that failed.
    AgentPhase.repair: 150,
  };

  static BehaviorTokenBudget forPhase(
    AgentPhase phase, {
    int? contextWindow,
  }) {
    final base = _defaults[phase]!;
    if (contextWindow == null || contextWindow >= 32000) {
      return BehaviorTokenBudget(base);
    }
    // Never let behaviors take more than ~3% of a small window.
    final cap = (contextWindow * 0.03).floor();
    return BehaviorTokenBudget(base < cap ? base : (cap < 60 ? 60 : cap));
  }
}
