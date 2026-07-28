import 'package:flutter_riverpod/flutter_riverpod.dart';

/// The user's manual override of the rail's width-driven default, or null to
/// follow it (shown beside the chat when the window is wide enough for both, the
/// panel stepping aside otherwise).
///
/// Cleared on every chat switch (see the chat pane), so each chat starts from
/// the default again, while a deliberate toggle still sticks within a chat.
final chatRailOverrideProvider = NotifierProvider<ChatRailOverride, bool?>(
  ChatRailOverride.new,
);

class ChatRailOverride extends Notifier<bool?> {
  @override
  bool? build() => null;

  void set(bool open) => state = open;

  void clear() => state = null;
}

/// The rail's resolved visibility, published by the chat pane — which alone
/// knows its own width — so the top-bar toggle can mirror it and flip it.
final chatRailVisibleProvider = NotifierProvider<ChatRailVisible, bool>(
  ChatRailVisible.new,
);

class ChatRailVisible extends Notifier<bool> {
  @override
  bool build() => false;

  void set(bool visible) => state = visible;
}
