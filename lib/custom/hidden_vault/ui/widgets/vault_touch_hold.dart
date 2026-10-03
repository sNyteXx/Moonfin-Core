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
/// Moving the finger, as when scrolling the row, cancels the press.
/// Without [enabled] the child is returned untouched.
///
/// The timing reads raw pointer events, so it works whatever recognizers the
/// tile itself has: a card that keeps a long press recognizer of its own
/// would otherwise win the gesture arena and the hold would never start. A
/// long press recognizer of our own still joins the arena, so a press held
/// past the long press timeout never also counts as a tap.
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
  int? _pointer;
  Offset _origin = Offset.zero;
  Timer? _longPressTimer;
  Timer? _holdTimer;
  bool _pastLongPress = false;
  bool _held = false;

  void _down(PointerDownEvent event) {
    if (_pointer != null) return;
    if (event.kind == PointerDeviceKind.mouse &&
        event.buttons != kPrimaryMouseButton) {
      return;
    }
    _pointer = event.pointer;
    _origin = event.position;
    _longPressTimer = Timer(kLongPressTimeout, () => _pastLongPress = true);
    _holdTimer = Timer(widget.holdAfter, () {
      _holdTimer = null;
      _held = true;
      if (mounted) widget.onHold();
    });
  }

  void _move(PointerMoveEvent event) {
    if (event.pointer != _pointer) return;
    if ((event.position - _origin).distance > kTouchSlop) _reset();
  }

  void _up(PointerUpEvent event) {
    if (event.pointer != _pointer) return;
    final menu = _pastLongPress && !_held;
    _reset();
    if (menu) widget.onLongPress?.call();
  }

  void _cancel(PointerCancelEvent event) {
    if (event.pointer == _pointer) _reset();
  }

  void _reset() {
    _longPressTimer?.cancel();
    _holdTimer?.cancel();
    _longPressTimer = null;
    _holdTimer = null;
    _pointer = null;
    _pastLongPress = false;
    _held = false;
  }

  @override
  void didUpdateWidget(VaultTouchHold oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!widget.enabled) _reset();
  }

  @override
  void dispose() {
    _reset();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (!widget.enabled) return widget.child;
    return Listener(
      behavior: HitTestBehavior.deferToChild,
      onPointerDown: _down,
      onPointerMove: _move,
      onPointerUp: _up,
      onPointerCancel: _cancel,
      child: RawGestureDetector(
        behavior: HitTestBehavior.deferToChild,
        gestures: {
          LongPressGestureRecognizer:
              GestureRecognizerFactoryWithHandlers<LongPressGestureRecognizer>(
                () => LongPressGestureRecognizer(debugOwner: this),
                (recognizer) {
                  // Only here to win over a tap; the timing is above.
                  recognizer.onLongPress = () {};
                },
              ),
        },
        child: widget.child,
      ),
    );
  }
}
