import 'package:flutter/material.dart';

import '../../shared/theme/exa_theme.dart';

/// Fullscreen region selector for screen snippets.
///
/// The native overlay service captures only after the user picks a region, so
/// this layer stays transparent over the app underneath and then asks native
/// for a single frame when the drag ends.
class SnippetSelectionScreen extends StatefulWidget {
  const SnippetSelectionScreen({
    super.key,
    required this.onSnap,
    required this.onCancel,
    required this.onRetryPermission,
    this.errorText,
  });

  /// [selection] is in this widget's own coordinate space, [panelSize] its
  /// size - not the display's. The overlay window can be inset from the
  /// screen, so mapping the two is the caller's job (see
  /// `CapturedFrame.mapSelectionToImage`).
  final Future<void> Function(Rect selection, Size panelSize) onSnap;
  final VoidCallback onCancel;
  final Future<void> Function() onRetryPermission;
  final String? errorText;

  @override
  State<SnippetSelectionScreen> createState() => _SnippetSelectionScreenState();
}

class _SnippetSelectionScreenState extends State<SnippetSelectionScreen> {
  Offset? _dragStart;
  Rect? _selection;
  Size? _panelSize;
  bool _snapping = false;

  bool get _hasUsableSelection {
    final sel = _selection;
    return sel != null && sel.width > 24 && sel.height > 24;
  }

  @override
  Widget build(BuildContext context) {
    final statusText = _snapping
        ? 'Snapping...'
        : widget.errorText ?? 'Drag a region to snap';

    return Stack(
      children: [
        Positioned.fill(
          child: LayoutBuilder(
            builder: (context, constraints) {
              _panelSize = Size(constraints.maxWidth, constraints.maxHeight);
              return GestureDetector(
                behavior: HitTestBehavior.opaque,
                onPanStart: _snapping
                    ? null
                    : (details) => setState(() {
                        _dragStart = details.localPosition;
                        _selection = Rect.fromPoints(
                          _dragStart!,
                          details.localPosition,
                        );
                      }),
                onPanUpdate: _snapping
                    ? null
                    : (details) => setState(() {
                        _selection = Rect.fromPoints(
                          _dragStart!,
                          details.localPosition,
                        );
                      }),
                onPanEnd: _snapping ? null : (_) => _snapSelection(),
                child: CustomPaint(
                  painter: _SelectionPainter(_selection),
                  child: const SizedBox.expand(),
                ),
              );
            },
          ),
        ),
        Positioned(
          left: 12,
          right: 12,
          top: 0,
          child: SafeArea(
            bottom: false,
            child: _SnippetToolbar(
              statusText: statusText,
              snapping: _snapping,
              onCancel: widget.onCancel,
              onRetryPermission: widget.onRetryPermission,
            ),
          ),
        ),
        Positioned(
          left: 12,
          right: 12,
          bottom: 0,
          child: SafeArea(
            top: false,
            child: Align(
              alignment: Alignment.centerRight,
              child: FilledButton.icon(
                onPressed: _snapping ? null : _snapFullScreen,
                icon: _snapping
                    ? const SizedBox(
                        width: 16,
                        height: 16,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.fullscreen),
                label: const Text('Snap full screen'),
              ),
            ),
          ),
        ),
      ],
    );
  }

  Future<void> _snapSelection() async {
    if (!_hasUsableSelection) return;
    await _snap(_selection!);
  }

  Future<void> _snapFullScreen() async {
    final size = _panelSize;
    if (size == null) return;
    await _snap(Offset.zero & size);
  }

  Future<void> _snap(Rect selection) async {
    final size = _panelSize;
    if (size == null || _snapping) return;
    setState(() => _snapping = true);
    try {
      await widget.onSnap(selection, size);
    } finally {
      if (mounted) setState(() => _snapping = false);
    }
  }
}

class _SnippetToolbar extends StatelessWidget {
  const _SnippetToolbar({
    required this.statusText,
    required this.snapping,
    required this.onCancel,
    required this.onRetryPermission,
  });

  final String statusText;
  final bool snapping;
  final VoidCallback onCancel;
  final Future<void> Function() onRetryPermission;

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: BoxDecoration(
        color: Colors.black.withValues(alpha: 0.68),
        border: Border.all(color: ExaColors.outline),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 6, 4, 6),
        child: Row(
          children: [
            const Icon(Icons.crop, size: 18, color: ExaColors.spark),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                statusText,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(color: ExaColors.textPrimary),
              ),
            ),
            if (statusText.startsWith('Screen capture permission'))
              TextButton(
                onPressed: snapping ? null : onRetryPermission,
                child: const Text('Retry'),
              ),
            IconButton(
              icon: const Icon(Icons.close, size: 20),
              tooltip: 'Close',
              onPressed: snapping ? null : onCancel,
            ),
          ],
        ),
      ),
    );
  }
}

/// Dims everything outside the selection and outlines it in the accent.
class _SelectionPainter extends CustomPainter {
  _SelectionPainter(this.selection);

  final Rect? selection;

  @override
  void paint(Canvas canvas, Size size) {
    final sel = selection;
    final dim = Paint()..color = const Color(0x66000000);
    if (sel == null) {
      canvas.drawRect(Offset.zero & size, dim);
      return;
    }
    final outside = Path()
      ..addRect(Offset.zero & size)
      ..addRect(sel)
      ..fillType = PathFillType.evenOdd;
    canvas.drawPath(outside, dim);
    canvas.drawRect(
      sel,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2
        ..color = ExaColors.accent,
    );
  }

  @override
  bool shouldRepaint(_SelectionPainter oldDelegate) =>
      oldDelegate.selection != selection;
}
