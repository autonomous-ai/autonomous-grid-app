import 'dart:io';

/// Resolves locations under `~/.grid`, mirroring the CLI's `paths.py`.
///
/// The CLI honours `GRID_HOME`, falling back to `~/.grid`. Everything the app
/// reads (credentials, per-network config, models, outputs) lives here — this
/// directory is the single source of truth (see CLI_Integration_Contract §1).
class GridPaths {
  const GridPaths._();

  static String get _userHome =>
      Platform.environment['HOME'] ??
      Platform.environment['USERPROFILE'] ??
      Directory.current.path;

  static Directory get home {
    final override = Platform.environment['GRID_HOME'];
    return Directory(override != null && override.isNotEmpty
        ? override
        : '$_userHome/.grid');
  }

  static File get deviceFile => File('${home.path}/device.toml');

  static File get credentialsFile => File('${home.path}/credentials.toml');

  /// The merged CLI's mode pointer + per-mode active grid
  /// (`{"mode": …, "active": {"lan": …, "cloud": …}}`). New in dual-mode: the
  /// active selection moved here out of `credentials.toml` (CLI shared/state.py).
  static File get stateFile => File('${home.path}/state.json');

  static Directory get networksDir => Directory('${home.path}/networks');

  static Directory networkDir(String networkId) =>
      Directory('${networksDir.path}/$networkId');

  static File networkConfigFile(String networkId) =>
      File('${networkDir(networkId).path}/config.toml');

  static File networkServerLog(String networkId) =>
      File('${networkDir(networkId).path}/server.log');

  static Directory get modelsDir => Directory('${home.path}/models');

  static Directory get outputsDir => Directory('${home.path}/outputs');

  /// Where `grid llama.cpp install` links the engine (provider_runtime
  /// paths.py: `llama_server_bin()`).
  static File get llamaServerBin => File('${home.path}/bin/llama-server');

  /// Run records for detached engines launched by `grid join`, namespaced per
  /// grid: `~/.grid/run/engines/<grid_id>/<engine_id>.{json,log}`. The app reads
  /// these to detect an engine that outlived an app restart (its `grid join`
  /// process keeps serving via the relay until `grid leave`).
  static Directory get runEnginesDir => Directory('${home.path}/run/engines');

  static File engineRunFile(String gridId, String engineName) =>
      File('${runEnginesDir.path}/$gridId/$engineName.json');

  static File engineRunLogFile(String gridId, String engineName) =>
      File('${runEnginesDir.path}/$gridId/$engineName.log');
}
