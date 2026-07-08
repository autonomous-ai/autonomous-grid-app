import 'grid_cli_service.dart';
import 'parsers/download_progress.dart';

/// Forces every `grid` invocation into **remote mode** by prepending the global
/// `--remote` flag — except the local-machine `engine` commands (see below).
///
/// The dual-mode CLI defaults to **local** mode when `~/.grid/state.json` has no
/// saved mode, and gates the remote-only commands (`login`, `members`, `sync`,
/// `use`, …) behind it — running them in local mode errors with a "run
/// `grid mode remote`" message. This app is purely a remote client, so it pins
/// the mode per command rather than relying on the persisted mode (which the
/// user can flip from their own terminal with `grid mode local`).
///
/// **Exception — `engine` commands.** `grid engine …` (install llama.cpp /
/// comfyui, status, pull) acts on *this machine's* engine: it builds llama.cpp
/// for the local platform and detects what's installed here. `--remote` pushes
/// those into the remote/CUDA path — e.g. `grid --remote engine install
/// llama.cpp` fails on a Mac with "No NVIDIA GPUs detected" — so the flag is
/// dropped for the whole `engine` family. Every other command still runs remote.
///
/// Sits *outside* [LoggingGridCliService] so the Debug tab shows the exact
/// command that ran.
class RemoteModeGridCliService implements GridCliService {
  const RemoteModeGridCliService(this._inner);

  final GridCliService _inner;

  static const _modeFlag = '--remote';

  /// Command families that operate on the local machine and must not be forced
  /// into remote mode (matched on the first arg — the top-level `grid` command).
  static const _localCommands = {'engine'};

  List<String> _remote(List<String> args) {
    if (args.isNotEmpty && _localCommands.contains(args.first)) return args;
    return [_modeFlag, ...args];
  }

  @override
  Future<CliResult> run(List<String> args) => _inner.run(_remote(args));

  @override
  Future<GridProcess> start(List<String> args) => _inner.start(_remote(args));

  @override
  Stream<DownloadProgress> pull(List<String> args) => _inner.pull(_remote(args));
}
