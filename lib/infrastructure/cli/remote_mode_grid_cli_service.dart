import 'grid_cli_service.dart';
import 'parsers/download_progress.dart';

/// Forces every `grid` invocation into **remote mode** by prepending the global
/// `--remote` flag.
///
/// The dual-mode CLI defaults to **local** mode when `~/.grid/state.json` has no
/// saved mode, and gates the remote-only commands (`login`, `members`, `sync`,
/// `use`, …) behind it — running them in local mode errors with a "run
/// `grid mode remote`" message. This app is purely a remote client, so it pins
/// the mode per command rather than relying on the persisted mode (which the
/// user can flip from their own terminal with `grid mode local`).
///
/// `--remote` is a global flag accepted before any command and is a no-op for
/// the mode-agnostic commands (`engine` / `catalog` / `pull` / `rm` /
/// `--version`), so prepending it universally is safe. Sits *outside*
/// [LoggingGridCliService] so the Debug tab shows the exact command that ran.
class RemoteModeGridCliService implements GridCliService {
  const RemoteModeGridCliService(this._inner);

  final GridCliService _inner;

  static const _modeFlag = '--remote';

  List<String> _remote(List<String> args) => [_modeFlag, ...args];

  @override
  Future<CliResult> run(List<String> args) => _inner.run(_remote(args));

  @override
  Future<GridProcess> start(List<String> args) => _inner.start(_remote(args));

  @override
  Stream<DownloadProgress> pull(List<String> args) => _inner.pull(_remote(args));
}
