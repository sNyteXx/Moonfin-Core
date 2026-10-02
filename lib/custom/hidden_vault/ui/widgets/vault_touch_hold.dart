import 'dart:async';

import 'package:flutter/gestures.dart';
import 'package:flutter/widgets.dart';

import '../../../../util/focus/key_event_utils.dart';

/// The touch and mouse counterpart of the D-pad hold on a trigger tile.
///
/// The tile's own long press has to be switched off for this to see the
/// gesture. A tap still goes to the tile. Holding past the usual long press
/// and letting go before [holdAfter] opens the context menu, on release;
/// keeping the finger down for [holdAfter] runs [onHold] and nothing else.
/// Without [enabled] the child is returned untouched.
class VaultTouchHold extends StatefulWidget {
  final bool enabled;
  final VoidCallback onHold;
  final VoidCallback? onLongPress;
  final Duration holdAfter;
  final Widget child;

  const VaultTouchHold({
    super.key,
    required this.enabled,
    required this.onHold,
    required this.child,
    this.onLongPress,
    this.holdAfter = SelectHoldGesture.defaultHoldAfter,
  });

  @override
  State<VaultTouchHold> createState() => _VaultTouchHoldState();
}

class _VaultTouchHoldState extends State<VaultTouchHold> {
  Timer? _holdTimer;
  bool _held = false;

  void _start() {
    _held = false;
    _holdTimer?.cancel();
    final remaining = widget.holdAfter - kLongPressTimeout;
    _holdTimer = Timer(remaining.isNegative ? Duration.zero : remaining, () {
      _holdTimer = null;
      _held = true;
      if (mounted) widget.onHold();
    });
  }

  void _end() {
    final pending = _holdTimer != null;
    _holdTimer?.cancel();
    _holdTimer = null;
    if (pending && !_held) widget.onLongPress?.call();
    _held = false;
  }

  void _cancel() {
    _holdTimer?.cancel();
    _holdTimer = null;
    _held = false;
  }

  @override
  void dispose() {
    _holdTimer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (!widget.enabled) return widget.child;
    return RawGestureDetector(
      behavior: HitTestBehavior.deferToChild,
      gestures: {
        LongPressGestureRecognizer:
            GestureRecognizerFactoryWithHandlers<LongPressGestureRecognizer>(
              () => LongPressGestureRecognizer(debugOwner: this),
              (recognizer) {
                recognizer
                  ..onLongPressStart = ((_) => _start())
                  ..onLongPressEnd = ((_) => _end())
                  ..onLongPressCancel = _cancel;
              },
            ),
      },
      child: widget.child,
    );
  }
}
