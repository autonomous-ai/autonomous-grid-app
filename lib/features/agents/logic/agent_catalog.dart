import 'package:flutter/material.dart';

/// The agents the app knows about — the ones that can be put in charge of a
/// chat, and the ones that are coming.
///
/// Only Hermes can run today: the `grid` CLI installs that and nothing else
/// (`grid agent install {hermes}`). The rest are listed so the screen says what
/// it will support instead of pretending the list is finished — but they carry
/// no controls, because a button that can't do anything is worse than none.
enum AgentTool {
  hermes(
    id: 'hermes',
    name: 'Hermes',
    tagline:
        'Runs on this computer. Uses your model, reads the project '
        'folder you point it at, and can run tools.',
    runnable: true,
    accent: Color(0xFF2F5BEA),
    icon: Icons.bolt_rounded,
  ),
  codex(
    id: 'codex',
    name: 'Codex',
    tagline: "OpenAI's coding agent.",
    runnable: false,
    accent: Color(0xFF16A34A),
    icon: Icons.terminal_rounded,
  ),
  openclaw(
    id: 'openclaw',
    name: 'OpenClaw',
    tagline: 'An open-source agent.',
    runnable: false,
    accent: Color(0xFFF97316),
    icon: Icons.pets_rounded,
  );

  const AgentTool({
    required this.id,
    required this.name,
    required this.tagline,
    required this.runnable,
    required this.accent,
    required this.icon,
  });

  /// What `grid agent install` calls it.
  final String id;

  final String name;

  /// One line: what it is, in the user's terms.
  final String tagline;

  /// Whether the app can actually install and run it today. False means the
  /// screen shows it as planned — no install button, no toggle.
  final bool runnable;

  /// The agent's own colour — its icon chip's tint and the rim it lifts to on
  /// hover, so each row reads as its own thing rather than a repeated robot.
  final Color accent;

  /// A glyph that hints at what the agent is, instead of one shared robot icon.
  final IconData icon;
}

/// The agent that answers chats today. Named rather than assumed, so the day a
/// second one becomes runnable the places that assume "the agent" are findable.
const AgentTool kChatAgent = AgentTool.hermes;
