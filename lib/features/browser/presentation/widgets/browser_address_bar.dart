import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../../../shared/theme/app_theme.dart';

/// Where the address goes, and where a new one is typed.
///
/// It shows the page's address until you click into it, and what you are typing
/// after that — the same field doing both jobs, the way a browser's does. The
/// field is only pushed back to the page's address when it isn't being edited,
/// so a redirect landing mid-sentence can't rewrite what the user is halfway
/// through typing.
class BrowserAddressBar extends StatefulWidget {
  const BrowserAddressBar({
    super.key,
    required this.url,
    required this.onSubmit,
  });

  /// The address of the page on screen. Empty in a tab nothing has been asked
  /// of yet, which is what puts the hint on screen instead.
  final String url;

  final ValueChanged<String> onSubmit;

  @override
  State<BrowserAddressBar> createState() => _BrowserAddressBarState();
}

class _BrowserAddressBarState extends State<BrowserAddressBar> {
  final _text = TextEditingController();
  final _focus = FocusNode();

  @override
  void initState() {
    super.initState();
    _text.text = widget.url;
    _focus.addListener(_onFocusChanged);
  }

  @override
  void didUpdateWidget(BrowserAddressBar old) {
    super.didUpdateWidget(old);
    // The page moved — a link, a redirect, Back. Only while nobody is typing:
    // see the class comment.
    if (widget.url == old.url || _focus.hasFocus) return;
    _text.text = widget.url;
  }

  @override
  void dispose() {
    _focus.removeListener(_onFocusChanged);
    _focus.dispose();
    _text.dispose();
    super.dispose();
  }

  void _onFocusChanged() {
    if (_focus.hasFocus) {
      // Clicking the bar selects the address, so typing replaces it rather than
      // landing in the middle of it — what every browser does, and what stops a
      // new address arriving as `https://old.example.comnew`.
      _text.selection = TextSelection(
        baseOffset: 0,
        extentOffset: _text.text.length,
      );
      return;
    }
    // Left without submitting: put the page's real address back, so the bar
    // never sits there naming somewhere the tab is not.
    _text.text = widget.url;
  }

  void _submit(String value) {
    // The page takes the keyboard from here, so what was typed can be read on
    // screen instead of staying selected in a field nobody is in.
    _focus.unfocus();
    widget.onSubmit(value);
  }

  @override
  Widget build(BuildContext context) {
    AppTheme.watch(context);
    return DecoratedBox(
      decoration: BoxDecoration(
        color: AppSurface.recess,
        borderRadius: BorderRadius.circular(AppControl.radius),
      ),
      // Escape hands the keyboard back without navigating — the way out of a
      // field you clicked into by accident, and what stops the key reaching
      // the page behind it while the bar has focus.
      child: CallbackShortcuts(
        bindings: {
          const SingleActivator(LogicalKeyboardKey.escape): _focus.unfocus,
        },
        child: TextField(
          controller: _text,
          focusNode: _focus,
          onSubmitted: _submit,
          textInputAction: TextInputAction.go,
          // The field fills the height the toolbar gives it and centres the
          // text inside that. It used to be wrapped in a `Center`, which sizes
          // the field to the font's own line box instead — and that box is not
          // symmetric (a font reserves more room under the baseline than over
          // it), so the address sat visibly high in the pill.
          textAlignVertical: TextAlignVertical.center,
          style: TextStyle(fontSize: 12.5, color: AppPalette.textPrimary),
          maxLines: 1,
          decoration: InputDecoration(
            isDense: true,
            filled: false,
            hintText: 'Search or enter an address',
            hintStyle: TextStyle(fontSize: 12.5, color: AppPalette.textFaint),
            border: InputBorder.none,
            enabledBorder: InputBorder.none,
            focusedBorder: InputBorder.none,
            // Horizontal only: the vertical placement is
            // [TextAlignVertical.center]'s job, and padding here would fight
            // it.
            contentPadding: const EdgeInsets.symmetric(horizontal: 10),
          ),
        ),
      ),
    );
  }
}
