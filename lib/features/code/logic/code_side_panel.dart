import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../shared/panels/panel_tabs.dart';

/// Whether the Code side panel is open. Off by default: the conversation is what
/// the screen is for, and a panel that lets itself in takes a third of the pane
/// before anyone has read a line.
///
/// The shared panel flag, under the name Code's own files use — the panel beside
/// a project is the same panel as the one beside a chat, tabs, launcher and all
/// (see [PanelHost.code]).
final codeSidePanelOpenProvider = panelOpenProvider(PanelHost.code);

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
