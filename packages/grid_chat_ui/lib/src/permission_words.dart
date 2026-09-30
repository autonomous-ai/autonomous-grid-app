/// The words an agent's permission question is put in, on either screen.
///
/// §5's rule — two screens asking the same question share the words — made
/// concrete: the phone now asks what the computer's card asks, and a second
/// copy of these lines is how one of them would start saying "Approve" while
/// the other says "Allow".
library;

import 'package:flutter/material.dart';

/// What the agent wants: to run a command, to change a file, or anything else.
enum PermissionAsk { command, edit, other }

/// The glyph and the question a permission card leads with.
({IconData icon, String question}) permissionHeading(PermissionAsk ask) =>
    switch (ask) {
      PermissionAsk.command => (
        icon: Icons.terminal_rounded,
        question: 'Run this on your computer?',
      ),
      PermissionAsk.edit => (
        icon: Icons.edit_note_rounded,
        question: 'Change this file?',
      ),
      // A tool no screen has a drawing for: the agent's own title and the raw
      // request go under this, rather than a description made up about
      // something that could not be read.
      PermissionAsk.other => (
        icon: Icons.extension_outlined,
        question: 'Let the assistant do this?',
      ),
    };

/// The three answers, as their buttons say them.
abstract final class PermissionAnswerLabels {
  static const allowOnce = 'Allow once';
  static const allowForChat = 'Allow in this chat';
  static const refuse = "Don't allow";
}
