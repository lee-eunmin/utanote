import 'package:flutter/gestures.dart';
import 'package:flutter/widgets.dart';

/// App-wide "tap outside the text field closes the keyboard".
///
/// Placed once above the [Navigator] (`MaterialApp.builder`), so it covers
/// every screen, bottom sheet and dialog without per-screen gesture
/// detectors. It overrides the two intents every [EditableText] invokes
/// through its [TapRegion] when a pointer goes down/up outside the field
/// (and outside its toolbar/handles), so it never joins the gesture arena:
/// buttons, the bottom navigation bar, sheets and scrolling keep working
/// exactly as before.
///
/// Touch: the field is unfocused on pointer **up**, and only for a tap
/// (the finger moved less than [kTouchSlop]). A tap on another text field
/// moves focus in the same event, so the keyboard stays up instead of
/// closing and reopening; a scroll/drag outside the field does not close
/// it (scroll views opt into that via `keyboardDismissBehavior`). Only the
/// field's own [FocusNode] is unfocused, so a field that was focused in the
/// meantime (e.g. by a sheet the tap opened) keeps its focus.
///
/// Other pointer kinds (mouse, stylus, …) keep Flutter's default action.
class DismissKeyboardOnTapOutside extends StatefulWidget {
  final Widget child;

  const DismissKeyboardOnTapOutside({super.key, required this.child});

  @override
  State<DismissKeyboardOnTapOutside> createState() =>
      _DismissKeyboardOnTapOutsideState();
}

class _DismissKeyboardOnTapOutsideState
    extends State<DismissKeyboardOnTapOutside> {
  late final _tracker = _TapOutsideTracker();
  late final Map<Type, Action<Intent>> _actions = {
    EditableTextTapOutsideIntent: _TapOutsideDownAction(_tracker),
    EditableTextTapUpOutsideIntent: _TapOutsideUpAction(_tracker),
  };

  @override
  Widget build(BuildContext context) =>
      Actions(actions: _actions, child: widget.child);
}

/// The touch-down outside a focused field, waiting for its pointer-up.
class _TapOutsideTracker {
  FocusNode? node;
  int? pointer;
  Offset? position;

  void clear() {
    node = null;
    pointer = null;
    position = null;
  }
}

class _TapOutsideDownAction extends ContextAction<EditableTextTapOutsideIntent> {
  final _TapOutsideTracker _tracker;

  _TapOutsideDownAction(this._tracker);

  @override
  Object? invoke(EditableTextTapOutsideIntent intent, [BuildContext? context]) {
    final down = intent.pointerDownEvent;
    if (down.kind == PointerDeviceKind.touch) {
      _tracker
        ..node = intent.focusNode
        ..pointer = down.pointer
        ..position = down.position;
      return null;
    }
    _tracker.clear();
    // Mouse/stylus/…: Flutter's own behavior.
    return callingAction?.invoke(intent);
  }
}

class _TapOutsideUpAction extends ContextAction<EditableTextTapUpOutsideIntent> {
  final _TapOutsideTracker _tracker;

  _TapOutsideUpAction(this._tracker);

  @override
  Object? invoke(
    EditableTextTapUpOutsideIntent intent, [
    BuildContext? context,
  ]) {
    final up = intent.pointerUpEvent;
    final isTap =
        identical(_tracker.node, intent.focusNode) &&
        _tracker.pointer == up.pointer &&
        _tracker.position != null &&
        (up.position - _tracker.position!).distance <= kTouchSlop;
    if (identical(_tracker.node, intent.focusNode)) _tracker.clear();
    if (isTap && intent.focusNode.hasFocus) intent.focusNode.unfocus();
    return null;
  }
}
