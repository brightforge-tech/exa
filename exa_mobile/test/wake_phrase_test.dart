import 'dart:io';

import 'package:exa_mobile/services/voice/wake_phrase.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('splits phrases exactly as SentencePiece does', () {
    // Generated with the sentencepiece library from the model's own
    // bpe.model; one phrase per line, then its pieces.
    final lines = File('test/fixtures/kws_bpe_reference.tsv')
        .readAsLinesSync()
        .where((l) => l.trim().isNotEmpty);
    var checked = 0;
    for (final line in lines) {
      final parts = line.split('\t');
      expect(WakePhrase.encode(parts[0])?.join(' '), parts[1],
          reason: parts[0]);
      checked++;
    }
    expect(checked, greaterThan(50));
  });

  test('"Hey Exa" listens for its pronunciations and ignores its decoys', () {
    final built = WakePhrase.forPhrase('hey exa!').value!;
    expect(built.phrase, 'Hey Exa');
    final lines = built.keywords.split('/');
    expect(lines.first, '▁HE Y ▁EX A @WAKE_HEY_EXA');
    expect(lines.where((l) => l.contains('@WAKE_')), hasLength(4));
    expect(lines, contains('▁HE Y ▁A LE X A @DECOY_HEY_ALEXA'));
  });

  test('the service\'s built-in default is the same as the app\'s', () {
    // The listener has to work before the app ever configured it, so it
    // carries its own copy; the two must not drift.
    final kotlin = File('packages/exa_voice/android/src/main/kotlin/'
            'com/brightforge/exa/voice/WakeWordService.kt')
        .readAsStringSync();
    final block = RegExp(r'DEFAULT_KEYWORDS =([\s\S]*?)\n\n')
        .firstMatch(kotlin)!
        .group(1)!;
    final native = [
      for (final m in RegExp(r'"([^"]*)"').allMatches(block)) m.group(1)!,
    ].join().replaceAll(r'▁', '▁');
    expect(native, WakePhrase.forPhrase(WakePhrase.defaultPhrase).value!
        .keywords);
  });

  test('other phrases work, without the Exa-specific extras', () {
    final built = WakePhrase.forPhrase('Hey Jarvis').value!;
    expect(built.keywords,
        '▁HE Y ▁JA R VI S @WAKE_HEY_JARVIS/▁HI ▁JA R VI S @WAKE_HI_JARVIS');
  });

  test('phrases that would wake Exa by accident are refused', () {
    expect(WakePhrase.forPhrase('Exa').error, contains('two words'));
    expect(WakePhrase.forPhrase('a b').error, contains('too short'));
    expect(WakePhrase.forPhrase('').error, isNotNull);
    expect(WakePhrase.forPhrase('one two three four five six').error,
        contains('five words'));
  });
}
