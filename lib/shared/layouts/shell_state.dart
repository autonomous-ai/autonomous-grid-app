import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

/// The screens the sidebar switches between. Chat is the app — the rest is the
/// plumbing behind it (the grids you can talk to, the computer that answers, and
/// how to point other apps at it), one click away rather than buried in a menu.
enum ShellSection {
  chat(Icons.chat_bubble_outline_rounded, 'Chat'),
  grids(Icons.bolt, 'Grids'),
  engines(Icons.dns_outlined, 'This computer'),
  guide(Icons.help_outline_rounded, 'How to use');

  const ShellSection(this.icon, this.label);

  final IconData icon;
  final String label;
}

/// The open section. Chat on launch — that's what the app is for.
///
/// Also the target of in-app deep links: a card that says "Set up engine" flips
/// this to [ShellSection.engines] instead of opening a second window on top.
final shellSectionProvider =
    NotifierProvider<ShellSectionNotifier, ShellSection>(
      ShellSectionNotifier.new,
    );

class ShellSectionNotifier extends Notifier<ShellSection> {
  @override
  ShellSection build() => ShellSection.chat;

  void select(ShellSection section) => state = section;
}
