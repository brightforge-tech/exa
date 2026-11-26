import 'package:exa_mobile/services/voice/utterance_listener.dart';
import 'package:flutter_test/flutter_test.dart';

/// A recogniser that behaves like Android's: each session ends at the
/// first pause, with whatever it heard marked final.
class FakeRecognizer implements RecognizerPort {
  bool _listening = false;
  void Function(String, bool)? _onWords;
  int starts = 0;

  @override
  bool get isListening => _listening;

  @override
  Future<void> start(void Function(String words, bool isFinal) onWords) async {
    starts++;
    _listening = true;
    _onWords = onWords;
  }

  @override
  Future<void> stop() async => _listening = false;

  void hear(String words) => _onWords?.call(words, false);

  /// The engine's own end-of-session at a short pause.
  void pause(String finalWords) {
    _onWords?.call(finalWords, true);
    _listening = false;
  }
}

UtteranceListener listener(FakeRecognizer r) => UtteranceListener(
      r,
      endSilence: const Duration(milliseconds: 400),
      noSpeech: const Duration(milliseconds: 600),
      maxLength: const Duration(seconds: 5),
      pollEvery: const Duration(milliseconds: 20),
      restartAfter: const Duration(milliseconds: 20),
    );

Future<void> wait(int ms) => Future<void>.delayed(Duration(milliseconds: ms));

void main() {
  test('a pause mid-sentence does not end the turn', () async {
    final r = FakeRecognizer();
    final heard = listener(r).listen();
    await wait(30);
    r.hear('remind me to call');
    await wait(50);
    // The engine gives up at a breath - this used to end the turn.
    r.pause('remind me to call');
    await wait(150);
    expect(r.starts, greaterThan(1), reason: 'the session is restarted');
    r.hear('Sam tomorrow at nine');
    await wait(50);
    r.pause('Sam tomorrow at nine');
    expect(await heard, 'remind me to call Sam tomorrow at nine');
  });

  test('the turn ends after real silence', () async {
    final r = FakeRecognizer();
    final watch = Stopwatch()..start();
    final heard = listener(r).listen();
    await wait(30);
    r.hear('what is on today');
    expect(await heard, 'what is on today');
    expect(watch.elapsedMilliseconds, greaterThanOrEqualTo(400));
  });

  test('saying nothing returns nothing', () async {
    final r = FakeRecognizer();
    expect(await listener(r).listen(), isNull);
  });

  test('words grow as they are heard', () async {
    final r = FakeRecognizer();
    final seen = <String>[];
    final heard = listener(r).listen(onWords: seen.add);
    await wait(30);
    r.hear('add');
    r.hear('add milk');
    r.pause('add milk');
    await wait(100);
    r.hear('and eggs');
    await heard;
    expect(seen, ['add', 'add milk', 'add milk', 'add milk and eggs']);
  });

  test('cancel ends the turn at once and discards it', () async {
    final r = FakeRecognizer();
    final l = listener(r);
    final heard = l.listen();
    await wait(30);
    r.hear('never mind this');
    l.cancel();
    expect(await heard, isNull);
  });
}
