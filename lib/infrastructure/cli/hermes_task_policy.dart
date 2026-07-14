import 'dart:io';

import 'package:yaml_edit/yaml_edit.dart';

/// What a scheduled task may do to this computer while it runs unattended.
///
/// There is no "ask" here, and there can't be: a task fires whether the app is
/// open or not, so there's nobody to answer. The choice is made once, in advance
/// — which is exactly why the screen has to say what it means.
enum TaskPower {
  /// It runs commands and changes files, with nobody to say no. The default —
  /// a task that can't act can only report.
  fullAccess,

  /// It reads and writes files in the project folder, but has **no terminal**:
  /// the command tools aren't loaded at all, so there is nothing for the model
  /// to call. Not a promise — an absence.
  noCommands,
}

/// The toolsets a task keeps under [TaskPower.noCommands].
///
/// Hermes bundles `read_file` and `write_file` into one `file` toolset, so a task
/// that can read the user's project can also write to it — there is no read-only
/// half to hand out. Dropping `file` too would make the whole feature pointless
/// ("summarise my notes" needs to read the notes), so what this mode actually
/// removes is the ability to *run* things: terminal, code execution, the browser
/// and computer control.
///
/// TODO(BE): `hermes cron create` has no `--toolsets` flag, though the job store
/// has an `enabled_toolsets` field — so this is Hermes-wide for cron, not
/// per-task. A flag would let each task carry its own limit.
const List<String> kNoCommandToolsets = [
  'file',
  'web',
  'skills',
  'vision',
  'todo',
  'memory',
  'session_search',
];

/// Reads and writes what Hermes lets its scheduler do.
///
/// Two settings in `~/.hermes/config.yaml`, and they work in different ways:
/// `platform_toolsets.cron` decides which tools a scheduled run even *loads*
/// (real enforcement — a tool that isn't there can't be called), while
/// `approvals.cron_mode` decides what happens when one of the loaded tools tries
/// something dangerous (`deny`, Hermes's own default, or `approve`).
///
/// A file write, note, is gated by neither: Hermes only asks about edits over ACP
/// (a live chat), never in cron. So "no commands" is the strongest limit the app
/// can honestly enforce today.
class HermesTaskPolicy {
  HermesTaskPolicy({String? home})
    : _home = home ?? Platform.environment['HOME'] ?? '';

  final String _home;

  File get _config => File('$_home/.hermes/config.yaml');

  /// What tasks may do right now, as Hermes's own config says. A config that
  /// doesn't mention it reads as [TaskPower.noCommands] only when the toolsets
  /// say so — otherwise the tools are all there, and saying anything else would
  /// be a comfortable lie.
  Future<TaskPower> read() async {
    final text = await _read();
    if (text == null) return TaskPower.fullAccess;
    final editor = YamlEditor(text);
    final toolsets = editor.parseAt([
      'platform_toolsets',
      'cron',
    ], orElse: () => wrapAsYamlNode(null)).value;
    if (toolsets is! List) return TaskPower.fullAccess;
    return toolsets.contains('terminal') || toolsets.contains('code_execution')
        ? TaskPower.fullAccess
        : TaskPower.noCommands;
  }

  /// Make Hermes's config say [power] — merged into whatever else is in there,
  /// with the file backed up to `<file>.bak` first.
  Future<void> write(TaskPower power) async {
    final text = await _read() ?? '';
    final editor = YamlEditor(text.trim().isEmpty ? '{}\n' : text);

    switch (power) {
      case TaskPower.noCommands:
        _upsert(editor, ['platform_toolsets', 'cron'], kNoCommandToolsets);
        // Belt and braces: a tool that arrives some other way (a plugin, an MCP
        // server) still can't run a dangerous command.
        _upsert(editor, ['approvals', 'cron_mode'], 'deny');
      case TaskPower.fullAccess:
        // Hand the toolset decision back to Hermes's own defaults rather than
        // pinning a list the app would then have to keep in step with it.
        _remove(editor, ['platform_toolsets', 'cron']);
        _upsert(editor, ['approvals', 'cron_mode'], 'approve');
    }

    await _config.parent.create(recursive: true);
    if (await _config.exists()) await _config.copy('${_config.path}.bak');
    await _config.writeAsString('${editor.toString().trimRight()}\n');
  }

  Future<String?> _read() async {
    if (!await _config.exists()) return null;
    final text = await _config.readAsString();
    return text.trim().isEmpty ? null : text;
  }

  /// Set [path], creating the parent map when the config has never had one.
  void _upsert(YamlEditor editor, List<String> path, Object value) {
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
  void _remove(YamlEditor editor, List<String> path) {
    final existing = editor
        .parseAt(path, orElse: () => wrapAsYamlNode(null))
        .value;
    if (existing == null) return;
    editor.remove(path);
  }
}
