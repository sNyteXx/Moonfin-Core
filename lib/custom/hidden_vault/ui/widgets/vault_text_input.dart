import 'package:custom_tv_text_field/custom_tv_text_field.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:get_it/get_it.dart';

import '../../../../preference/user_preferences.dart';
import '../../../../util/focus/dpad_keys.dart';
import '../../../../util/platform_detection.dart';

/// A text field that works with a D-pad: select opens the app's TV keyboard,
/// back closes it. Off TV it's a plain [TextField].
class VaultTextInput extends StatefulWidget {
  final TextEditingController controller;
  final String hint;
  final ValueChanged<String> onSubmitted;
  final bool autofocus;
  final FocusNode? focusNode;

  const VaultTextInput({
    super.key,
    required this.controller,
    required this.hint,
    required this.onSubmitted,
    this.autofocus = false,
    this.focusNode,
  });

  @override
  State<VaultTextInput> createState() => _VaultTextInputState();
}

class _VaultTextInputState extends State<VaultTextInput> {
  final _tvKey = GlobalKey<CustomTVTextFieldState>();
  FocusNode? _ownNode;

  FocusNode get _node => widget.focusNode ?? (_ownNode ??= FocusNode());

  @override
  void dispose() {
    _ownNode?.dispose();
    super.dispose();
  }

  KeyEventResult _onKey(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent) return KeyEventResult.ignored;
    final field = _tvKey.currentState;
    if (event.logicalKey.isBackKey && (field?.isKeyboardVisible ?? false)) {
      field?.closeKeyboard();
      _node.requestFocus();
      return KeyEventResult.handled;
    }
    if (event.logicalKey.isSelectKey ||
        event.logicalKey == LogicalKeyboardKey.enter) {
      field?.openKeyboard();
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    if (!PlatformDetection.isTV) {
      return TextField(
        controller: widget.controller,
        focusNode: _node,
        autofocus: widget.autofocus,
        onSubmitted: widget.onSubmitted,
        decoration: InputDecoration(
          hintText: widget.hint,
          border: const OutlineInputBorder(),
        ),
      );
    }
    final preferIme = GetIt.instance.isRegistered<UserPreferences>() &&
        GetIt.instance<UserPreferences>().get(
          UserPreferences.preferSystemImeKeyboard,
        );
    return Focus(
      focusNode: _node,
      autofocus: widget.autofocus,
      onKeyEvent: _onKey,
      child: ListenableBuilder(
        listenable: _node,
        builder: (context, _) {
          final focused = _node.hasFocus;
          return CustomTVTextField(
            key: _tvKey,
            controller: widget.controller,
            isFocused: focused,
            hint: widget.hint,
            preferSystemIme: preferIme,
            keyboardType: KeyboardType.alphabetic,
            filled: true,
            fillColor: focused
                ? scheme.primaryContainer
                : scheme.surfaceContainerHighest.withValues(alpha: 0.6),
            borderColor: scheme.outline,
            focusedBorderColor: scheme.primary,
            textStyle: TextStyle(color: scheme.onSurface, fontSize: 18),
            hintStyle: TextStyle(
              color: scheme.onSurface.withValues(alpha: 0.6),
              fontSize: 18,
            ),
            popParentOnKeyboardClose: false,
            onFieldSubmitted: widget.onSubmitted,
          );
        },
      ),
    );
  }
}
