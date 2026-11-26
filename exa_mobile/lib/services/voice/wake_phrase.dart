import 'package:exa_voice/exa_voice.dart';

import 'kws_vocab.dart';

/// Turns the wake phrase the user typed into what the keyword spotter
/// listens for.
///
/// The spotter (sherpa-onnx, android/sherpa.gradle) does not read text: it
/// matches sequences of its model's word pieces, so "Hey Exa" has to arrive
/// as `▁HE Y ▁EX A`. That is SentencePiece segmentation over the model's own
/// vocabulary ([kwsVocab]), done here so the phrase can be changed on the
/// phone - checked against the reference implementation in
/// wake_phrase_test.dart.
///
/// One phrase becomes several keyword lines: the phrase, a few ways of
/// saying it, and decoys - words that sound close ("Hey Alexa", "extra").
/// The service opens Exa only on a `WAKE_` line; a decoy that matches is the
/// spotter hearing something else, and is ignored.
class WakePhrase {
  const WakePhrase._(this.phrase, this.keywords);

  /// As shown to the user.
  final String phrase;

  /// The spotter's keyword lines, joined by `/`.
  final String keywords;

  static const defaultPhrase = 'Hey Exa';

  /// Builds the keywords for [phrase], or explains why it cannot be used.
  static ({WakePhrase? value, String? error}) forPhrase(String phrase) {
    final words = normalize(phrase);
    if (words.isEmpty) return (value: null, error: 'Type a phrase.');
    if (words.length < 2) {
      return (
        value: null,
        error: 'Use at least two words ("Hey Exa"): one short word '
            'wakes Exa by accident.',
      );
    }
    if (words.join().length < 5) {
      return (value: null, error: 'That phrase is too short to hear reliably.');
    }
    if (words.length > 5) {
      return (value: null, error: 'Keep it to five words or fewer.');
    }

    final wake = <List<String>>[words];
    // How "Exa" is actually said, which its spelling does not capture.
    if (words.contains('EXA')) {
      for (final spoken in const ['EKSA', 'ECKSA']) {
        wake.add([for (final w in words) w == 'EXA' ? spoken : w]);
      }
    }
    // People say "hi" and "hey" interchangeably.
    if (words.first == 'HEY') wake.add(['HI', ...words.skip(1)]);
    if (words.first == 'HI') wake.add(['HEY', ...words.skip(1)]);

    final lines = <String>[];
    for (final variant in wake) {
      final pieces = encodeWords(variant);
      if (pieces == null) {
        return (
          value: null,
          error: 'Use plain letters only - no digits or symbols.',
        );
      }
      lines.add('${pieces.join(' ')} @WAKE_${variant.join('_')}');
    }
    if (words.contains('EXA')) {
      for (final decoy in const [
        ['HEY', 'ALEXA'],
        ['ALEXA'],
        ['EXTRA'],
        ['EXAM'],
      ]) {
        lines.add('${encodeWords(decoy)!.join(' ')} @DECOY_${decoy.join('_')}');
      }
    }
    return (
      value: WakePhrase._(_display(words), lines.join('/')),
      error: null,
    );
  }

  /// Re-prepares the stored phrase when this build would prepare it
  /// differently - a phrase saved before an update gets that update's
  /// variants and decoys. Only writes (and so restarts the listener) when
  /// something changed.
  static Future<void> resync(ExaVoice voice) async {
    try {
      final status = await voice.status();
      final stored = status.wakeKeywords;
      if (stored == null) return; // the built-in default, already current
      final built = forPhrase(status.wakePhrase).value;
      if (built == null || built.keywords == stored) return;
      await voice.configureWakeWord(
          phrase: built.phrase, keywords: built.keywords);
    } catch (_) {
      // The next launch tries again.
    }
  }

  /// Upper-case words of plain letters (and apostrophes), as the model was
  /// trained on.
  static List<String> normalize(String phrase) => [
        for (final word in phrase
            .toUpperCase()
            .replaceAll(RegExp(r"[^A-Z' ]"), ' ')
            .split(RegExp(r'\s+')))
          if (word.replaceAll("'", '').isNotEmpty) word,
      ];

  static String _display(List<String> words) => words
      .map((w) => w[0] + w.substring(1).toLowerCase())
      .join(' ');

  /// The model's SentencePiece segmentation. Despite the file's name
  /// (`bpe.model`) it is a unigram model, as icefall trains them: each word,
  /// with its leading `▁`, is split into the pieces whose scores (log
  /// probabilities) sum highest - a Viterbi search over the vocabulary.
  /// Null when some character cannot be spelled with it at all.
  static List<String>? encodeWords(List<String> words) {
    final out = <String>[];
    for (final word in words) {
      final text = '▁$word';
      final n = text.length;
      final best = List<double>.filled(n + 1, double.negativeInfinity);
      final from = List<int>.filled(n + 1, -1);
      best[0] = 0;
      for (var end = 1; end <= n; end++) {
        for (var start = 0; start < end; start++) {
          if (best[start] == double.negativeInfinity) continue;
          final score = kwsVocab[text.substring(start, end)];
          if (score == null) continue;
          final total = best[start] + score;
          if (total > best[end]) {
            best[end] = total;
            from[end] = start;
          }
        }
      }
      if (from[n] < 0) return null;
      final pieces = <String>[];
      for (var end = n; end > 0; end = from[end]) {
        pieces.insert(0, text.substring(from[end], end));
      }
      out.addAll(pieces);
    }
    return out;
  }

  /// [encodeWords] for a phrase as typed.
  static List<String>? encode(String phrase) => encodeWords(normalize(phrase));
}
