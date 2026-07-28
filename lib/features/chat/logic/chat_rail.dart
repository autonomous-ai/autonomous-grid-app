import 'package:flutter_riverpod/flutter_riverpod.dart';

/// Whether the project rail shows by default for the chat on screen: on a fresh
/// compose (there's room beside the starters), or on a pane wide enough to sit
/// the rail beside the conversation.
///
/// It only *auto*-hides in the one case where the conversation needs the width:
/// a narrow pane with a conversation already in it. There the top-bar toggle
/// brings it back as an overlay — it never just vanishes with no way in.
bool railShowsByDefault({required bool isNewChat, required bool isWide}) =>
    isNewChat || isWide;

/// The user's manual override of [railShowsByDefault], or null to follow it.
///
/// Cleared on every chat switch (see the chat pane), so each chat starts from
/// the default again — a new chat shows the rail, opening a conversation on a
/// narrow pane hides it — while a deliberate toggle still sticks within a chat.
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
