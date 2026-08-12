import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';

/// The three things the Code side panel can show, rooted at the project's local
/// clone — the same trio the chat's panel carries, in the same order.
enum CodePanelTab {
  files('Files'),
  review('Review'),
  terminal('Terminal');

  const CodePanelTab(this.label);

  final String label;
}

/// Whether the Code side panel is open. Off by default: the conversation is what
/// the screen is for, and a panel that lets itself in takes a third of the pane
/// before anyone has read a line.
final codeSidePanelOpenProvider = NotifierProvider<CodeSidePanelOpen, bool>(
  CodeSidePanelOpen.new,
);

class CodeSidePanelOpen extends Notifier<bool> {
  @override
  bool build() => false;

  void toggle() => state = !state;

  void close() => state = false;
}

/// Which tab the side panel is showing.
final codeSidePanelTabProvider =
    NotifierProvider<CodeSidePanelTab, CodePanelTab>(CodeSidePanelTab.new);

class CodeSidePanelTab extends Notifier<CodePanelTab> {
  @override
  CodePanelTab build() => CodePanelTab.files;

  void select(CodePanelTab tab) => state = tab;
}

/// Whether the project's working copy exists on disk yet, so the panel can offer
/// to fetch it rather than open a terminal onto nothing. Keyed by the clone
/// path; the button that fetches invalidates this.
final codeCloneExistsProvider = FutureProvider.autoDispose.family<bool, String>(
  (ref, path) => Directory(path).exists(),
);

/// A message Review wants the user to send about a diff, offered to the task
/// composer rather than sent — the same manners as the chat's
/// `composerPrefillProvider`: which agent and model answer are the grid's to
/// pick, and a panel firing a task off on the user's behalf would spend a task
/// slot on a turn they never wrote.
final codeComposerPrefillProvider =
    NotifierProvider<CodeComposerPrefill, String?>(CodeComposerPrefill.new);

class CodeComposerPrefill extends Notifier<String?> {
  @override
  String? build() => null;

  void offer(String text) => state = text;

  void taken() => state = null;
}
