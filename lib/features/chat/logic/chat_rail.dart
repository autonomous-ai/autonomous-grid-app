import 'package:flutter_riverpod/flutter_riverpod.dart';

/// Whether the user has asked for the project rail, or null while they haven't
/// — in which case it stays hidden, at any window width.
///
/// Sticks once set: a deliberate hide or show carries across chats — in this
/// project and any other — because a preference the user just expressed
/// shouldn't silently reset the moment they open the next conversation. When
/// shown, the window width still decides whether it sits alongside the chat or
/// floats over it as an overlay.
final chatRailOverrideProvider = NotifierProvider<ChatRailOverride, bool?>(
  ChatRailOverride.new,
);

class ChatRailOverride extends Notifier<bool?> {
  @override
  bool? build() => null;

  void set(bool open) => state = open;
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
