import 'hermes_config_file.dart';

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
///
/// TODO(BE): `hermes cron create` has no `--toolsets` flag, though the job store
/// has an `enabled_toolsets` field — so this limit is Hermes-wide for cron, not
/// per-task. A flag would let each task carry its own.
class HermesTaskPolicy {
  HermesTaskPolicy({String? home}) : _config = HermesConfigFile(home: home);

  final HermesConfigFile _config;

  /// What tasks may do right now, as Hermes's own config says. A config that
  /// doesn't pin a toolset list reads as [TaskPower.fullAccess] — the tools are
  /// all there, and saying anything else would be a comfortable lie.
  Future<TaskPower> read() async {
    final toolsets = await _config.valueAt(['platform_toolsets', 'cron']);
    if (toolsets is! List) return TaskPower.fullAccess;
    return toolsets.contains('terminal') || toolsets.contains('code_execution')
        ? TaskPower.fullAccess
        : TaskPower.noCommands;
  }

  /// Make Hermes's config say [power] — merged into whatever else is in there,
  /// with the file backed up first.
  Future<void> write(TaskPower power) => _config.edit((editor) {
    switch (power) {
      case TaskPower.noCommands:
        HermesConfigFile.upsert(editor, [
          'platform_toolsets',
          'cron',
        ], kReadAndAnswerToolsets);
        // Belt and braces: a tool that arrives some other way (a plugin, an MCP
        // server) still can't run a dangerous command.
        HermesConfigFile.upsert(editor, ['approvals', 'cron_mode'], 'deny');
      case TaskPower.fullAccess:
        // Hand the toolset decision back to Hermes's own defaults rather than
        // pinning a list the app would then have to keep in step with it.
        HermesConfigFile.remove(editor, ['platform_toolsets', 'cron']);
        HermesConfigFile.upsert(editor, ['approvals', 'cron_mode'], 'approve');
    }
  });
}
