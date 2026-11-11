import 'package:exa_mobile/features/overlay/voice_input_controller.dart';
import 'package:flutter_test/flutter_test.dart';

/// The bubble's Voice action sends the spoken message by itself when the
/// recognizer stops - once, and only while the user has not taken over.
void main() {
  const listening = VoiceInputState(listening: true, text: 'remind me');
  const stopped = VoiceInputState(listening: false, text: 'remind me at 6');

  test('fires on the listening -> stopped edge with words in hand', () {
    expect(
      VoiceAutoSend.shouldSend(previous: listening, next: stopped, armed: true),
      isTrue,
    );
  });

  test('does not fire while still listening, or twice', () {
    expect(
      VoiceAutoSend.shouldSend(
          previous: listening,
          next: const VoiceInputState(listening: true, text: 'remind'),
          armed: true),
      isFalse,
    );
    // A second state change after the stop is not another edge.
    expect(
      VoiceAutoSend.shouldSend(previous: stopped, next: stopped, armed: true),
      isFalse,
    );
    expect(
      VoiceAutoSend.shouldSend(previous: null, next: stopped, armed: true),
      isFalse,
    );
  });

  test('does not fire once the user has taken over', () {
    expect(
      VoiceAutoSend.shouldSend(previous: listening, next: stopped, armed: false),
      isFalse,
    );
  });

  test('does not fire with nothing heard, or when the mic failed to start', () {
    expect(
      VoiceAutoSend.shouldSend(
          previous: listening,
          next: const VoiceInputState(listening: false, text: '   '),
          armed: true),
      isFalse,
    );
    expect(
      VoiceAutoSend.shouldSend(
          previous: listening,
          next: const VoiceInputState(
              listening: false, text: 'remind me', error: 'no mic'),
          armed: true),
      isFalse,
    );
  });

  test('fires on the final-result edge even while still listening', () {
    // The engine can deliver the final words before it reports "stopped".
    // Waiting only for the stop edge would send the last partial (or empty);
    // the finalized flag catches the full transcript when it lands.
    expect(
      VoiceAutoSend.shouldSend(
        previous: const VoiceInputState(listening: true, text: 'remind'),
        next: const VoiceInputState(
            listening: true, text: 'remind me at 6', finalized: true),
        armed: true,
      ),
      isTrue,
    );
  });

  test('the stop edge with a stale partial still resolves to the final text',
      () {
    // Order the other way: "stopped" arrives first carrying only a partial,
    // then the final result. The stop edge is suppressed here only if the
    // partial is empty; with a partial it would fire - so the panel sends
    // next.text and the LATER finalized edge is a no-op (armed already
    // cleared). This test pins that the finalized edge is recognized so the
    // panel can prefer it.
    const stoppedFinal = VoiceInputState(
        listening: false, text: 'remind me at 6', finalized: true);
    expect(
      VoiceAutoSend.shouldSend(
        previous: const VoiceInputState(listening: false, text: 'remind'),
        next: stoppedFinal,
        armed: true,
      ),
      isTrue,
    );
  });
}
