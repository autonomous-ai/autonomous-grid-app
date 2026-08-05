import 'package:flutter_riverpod/flutter_riverpod.dart';

/// Whether the app's window is the one the user is looking at.
///
/// Kept as state rather than asked for on demand: `windowManager.isFocused()` is
/// async, and the decisions that need this answer — chiefly "does this finished
/// reply deserve a desktop notification?" — are made inside a synchronous state
/// update where awaiting isn't an option.
///
/// Starts true: the window is shown and focused at launch (see `main`), and a
/// wrong `false` would announce the very first reply the user is watching stream
/// in. [WindowLifecycleScope] keeps it honest from there.
final windowFocusedProvider = NotifierProvider<WindowFocusController, bool>(
  WindowFocusController.new,
);

class WindowFocusController extends Notifier<bool> {
  @override
  bool build() => true;

  void set({required bool focused}) {
    if (state == focused) return;
    state = focused;
  }
}
