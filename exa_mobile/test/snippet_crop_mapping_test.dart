import 'dart:typed_data';
import 'dart:ui';

import 'package:exa_mobile/services/overlay/overlay_panel_channel.dart';
import 'package:flutter_test/flutter_test.dart';

/// The snippet selector draws in its own window, which the system can inset
/// from the display (status bar, cutout, gesture area) while the captured
/// frame always covers the whole display. Mapping one onto the other is what
/// decides whether a crop lands where the user dragged.
void main() {
  CapturedFrame frame({
    required int width,
    required int height,
    int screenWidth = 0,
    int screenHeight = 0,
    int panelLeft = 0,
    int panelTop = 0,
    int panelWidth = 0,
    int panelHeight = 0,
  }) =>
      CapturedFrame(
        png: Uint8List(0),
        width: width,
        height: height,
        screenWidth: screenWidth,
        screenHeight: screenHeight,
        panelLeft: panelLeft,
        panelTop: panelTop,
        panelWidth: panelWidth,
        panelHeight: panelHeight,
      );

  group('CapturedFrame.mapSelectionToImage', () {
    test('a panel covering the display maps by device pixel ratio alone', () {
      final f = frame(
        width: 1000,
        height: 2000,
        screenWidth: 1000,
        screenHeight: 2000,
        panelWidth: 1000,
        panelHeight: 2000,
      );

      expect(
        f.mapSelectionToImage(
            const Rect.fromLTRB(100, 200, 300, 400), const Size(500, 1000)),
        const Rect.fromLTRB(200, 400, 600, 800),
      );
    });

    test('a panel inset from the top maps by the inset, not by ratio', () {
      // 100px of status bar above the window: the panel is 1900px tall on a
      // 2000px screen, so y=200 logical is 500px down the frame - not 421.
      final f = frame(
        width: 1000,
        height: 2000,
        screenWidth: 1000,
        screenHeight: 2000,
        panelTop: 100,
        panelWidth: 1000,
        panelHeight: 1900,
      );

      expect(
        f.mapSelectionToImage(
            const Rect.fromLTRB(100, 200, 300, 400), const Size(500, 950)),
        const Rect.fromLTRB(200, 500, 600, 900),
      );
    });

    test('the frame downscale is applied on top of the window mapping', () {
      // Native caps the long edge, so the frame is half the display here.
      final f = frame(
        width: 500,
        height: 1000,
        screenWidth: 1000,
        screenHeight: 2000,
        panelWidth: 1000,
        panelHeight: 2000,
      );

      expect(
        f.mapSelectionToImage(
            const Rect.fromLTRB(100, 200, 300, 400), const Size(500, 1000)),
        const Rect.fromLTRB(100, 200, 300, 400),
      );
    });

    test('the decoded image size wins over the size native reported', () {
      final f = frame(
        width: 1,
        height: 1,
        screenWidth: 1000,
        screenHeight: 2000,
        panelWidth: 1000,
        panelHeight: 2000,
      );

      expect(
        f.mapSelectionToImage(
          const Rect.fromLTRB(100, 200, 300, 400),
          const Size(500, 1000),
          imageSize: const Size(1000, 2000),
        ),
        const Rect.fromLTRB(200, 400, 600, 800),
      );
    });

    test('without geometry it falls back to assuming a full-screen panel', () {
      final f = frame(width: 1000, height: 2000);

      expect(
        f.mapSelectionToImage(
            const Rect.fromLTRB(100, 200, 300, 400), const Size(500, 1000)),
        const Rect.fromLTRB(200, 400, 600, 800),
      );
    });

    test('a selection running past the panel clamps inside the frame', () {
      final f = frame(
        width: 1000,
        height: 2000,
        screenWidth: 1000,
        screenHeight: 2000,
        panelTop: 100,
        panelWidth: 1000,
        panelHeight: 1900,
      );

      expect(
        f.mapSelectionToImage(
            const Rect.fromLTRB(-50, -50, 900, 2000), const Size(500, 950)),
        const Rect.fromLTRB(0, 0, 1000, 2000),
      );
    });

    test('a zero-sized panel maps to nothing rather than dividing by zero', () {
      final f = frame(width: 1000, height: 2000);

      expect(
        f.mapSelectionToImage(
            const Rect.fromLTRB(0, 0, 10, 10), const Size(0, 0)),
        Rect.zero,
      );
    });
  });
}
