import 'dart:async';

import 'package:speech_to_text/speech_to_text.dart';

/// The recogniser calls, behind a seam so the timing rules can be tested
/// without a microphone.
abstract class RecognizerPort {
  bool get isListening;

  /// Starts one recognition session. [onWords] gets the words heard so far
  /// in this session, and whether the engine considers them final.
  Future<void> start(void Function(String words, bool isFinal) onWords);

  Future<void> stop();
}

class SpeechToTextPort implements RecognizerPort {
  SpeechToTextPort(this._stt);

  final SpeechToText _stt;

  @override
  bool get isListening => _stt.isListening;

  @override
  Future<void> start(void Function(String words, bool isFinal) onWords) =>
      _stt.listen(
        onResult: (r) => onWords(r.recognizedWords, r.finalResult),
        listenOptions: SpeechListenOptions(
          partialResults: true,
          listenMode: ListenMode.dictation,
          // As long as the engine allows: ending the turn is decided here,
          // by [UtteranceListener.endSilence], not by the engine.
          pauseFor: const Duration(seconds: 30),
          listenFor: const Duration(seconds: 120),
        ),
      );

  @override
  Future<void> stop() => _stt.stop();
}

/// Hears one whole thing the user says, however many breaths it takes.
///
/// Android's recogniser ends its session at the first short pause - often
/// under a second, whatever `pauseFor` asks for - and treating that as the
/// end of the turn cut people off mid-sentence. So the session is restarted
/// whenever the engine stops, the words from every session are kept, and
/// the turn ends only after [endSilence] with no new words.
class UtteranceListener {
  UtteranceListener(
    this._recognizer, {
    this.endSilence = const Duration(milliseconds: 2500),
    this.noSpeech = const Duration(seconds: 8),
    this.maxLength = const Duration(seconds: 90),
    this.pollEvery = const Duration(milliseconds: 250),
    this.restartAfter = const Duration(milliseconds: 300),
  });

  final RecognizerPort _recognizer;

  /// Quiet after the last new word that ends the turn.
  final Duration endSilence;

  /// How long to wait for the first word before giving up.
  final Duration noSpeech;

  /// A hard ceiling on one turn.
  final Duration maxLength;

  final Duration pollEvery;
  final Duration restartAfter;

  Completer<String?>? _done;
  bool _cancelled = false;

  /// Listens until the user has finished, and returns what they said - or
  /// null when they said nothing. [onWords] sees the text as it grows.
  Future<String?> listen({void Function(String text)? onWords}) async {
    _cancelled = false;
    final done = Completer<String?>();
    _done = done;
    var banked = '';
    var current = '';
    var restarting = false;
    Timer? quiet;
    Timer? poll;
    Timer? ceiling;

    String text() => _join(banked, current);

    void finish() {
      if (done.isCompleted) return;
      quiet?.cancel();
      poll?.cancel();
      ceiling?.cancel();
      final heard = text().trim();
      done.complete(heard.isEmpty ? null : heard);
    }

    void armQuiet() {
      quiet?.cancel();
      quiet = Timer(text().trim().isEmpty ? noSpeech : endSilence, finish);
    }

    void onResult(String words, bool isFinal) {
      if (done.isCompleted) return;
      final changed = words != current;
      current = words;
      if (isFinal) {
        // Kept now: the next session starts from nothing.
        banked = _join(banked, current);
        current = '';
      }
      if (changed || isFinal) {
        onWords?.call(text());
        armQuiet();
      }
    }

    Future<void> startSession() async {
      try {
        await _recognizer.start(onResult);
      } catch (_) {
        // A refused start is retried by the poll, within the same limits.
      }
    }

    armQuiet();
    ceiling = Timer(maxLength, finish);
    await startSession();
    poll = Timer.periodic(pollEvery, (_) async {
      if (done.isCompleted || restarting || _recognizer.isListening) return;
      // The engine stopped on its own - a pause, not the end of the turn.
      restarting = true;
      if (current.isNotEmpty) {
        banked = _join(banked, current);
        current = '';
      }
      await Future<void>.delayed(restartAfter);
      if (!done.isCompleted && !_cancelled) await startSession();
      restarting = false;
    });

    final heard = await done.future;
    // Also reached through [cancel], which completes without [finish].
    quiet?.cancel();
    poll.cancel();
    ceiling.cancel();
    if (_recognizer.isListening) {
      try {
        await _recognizer.stop();
      } catch (_) {}
    }
    _done = null;
    return _cancelled ? null : heard;
  }

  /// Ends the turn now and discards it.
  void cancel() {
    _cancelled = true;
    final done = _done;
    if (done != null && !done.isCompleted) done.complete(null);
  }

  static String _join(String a, String b) {
    final left = a.trim();
    final right = b.trim();
    if (left.isEmpty) return right;
    if (right.isEmpty) return left;
    return '$left $right';
  }
}
