import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:speech_to_text/speech_to_text.dart';

/// State for continuous, long-form dictation into a document.
///
/// [committed] holds finished utterances (and any text the editor seeds back
/// in after a manual edit); [partial] is the live, in-progress words of the
/// current recognition session. [fullText] is what the editor renders while
/// listening.
class DictationState {
  final String committed;
  final String partial;
  final bool listening;
  final bool available;
  final String? error;

  const DictationState({
    this.committed = '',
    this.partial = '',
    this.listening = false,
    this.available = false,
    this.error,
  });

  String get fullText {
    if (partial.isEmpty) return committed;
    if (committed.isEmpty) return partial;
    return '$committed $partial';
  }

  DictationState copyWith({
    String? committed,
    String? partial,
    bool? listening,
    bool? available,
    String? error,
    bool clearError = false,
  }) =>
      DictationState(
        committed: committed ?? this.committed,
        partial: partial ?? this.partial,
        listening: listening ?? this.listening,
        available: available ?? this.available,
        error: clearError ? null : (error ?? this.error),
      );
}

/// Drives the device speech recognizer for open-ended dictation.
///
/// The `speech_to_text` engine stops on its own after a silence pause or a
/// max-duration cap, and each session's `recognizedWords` resets. To behave
/// like a dictation document we (a) APPEND each finalized utterance to
/// [DictationState.committed] instead of replacing, and (b) auto-restart the
/// engine whenever it stops while the user still intends to record - tracked
/// by [_wantListening], which survives those restarts.
class DictationController extends StateNotifier<DictationState> {
  DictationController() : super(const DictationState());

  final SpeechToText _speech = SpeechToText();

  /// User intent to keep recording. Set false only by [stop]/[dispose]; the
  /// engine's own done/error callbacks check it to decide restart vs stop.
  bool _wantListening = false;
  bool _initialized = false;
  bool _restartScheduled = false;

  /// Seed the committed buffer from the current document text so a resumed
  /// dictation appends after it rather than starting from scratch (e.g. after
  /// the user hand-edits the text between recordings).
  void setCommitted(String text) {
    state = state.copyWith(committed: text.trim(), partial: '');
  }

  Future<void> start() async {
    if (!_initialized) {
      _initialized = await _speech.initialize(
        onStatus: _onStatus,
        onError: (_) {
          // An error often just means the session ended oddly; keep going if
          // the user still wants to record.
          if (_wantListening) _restartSoon();
        },
      );
      if (!_initialized) {
        state = state.copyWith(
          available: false,
          error: 'Voice input is unavailable - check the microphone '
              'permission.',
        );
        return;
      }
    }
    _wantListening = true;
    state = state.copyWith(listening: true, available: true, clearError: true);
    await _listenOnce();
  }

  Future<void> _listenOnce() async {
    await _speech.listen(
      onResult: (result) {
        if (result.finalResult) {
          final words = result.recognizedWords.trim();
          if (words.isEmpty) {
            state = state.copyWith(partial: '');
            return;
          }
          final merged = state.committed.isEmpty
              ? words
              : '${state.committed} $words';
          state = state.copyWith(committed: merged, partial: '');
        } else {
          state = state.copyWith(partial: result.recognizedWords);
        }
      },
      listenOptions: SpeechListenOptions(
        partialResults: true,
        listenMode: ListenMode.dictation,
        // Generous pause; we auto-restart anyway, so this just reduces churn.
        pauseFor: const Duration(seconds: 8),
      ),
    );
  }

  void _onStatus(String status) {
    if (status == 'done' || status == 'notListening') {
      if (_wantListening) {
        _restartSoon();
      } else if (mounted) {
        state = state.copyWith(listening: false);
      }
    }
  }

  /// The plugin must fully finish the previous session before `listen()` is
  /// called again, or it throws. A short debounce plus the [_restartScheduled]
  /// guard prevents overlapping sessions and tight error loops.
  Future<void> _restartSoon() async {
    if (_restartScheduled || !_wantListening) return;
    _restartScheduled = true;
    await Future<void>.delayed(const Duration(milliseconds: 250));
    _restartScheduled = false;
    if (!_wantListening || !mounted || _speech.isListening) return;
    try {
      await _listenOnce();
    } catch (_) {
      if (_wantListening) _restartSoon();
    }
  }

  Future<void> stop() async {
    _wantListening = false;
    await _speech.stop();
    // Don't lose a trailing partial that never got a final result.
    if (state.partial.isNotEmpty) {
      final merged = state.committed.isEmpty
          ? state.partial
          : '${state.committed} ${state.partial}';
      state = state.copyWith(committed: merged, partial: '', listening: false);
    } else {
      state = state.copyWith(listening: false);
    }
  }

  @override
  void dispose() {
    _wantListening = false;
    _speech.stop();
    _speech.cancel();
    super.dispose();
  }
}
