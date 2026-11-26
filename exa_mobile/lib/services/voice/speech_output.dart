import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_tts/flutter_tts.dart';

/// Exa's voice: reads replies aloud through the phone's own text-to-speech
/// engine.
///
/// The platform engine rather than a cloud voice on purpose. It works
/// offline, costs nothing, and sends the reply nowhere - the same promise
/// the rest of the app makes about where text goes. A user who wants a
/// different voice installs or picks one in Android's text-to-speech
/// settings, and Exa uses it.
class SpeechOutput {
  SpeechOutput({FlutterTts? tts}) : _tts = tts ?? FlutterTts();

  final FlutterTts _tts;
  bool _ready = false;
  bool _speaking = false;

  /// The most characters read aloud from one reply. A long reply (a digest,
  /// a list of twenty tasks) is a screen's worth of text, and listening to
  /// all of it is worse than glancing at it.
  static const maxSpokenChars = 1200;

  bool get isSpeaking => _speaking;

  Future<void> _ensureReady() async {
    if (_ready) return;
    // speak() completes when the utterance has finished, so a conversation
    // can start listening again only once Exa has stopped talking - never
    // while the microphone would hear Exa's own voice.
    await _tts.awaitSpeakCompletion(true);
    await _tts.setSpeechRate(0.5);
    await _tts.setPitch(1.0);
    _ready = true;
  }

  /// Reads [text] aloud and completes when it has been spoken (or stopped).
  /// Returns false when there was nothing to say or the engine failed.
  Future<bool> speak(String text) async {
    final spoken = forSpeech(text);
    if (spoken.isEmpty) return false;
    try {
      await _ensureReady();
      await _tts.stop();
      _speaking = true;
      final result = await _tts.speak(spoken);
      return result == 1;
    } catch (_) {
      return false;
    } finally {
      _speaking = false;
    }
  }

  Future<void> stop() async {
    _speaking = false;
    try {
      await _tts.stop();
    } catch (_) {
      // Nothing playing is not an error worth surfacing.
    }
  }

  /// A reply written for a screen, rewritten to be heard: no markdown, no
  /// addresses read out character by character, bullets as pauses, and a
  /// long reply cut at a sentence with a pointer to the rest.
  static String forSpeech(String text) {
    var out = text
        .replaceAll(RegExp(r'```.*?```', dotAll: true), ' ')
        .replaceAll(RegExp(r'https?://\S+'), 'a link')
        .replaceAll(RegExp(r'[*_`#>|]+'), '')
        .replaceAll(RegExp(r'^\s*[-•]\s+', multiLine: true), '')
        .replaceAll(RegExp(r'^\s*\d+[.)]\s+', multiLine: true), '');
    final lines = [
      for (final line in out.split('\n'))
        if (line.trim().isNotEmpty) line.trim(),
    ];
    // A line that does not end a sentence still needs a pause after it.
    out = lines
        .map((line) => RegExp(r'[.!?:;,]$').hasMatch(line) ? line : '$line.')
        .join(' ')
        .replaceAll(RegExp(r'\s+'), ' ')
        .trim();
    if (out.length <= maxSpokenChars) return out;
    final cut = out.substring(0, maxSpokenChars);
    final lastStop = cut.lastIndexOf(RegExp(r'[.!?]\s'));
    final head = lastStop > maxSpokenChars ~/ 2
        ? cut.substring(0, lastStop + 1)
        : '${cut.substring(0, cut.lastIndexOf(' '))}...';
    return '$head The rest is on your screen.';
  }

  void dispose() {
    unawaited(stop());
  }
}

final speechOutputProvider = Provider<SpeechOutput>((ref) {
  final output = SpeechOutput();
  ref.onDispose(output.dispose);
  return output;
});
