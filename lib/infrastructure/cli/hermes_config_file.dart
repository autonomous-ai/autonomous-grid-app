import 'dart:io';

import 'package:yaml_edit/yaml_edit.dart';

import '../../core/grid_paths.dart';

/// Reads and edits Hermes's own `~/.hermes/config.yaml` without disturbing the
/// rest of it.
///
/// Hermes owns this file; the app only edits a couple of corners — what a
/// scheduled task ([HermesTaskPolicy]) and a chat-platform message
/// ([HermesPlatformPolicy]) are each allowed to do. Every write merges into
/// whatever else is in there and keeps a `<file>.bak` first, so a hand-edited
/// config is never clobbered.
class HermesConfigFile {
  HermesConfigFile({String? home}) : _home = home ?? GridPaths.userHome;

  final String _home;

  File get _file => File('$_home/.hermes/config.yaml');

  /// The value at [path], or null when the config says nothing there.
  Future<Object?> valueAt(List<String> path) async {
    final text = await _read();
    if (text == null) return null;
    return YamlEditor(
      text,
    ).parseAt(path, orElse: () => wrapAsYamlNode(null)).value;
  }

  /// Apply [mutate] to the config, backing the old file up to `<file>.bak`
  /// first. A file that has never existed starts from an empty map so the first
  /// write still lands.
  Future<void> edit(void Function(YamlEditor editor) mutate) async {
    final text = await _read() ?? '';
    final editor = YamlEditor(text.trim().isEmpty ? '{}\n' : text);
    mutate(editor);
    await _file.parent.create(recursive: true);
    if (await _file.exists()) await _file.copy('${_file.path}.bak');
    await _file.writeAsString('${editor.toString().trimRight()}\n');
  }

  Future<String?> _read() async {
    if (!await _file.exists()) return null;
    final text = await _file.readAsString();
    return text.trim().isEmpty ? null : text;
  }

  /// Set [path], creating the parent map when the config has never had one.
  static void upsert(YamlEditor editor, List<String> path, Object value) {
    final parent = path.sublist(0, path.length - 1);
    final existing = editor
        .parseAt(parent, orElse: () => wrapAsYamlNode(null))
        .value;
    if (existing is! Map) {
      editor.update(parent, {path.last: value});
      return;
    }
    editor.update(path, value);
  }

  /// Drop [path] if it's there. A key that was never written is already gone.
  static void remove(YamlEditor editor, List<String> path) {
    final existing = editor
        .parseAt(path, orElse: () => wrapAsYamlNode(null))
        .value;
    if (existing == null) return;
    editor.remove(path);
  }
}

/// How many tool calls Hermes may make inside one turn before it stops.
///
/// Hermes's own default, written into the config on purpose: at the cap it
/// doesn't fail or say anything over ACP — it quietly injects "You've reached
/// the maximum number of tool-calling iterations allowed", makes the model
/// summarise, and returns `stopReason: end_turn` like any finished turn
/// (`acp_adapter/server.py` has no other reason to give). A turn that stopped
/// three steps into a five-step plan then looked exactly like one that was
/// done. Writing the number here makes it *ours*: the app counts the turn's
/// tool calls against it and can say what happened (see [agentSpentToolBudget]).
///
/// Left at Hermes's 90 rather than raised — a bigger budget is a longer, more
/// expensive turn, and that is the user's call to make, not a default to change
/// behind them.
const int kHermesToolCallBudget = 90;

/// Pin `agent.max_turns` so the app and Hermes agree on the same budget.
void ensureToolCallBudget(YamlEditor editor) {
  HermesConfigFile.upsert(editor, [
    'agent',
    'max_turns',
  ], kHermesToolCallBudget);
}

/// The toolsets that read and answer but can't act on this computer.
///
/// Hermes bundles `read_file` and `write_file` into one `file` toolset, so a
/// turn that can read the user's files can also write to them — there is no
/// read-only half to hand out. Dropping `file` too would make the whole thing
/// pointless ("summarise my notes" needs to read the notes), so what this list
/// actually removes is the ability to *run* things: terminal, code execution,
/// and computer control. The scheduler's "no commands" setting, and — because
/// the chat platforms were once held to this same list — the fingerprint
/// [HermesPlatformPolicy.isPinned] recognises when undoing that.
///
/// `browser` is in the list because without it these surfaces can't reach the
/// web at all: `web` (`web_search` / `web_extract`) only loads when a search
/// backend has credentials — an Exa/Tavily/Brave key, a SearXNG URL, or the
/// `ddgs` package — and a stock install has none, so Hermes drops both tools
/// and a "read me today's news" task has nothing left to read with. The browser
/// drives headless Chromium: it opens pages, it doesn't run the user's
/// commands, so it belongs on the read-and-answer side of the line.
const List<String> kReadAndAnswerToolsets = [
  'file',
  'web',
  'browser',
  'skills',
  'vision',
  'todo',
  'memory',
  'session_search',
];
