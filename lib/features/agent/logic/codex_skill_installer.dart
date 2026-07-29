import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/grid_paths.dart';
import 'grid_web_skill.dart';

/// Installs the skills Codex needs to do what the app implies it can — right now
/// just web search, the one capability Codex can't get any other way on a grid.
///
/// Codex reads skills from `~/.codex/skills/<name>/`, auto-discovering each by
/// its `SKILL.md` frontmatter, exactly as Hermes does under `~/.hermes/skills`.
/// So the same [writeGridWebSkill] serves both — one script, one card, two homes
/// — and search behaves the same whichever agent is answering.
class CodexSkillInstaller {
  CodexSkillInstaller({String? home}) : _home = home ?? GridPaths.userHome;

  final String _home;

  Directory _skillDir(String name) => Directory('$_home/.codex/skills/$name');

  /// Write (or refresh) the grid skills. Idempotent — safe to call every time the
  /// app points Codex at a grid.
  Future<void> install() async {
    await writeGridWebSkill(_skillDir(kGridWebSkillName));
  }
}

/// Wire through the container so callers get it via `ref.read`, and tests can
/// point it at a temp home.
final codexSkillInstallerProvider = Provider<CodexSkillInstaller>(
  (ref) => CodexSkillInstaller(),
);
