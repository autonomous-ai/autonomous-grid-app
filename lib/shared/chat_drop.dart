import 'package:flutter/foundation.dart';

/// Something on its way to the conversation under the pointer.
///
/// Sealed, and one type for both kinds, because the chat takes them at one
/// place: a single `DragTarget<ChatDrop>` lights up for everything the message
/// can carry and switches on what actually landed. Two targets, one per kind,
/// would be two chances for a drop to fall between them.
///
/// A type of its own rather than the bare path or id it carries. A
/// `DragTarget<String>` would light up for anything anybody in the app ever
/// decides to drag, and what a message will take is a decision worth naming out
/// loud rather than leaving to whichever strings happen to fly past.
@immutable
sealed class ChatDrop {
  const ChatDrop();
}

/// A file, dragged out of the Files panel's tree.
class FileDrop extends ChatDrop {
  const FileDrop(this.path);

  /// Where the file is on disk, absolute — the same form "Add to chat" hands
  /// over, so both gestures end in the same place.
  final String path;
}

/// A terminal, dragged by its tab out of a panel's tab strip.
///
/// The id, not the text on screen: what the message carries is read when Send is
/// pressed, not when the tab is dropped. A build still running at the drop has
/// usually finished by the time the question about it goes.
class TerminalDrop extends ChatDrop {
  const TerminalDrop({required this.tabId, required this.label});

  final String tabId;

  /// What the tab was called, kept for the chip. Read at the drop because the
  /// chip has to name something even after the tab it came from is closed.
  final String label;
}
