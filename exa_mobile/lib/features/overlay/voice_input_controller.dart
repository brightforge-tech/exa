import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:speech_to_text/speech_to_text.dart';

/// One spoken message, in progress.
class VoiceInputState {
  const VoiceInputState({
    this.listening = false,
    this.text = '',
    this.error,
    this.finalized = false,
  });

  final bool listening;

  /// Everything heard so far this session, seed text included, ready to drop
  /// into the composer verbatim.
  final String text;

  /// Set when the recognizer could not start. In the overlay this is almost
  /// always the microphone permission, which cannot be requested from here.
  final String? error;

  /// True once the recognizer has delivered its *final* result for this
  /// session (`recognizedWords` will not change again). The auto-send edge
  /// keys off this rather than off [listening] alone, because on some
  /// engines the "stopped listening" status arrives before the final words
  /// do - and sending on the stop edge then sends an empty or half-heard
  /// message.
  final bool finalized;

  VoiceInputState copyWith({
    bool? listening,
    String? text,
    String? error,
    bool? finalized,
    bool clearError = false,
  }) =>
      VoiceInputState(
        listening: listening ?? this.listening,
        text: text ?? this.text,
        error: clearError ? null : (error ?? this.error),
        finalized: finalized ?? this.finalized,
      );
}

/// The rule behind the bubble's Voice action: a message that was *opened by
/// voice* sends itself the moment the recognizer is done, with words in hand.
///
/// Pure, so the rule is pinned by a test rather than by reading the panel. It
/// fires once, while still armed (the user has not touched the field or the
/// mic since), with something to send, and never on an error. The trigger is
/// "the recognition just finalized OR the mic just stopped" - whichever comes
/// first - because the two arrive in either order depending on the engine,
/// and waiting only for the stop edge is what dropped the transcript.
///
/// The caller sends [VoiceInputState.text] directly (not whatever landed in
/// the text field): that field is filled by a second listener whose timing is
/// not guaranteed relative to this one, so at the send edge it may still be
/// empty.
class VoiceAutoSend {
  const VoiceAutoSend._();

  static bool shouldSend({
    required VoiceInputState? previous,
    required VoiceInputState next,
    required bool armed,
  }) {
    if (!armed) return false;
    if (next.error != null) return false;
    if (next.text.trim().isEmpty) return false;
    final justFinalized = next.finalized && !(previous?.finalized ?? false);
    final justStopped = (previous?.listening ?? false) && !next.listening;
    return justFinalized || justStopped;
  }
}

/// Speech capture for a single message, not a document.
///
/// Deliberately unlike [DictationController], which auto-restarts the engine
/// so a long transcript can survive pauses: here the recognizer stopping IS
/// the signal that the user finished their sentence, so the mic goes cold and
/// the words are left in the composer to check and send. Holding the mic open
/// over someone else's app, waiting for more speech, is not something an
/// overlay should do quietly.
class VoiceInputController extends StateNotifier<VoiceInputState> {
  VoiceInputController() : super(const VoiceInputState());

  /// Why the mic can refuse to start here, and the only way to fix it.
  ///
  /// The overlay engine is hosted by a Service with no Activity attached, and
  /// `speech_to_text` can only raise the system permission prompt from an
  /// Activity - so it reports "unavailable" rather than asking. Granting has
  /// to happen inside the app once; after that the recognizer runs fine from
  /// the service.
  static const micPermissionMessage =
      'Voice input needs microphone permission, which can only be granted in '
      'the app. Open Exa > Transcribe, tap the mic once and allow it - then '
      'this works from the bubble.';

  final SpeechToText _speech = SpeechToText();
  bool _initialized = false;

  /// Text already in the field when the mic was tapped; new words append to
  /// it rather than wiping what was typed.
  String _seed = '';

  /// Starts listening, appending to [seed]. Safe to call while already
  /// listening (no-op).
  Future<void> start({String seed = ''}) async {
    if (state.listening) return;
    if (!_initialized) {
      _initialized = await _speech.initialize(
        onStatus: _onStatus,
        onError: (_) {
          // The recognizer reports "no match" and "speech timeout" as errors.
          // Neither is worth a message: the words heard so far are already in
          // the composer, so just go quiet.
          if (mounted) state = state.copyWith(listening: false);
        },
      );
      if (!_initialized) {
        state = state.copyWith(listening: false, error: micPermissionMessage);
        return;
      }
    }
    _seed = seed.trim();
    state = VoiceInputState(listening: true, text: _seed);
    await _speech.listen(
      onResult: (result) {
        if (!mounted) return;
        final heard = result.recognizedWords.trim();
        state = state.copyWith(
          text: _seed.isEmpty ? heard : (heard.isEmpty ? _seed : '$_seed $heard'),
          finalized: result.finalResult,
        );
      },
      listenOptions: SpeechListenOptions(
        partialResults: true,
        // A question, not a monologue: end the session shortly after they
        // stop talking so the send button is the next thing they touch.
        listenMode: ListenMode.dictation,
        pauseFor: const Duration(seconds: 3),
        listenFor: const Duration(seconds: 60),
      ),
    );
  }

  Future<void> stop() async {
    if (!state.listening) return;
    await _speech.stop();
    if (mounted) state = state.copyWith(listening: false);
  }

  Future<void> toggle({String seed = ''}) =>
      state.listening ? stop() : start(seed: seed);

  /// Clears the buffer after the message is sent (or abandoned) so the next
  /// tap starts clean.
  void reset() {
    _seed = '';
    if (mounted) state = const VoiceInputState();
  }

  void _onStatus(String status) {
    if (!mounted) return;
    if (status == 'done' || status == 'notListening') {
      state = state.copyWith(listening: false);
    }
  }

  @override
  void dispose() {
    _speech.stop();
    _speech.cancel();
    super.dispose();
  }
}

final voiceInputControllerProvider =
    StateNotifierProvider<VoiceInputController, VoiceInputState>(
        (ref) => VoiceInputController());
