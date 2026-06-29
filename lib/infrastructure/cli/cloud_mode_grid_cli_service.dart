import 'grid_cli_service.dart';
import 'parsers/download_progress.dart';

/// Forces every `grid` invocation into **cloud mode** by prepending the global
/// `--cloud` flag.
///
/// The merged dual-mode CLI defaults to **LAN** mode when `~/.grid/state.json`
/// has no saved mode, and gates the cloud-only commands (`login`, `members`,
/// `sync`, …) behind it — running them in LAN mode errors with a "run
/// `grid mode cloud`" message. This app is purely a cloud client, so it pins the
/// mode per command rather than relying on the persisted mode (which the user
/// can flip from their own terminal with `grid mode lan`).
///
/// `--cloud` is stripped from any argv position before the parser runs and is a
/// no-op for the mode-agnostic commands (`engine` / `catalog` / `pull` / `rm` /
/// `--version`), so prepending it universally is safe. Sits *outside*
/// [LoggingGridCliService] so the Debug tab shows the exact command that ran.
class CloudModeGridCliService implements GridCliService {
  const CloudModeGridCliService(this._inner);

  final GridCliService _inner;

  static const _modeFlag = '--cloud';

  List<String> _cloud(List<String> args) => [_modeFlag, ...args];

  @override
  Future<CliResult> run(List<String> args) => _inner.run(_cloud(args));

  @override
  Future<GridProcess> start(List<String> args) => _inner.start(_cloud(args));

  @override
  Stream<DownloadProgress> pull(List<String> args) => _inner.pull(_cloud(args));
}
