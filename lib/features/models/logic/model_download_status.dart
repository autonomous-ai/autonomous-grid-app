import '../../../infrastructure/cli/parsers/download_progress.dart';
import '../../node_setup/logic/background_model_controller.dart';
import '../../node_setup/logic/node_setup_controller.dart';
import 'model_pull_controller.dart';

/// A model download actively in flight — a manual pull in the model manager,
/// the node-setup auto-download, or the background first-run download —
/// reduced to what a caller needs to say so. Outer null means no live download; a null
/// [pct] means "downloading, percent not known yet".
///
/// A partial `.gguf.part` sitting on disk with no live stream is *not* this:
/// that's a download that stopped, which reads and behaves differently (it can
/// be resumed, and it can be deleted to get its space back).
///
/// Three controllers can be pulling, so anything that has to know — the engine
/// block's progress line, the storage list refusing to delete a file being
/// written — asks here rather than watching one of them and being wrong when
/// another is the one running.
({int? pct})? liveModelDownload({
  required ModelPullState pull,
  required NodeSetupState setup,
  required ModelDownloadState background,
}) {
  if (pull is ModelPulling) return (pct: _pctOf(pull.progress));
  if (setup is NodeSetupRunning && setup.current.isDownload) {
    return (pct: _pctOf(setup.progress));
  }
  if (background is ModelDownloadRunning) {
    return (pct: _pctOf(background.progress));
  }
  return null;
}

int? _pctOf(DownloadProgress? p) =>
    (p != null && !p.isIndeterminate) ? p.pct!.round() : null;
