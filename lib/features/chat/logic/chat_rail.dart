import 'package:flutter_riverpod/flutter_riverpod.dart';

/// Whether the project rail beside a chat is open.
///
/// On by default and toggled from the top bar. It never *auto*-hides: when the
/// pane is too narrow to sit the rail beside the conversation, the rail opens as
/// an overlay instead of vanishing — so the toggle is always the way back in and
/// the panel never disappears with no way to reopen it.
final chatRailOpenProvider = NotifierProvider<ChatRailOpen, bool>(
  ChatRailOpen.new,
);

class ChatRailOpen extends Notifier<bool> {
  @override
  bool build() => true;

  void toggle() => state = !state;

  void set(bool open) => state = open;
}
