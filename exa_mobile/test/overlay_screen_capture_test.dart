import 'package:exa_mobile/features/overlay/overlay_chat_controller.dart';
import 'package:exa_mobile/features/overlay/voice_input_controller.dart';
import 'package:exa_mobile/services/overlay/overlay_panel_channel.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

/// The "look at my screen" path: the native contract the chat sheet drives,
/// the message that reaches the model, and what the mic does when the overlay
/// cannot ask for the permission it needs.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const panelChannel = MethodChannel('com.brightforge.exa/overlay_panel');
  final calls = <MethodCall>[];

  void mockPanel(Future<Object?> Function(MethodCall call) handler) {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(panelChannel, (call) {
      calls.add(call);
      return handler(call);
    });
  }

  setUp(calls.clear);

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(panelChannel, null);
  });

  group('OverlayPanelChannel', () {
    test('names the panel to reopen after capture consent', () async {
      mockPanel((_) async => true);
      await OverlayPanelChannel()
          .requestCaptureConsent(then: OverlayPanelChannel.panelScreen);
      expect(calls.single.method, 'requestCaptureConsent');
      // Without this the user grants consent and lands back at the bubble
      // with nothing captured.
      expect((calls.single.arguments as Map)['then'], 'screen');
    });

    test('reports the live capture state, defaulting to inactive', () async {
      mockPanel((_) async => 'ready');
      expect(await OverlayPanelChannel().captureState(), 'ready');

      // A service that is gone (or too old to know the method) must read as
      // "ask for consent", never as "go ahead and capture".
      mockPanel((_) async => throw PlatformException(code: 'unavailable'));
      expect(await OverlayPanelChannel().captureState(), 'inactive');
    });

    test('a captured frame comes back as PNG bytes with its size', () async {
      final png = Uint8List.fromList([137, 80, 78, 71]);
      mockPanel((call) async => call.method == 'captureFrame'
          ? {'png': png, 'width': 1080, 'height': 2400}
          : null);
      final frame = await OverlayPanelChannel().captureCurrentFrame();
      expect(frame?.png, png);
      expect(frame?.width, 1080);
      expect(frame?.height, 2400);
    });

    test('a captured frame carries the window geometry the crop needs',
        () async {
      mockPanel((call) async => call.method == 'captureFrame'
          ? {
              'png': Uint8List.fromList([137, 80, 78, 71]),
              'width': 665,
              'height': 1440,
              'screenWidth': 1080,
              'screenHeight': 2340,
              'panelLeft': 0,
              'panelTop': 96,
              'panelWidth': 1080,
              'panelHeight': 2244,
            }
          : null);
      final frame = await OverlayPanelChannel().captureCurrentFrame();
      // Without this the selection is mapped as if the overlay covered the
      // whole display, and every crop lands off-target.
      expect(frame?.hasGeometry, isTrue);
      expect(frame?.panelTop, 96);
    });

    test('a failed capture surfaces which failure it was', () async {
      // Swallowing this into a bare null is what made "Snippet failed, try
      // again" cover three unrelated causes.
      mockPanel((_) async => throw PlatformException(code: 'capture_timeout'));
      await expectLater(
        OverlayPanelChannel().captureCurrentFrame(),
        throwsA(isA<CaptureFailure>()
            .having((e) => e.code, 'code', 'capture_timeout')
            .having((e) => e.userMessage, 'userMessage',
                contains('no frame in time'))),
      );

      mockPanel((_) async => throw PlatformException(code: 'capture_inactive'));
      await expectLater(
        OverlayPanelChannel().captureCurrentFrame(),
        throwsA(isA<CaptureFailure>().having(
            (e) => e.userMessage, 'userMessage', contains('permission ended'))),
      );
    });
  });

  group('capture message', () {
    test('leads with the skill trigger sentence, whatever else is added', () {
      // This exact opening is an `analyze_snippet` trigger example; anything
      // in front of it costs the turn its contract (summarize, then offer a
      // follow-up) and its store-the-image step.
      const trigger = 'Analyze this screenshot snippet I captured from my '
          'screen.';

      final snippet = OverlayChatController.composeCaptureMessage(
          fullScreen: false, instruction: '');
      expect(snippet, trigger);

      final screen = OverlayChatController.composeCaptureMessage(
          fullScreen: true, instruction: 'what am I looking at?');
      expect(screen, startsWith(trigger));
      // The model is told the framing before the question, so "what am I
      // looking at" is answered about the whole screen.
      expect(screen, contains('This is my entire screen.'));
      expect(screen, endsWith('what am I looking at?'));
    });

    test('a spoken instruction is appended, never substituted', () {
      final message = OverlayChatController.composeCaptureMessage(
          fullScreen: true, instruction: '  save this link for later  ');
      expect(message,
          'Analyze this screenshot snippet I captured from my screen. '
          'This is my entire screen. save this link for later');
    });
  });

  group('VoiceInputController', () {
    const speechChannel = MethodChannel('plugin.csdcorp.com/speech_to_text');

    tearDown(() {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(speechChannel, null);
    });

    test('an unavailable recognizer explains how to grant the mic', () async {
      // What the plugin returns from a Service-hosted engine when RECORD_AUDIO
      // has never been granted: false, with no prompt shown, because there is
      // no Activity to show one from.
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(
              speechChannel,
              (call) async => call.method == 'initialize' ? false : null);

      final controller = VoiceInputController();
      addTearDown(controller.dispose);
      await controller.start();

      expect(controller.state.listening, isFalse);
      expect(controller.state.error, VoiceInputController.micPermissionMessage);
      // The message has to name the fix, since the overlay cannot perform it.
      expect(controller.state.error, contains('Transcribe'));
    });

    test('seeds from what is already typed so nothing is overwritten',
        () async {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(speechChannel, (call) async {
        return switch (call.method) {
          'initialize' => true,
          'listen' => true,
          'stop' => true,
          _ => null,
        };
      });

      final controller = VoiceInputController();
      addTearDown(controller.dispose);
      await controller.start(seed: 'Remind me to ');

      expect(controller.state.listening, isTrue);
      expect(controller.state.text, 'Remind me to');
      expect(controller.state.error, isNull);
    });
  });
}
