import 'grid_cli_service.dart';
import 'parsers/download_progress.dart';

/// Forces every `grid` invocation into **remote mode** by prepending the global
/// `--remote` flag — except the local-machine commands in [_localCommands].
///
/// The dual-mode CLI defaults to **local** mode when `~/.grid/state.json` has no
/// saved mode, and gates the remote-only commands (`login`, `members`, `sync`,
/// `use`, …) behind it — running them in local mode errors with a "run
/// `grid mode remote`" message. This app is purely a remote client, so it pins
/// the mode per command rather than relying on the persisted mode (which the
/// user can flip from their own terminal with `grid mode local`).
///
/// **Exception — local-machine commands.** Some commands act on *this machine*,
/// not the remote grid, and `--remote` either misroutes them or flips them onto
/// the wrong path:
///  - `engine …` (install llama.cpp / comfyui, status, pull) builds and detects
///    the local engine; `--remote` pushes it onto the remote/CUDA path — e.g.
///    `grid --remote engine install llama.cpp` fails on a Mac with "No NVIDIA
///    GPUs detected".
///  - `pull …` downloads a model to this machine's `~/.grid/models`.
/// These drop the flag; every other command still runs remote.
///
/// Sits *outside* [LoggingGridCliService] so the Debug tab shows the exact
/// command that ran.
class RemoteModeGridCliService implements GridCliService {
  const RemoteModeGridCliService(this._inner);

  final GridCliService _inner;

  static const _modeFlag = '--remote';

  /// Command families that operate on the local machine and must not be forced
  /// into remote mode (matched on the first arg — the top-level `grid` command).
  static const _localCommands = {'engine', 'pull'};

  List<String> _remote(List<String> args) {
    if (args.isNotEmpty && _localCommands.contains(args.first)) return args;
    return [_modeFlag, ...args];
  }

  @override
  Future<CliResult> run(List<String> args) => _inner.run(_remote(args));

  @override
  Future<GridProcess> start(List<String> args,
          {Map<String, String>? environment}) =>
      _inner.start(_remote(args), environment: environment);

  @override
  Stream<DownloadProgress> pull(List<String> args) => _inner.pull(_remote(args));
}
