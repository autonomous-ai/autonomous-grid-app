import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../../../infrastructure/api/model_catalog_client.dart';
import '../../../infrastructure/api/models/model_detail.dart';
import '../../../infrastructure/api/models/model_icon_service.dart';
import '../../../infrastructure/providers.dart';
import '../../../shared/copy/setup_hints.dart';
import '../../../shared/theme/app_theme.dart';
import '../../../shared/widgets/app_select_field.dart';
import '../../../shared/widgets/error_box.dart';
import '../../auth/logic/session_controller.dart';
import '../../provider_node/logic/provider_run_controller.dart';
import '../logic/model_delete_controller.dart';
import '../logic/model_group.dart';
import '../logic/model_pull_controller.dart';
import '../logic/model_storage.dart';
import '../logic/models_providers.dart';
import '../logic/pull_spec.dart';
import '../logic/suggested_catalog.dart';
import 'cancel_download_button.dart';
import 'model_delete_confirm.dart';
import 'model_detail_badges.dart';

/// The right pane of the model manager dialog: one model's full version list
/// with a runnability verdict per row. Reads `GET /v1/grid/catalog/{repo_id}`
/// with the user's device so each version gets a green/gray/red badge.
class ModelDetailPanel extends ConsumerWidget {
  const ModelDetailPanel({super.key, required this.repoId});

  final String repoId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    AppTheme.watch(context);
    final token = ref.watch(sessionProvider).sessionToken;
    final deviceAsync = ref.watch(deviceInfoProvider);

    if (token == null || token.isEmpty) {
      return const _DetailMessage(
        icon: Icons.lock_outline,
        text: 'Sign in to see model details.',
      );
    }

    final apiUrl = ref.watch(gridApiUrlProvider);
    final client = ref.watch(modelDetailClientProvider);

    return FutureBuilder<(ModelDetail?, ModelCatalogError?)>(
      future: deviceAsync.when(
        data: (device) => client.detail(
          apiUrl: apiUrl,
          sessionToken: token,
          repoId: repoId,
          device: device,
        ),
        loading: () async => (
          null,
          const ModelCatalogError('Reading this computer\'s details…'),
        ),
        error: (e, _) async => (
          null,
          ModelCatalogError('Couldn\'t read this computer\'s details: $e'),
        ),
      ),
      builder: (context, snap) {
        if (snap.connectionState != ConnectionState.done) {
          return const Center(child: CircularProgressIndicator());
        }
        final (detail, error) = snap.data ?? (null, null);
        if (error != null) {
          return _DetailMessage(icon: Icons.error_outline, text: error.message);
        }
        if (detail == null || detail.versions.isEmpty) {
          return const _DetailMessage(
            icon: Icons.inbox_outlined,
            text: 'No versions found for this model.',
          );
        }
        return _VersionPicker(detail: detail);
      },
    );
  }
}

final modelDetailClientProvider = Provider<ModelDetailClient>(
  (ref) => const ModelDetailClient._(),
);

class ModelDetailClient {
  const ModelDetailClient._();

  Future<(ModelDetail?, ModelCatalogError?)> detail({
    required String apiUrl,
    required String sessionToken,
    required String repoId,
    Map<String, dynamic>? device,
  }) => ModelCatalogClient.detail(
    apiUrl: apiUrl,
    sessionToken: sessionToken,
    repoId: repoId,
    device: device,
  );
}

class _VersionPicker extends ConsumerStatefulWidget {
  const _VersionPicker({required this.detail});

  final ModelDetail detail;

  @override
  ConsumerState<_VersionPicker> createState() => _VersionPickerState();
}

class _VersionPickerState extends ConsumerState<_VersionPicker> {
  late ModelVersion _selected;

  /// The message from a download this panel started and that failed. Set only
  /// for our own pulls — [ModelPullFailed] doesn't say which spec it belongs
  /// to, and a failure the reader never triggered isn't theirs to answer for.
  String? _error;

  /// True between starting a pull and seeing it end, so the listener below can
  /// tell our outcome from one belonging to another panel. Deliberately not a
  /// second copy of "is a download running" — that stays the controller's.
  bool _awaitingOutcome = false;

  @override
  void initState() {
    super.initState();
    _selected = widget.detail.versions.firstWhere(
      (v) => v.status == VersionStatus.runnable,
      orElse: () => widget.detail.versions.first,
    );
  }

  /// Every `grid pull` spec [version] needs — one per part of a split GGUF.
  List<String> _specsFor(ModelVersion version) =>
      versionPullSpecs(urls: version.urls, pullSpec: version.pullSpec);

  /// The filenames those specs land on disk, folder prefixes stripped the way
  /// the CLI strips them.
  List<String> _fileNamesFor(ModelVersion version) => [
    for (final spec in _specsFor(version)) ?pullSpecFileName(spec),
  ];

  bool get _isDownloaded => _isVersionDownloaded(_selected);

  /// What the selected version actually weighs on disk. The catalog's own
  /// figure is what it *will* weigh; for a delete the honest number is the one being
  /// freed, so it's summed from the files themselves.
  int _bytesOnDisk() {
    final names = {
      for (final name in _fileNamesFor(_selected)) name.toLowerCase(),
    };
    var bytes = 0;
    for (final file in ref.read(localModelsProvider)) {
      if (names.contains(file.name.toLowerCase())) bytes += file.sizeBytes;
    }
    return bytes;
  }

  /// True once *every* part is on disk. A split model missing one part isn't
  /// downloaded — it's unservable — so it must not read as done.
  bool _isVersionDownloaded(ModelVersion version) {
    final names = _fileNamesFor(version);
    if (names.isEmpty) return false;
    final onDisk = {
      for (final file in ref.watch(localModelsProvider))
        file.name.toLowerCase(),
    };
    return names.every((name) => onDisk.contains(name.toLowerCase()));
  }

  @override
  void didUpdateWidget(covariant _VersionPicker old) {
    super.didUpdateWidget(old);
    if (!widget.detail.versions.any((v) => v.version == _selected.version)) {
      _selected = widget.detail.versions.firstWhere(
        (v) => v.status == VersionStatus.runnable,
        orElse: () => widget.detail.versions.first,
      );
    }
  }

  /// Starts the pull and nothing else. Whether a download is running is the
  /// controller's to say — this used to flip a local `_isDownloading` too, and
  /// the two copies drifted the moment anything ended a download by a route the
  /// panel wasn't listening for. See the button's `pulling` below.
  ///
  /// Every part goes down in one call: the controller takes one spec per line
  /// and stops at the first that fails, so a split model arrives whole or the
  /// user is told which part didn't.
  ///
  /// **Any** version may be downloaded, not only the one the ranking would have
  /// picked. `status` is advice, not permission: a quant below the quality floor
  /// ([VersionStatus.lowQuality]) or one that won't quite hit interactive speed
  /// ([VersionStatus.partial]) still loads and still answers. Gating the button
  /// on [VersionStatus.runnable] left every *smaller* version in the list —
  /// exactly the ones a modest machine wants — visible, selectable, and
  /// impossible to install, with no word on screen saying why.
  ///
  /// [VersionStatus.tooLarge] is the one that asks first: those weights cannot
  /// load here at all, and it is several GB to find that out.
  Future<void> _startDownload(BuildContext context) async {
    final specs = _specsFor(_selected);
    if (specs.isEmpty) return;
    if (!(_selected.status?.canRunHere ?? true) &&
        !await _confirmTooLarge(context)) {
      return;
    }
    if (!mounted) return;
    setState(() {
      _error = null;
      _awaitingOutcome = true;
    });
    ref.read(modelPullControllerProvider.notifier).pull(specs.join('\n'));
  }

  /// Confirms a download of weights this computer can't hold. Anything but an
  /// explicit yes — Cancel, Escape, a tap outside — returns false, so a stray
  /// dismissal never starts a multi-gigabyte transfer that can't be run.
  Future<bool> _confirmTooLarge(BuildContext context) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Download anyway?'),
        content: Text(
          '${_selected.version ?? 'This version'} '
          '(${modelSizeLabel(_selected.sizeBytes)}) needs more memory than '
          'this computer has, so it won\'t start here. You can still download it — '
          'to share from another computer on your grid, or for later.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Download'),
          ),
        ],
      ),
    );
    return confirmed == true;
  }

  Future<void> _confirmAndDelete(BuildContext context) async {
    final files = _fileNamesFor(_selected);
    if (files.isEmpty) return;
    final label = _modelLabel(files);

    final confirmed = await confirmModelDelete(
      context,
      label: label,
      sizeBytes: _bytesOnDisk(),
      unfinished: false,
    );
    if (!confirmed) return;

    await ref
        .read(modelDeleteControllerProvider.notifier)
        .delete(files, label: label);
  }

  /// What to call this model in a sentence: the filename when it's one file,
  /// the shared base plus a part count when it's a split set — the same shape
  /// the pull controller reports when a multi-part download finishes.
  String _modelLabel(List<String> files) => files.length == 1
      ? files.first
      : '${stripSplitSuffix(files.first)} (${files.length} parts)';

  /// Why Delete is off. Names where to stop it from [kShareModelsPlace], the
  /// top bar button's own label, so the sentence points somewhere that exists.
  static const _inUseReason =
      'This model is running right now. Stop it from $kShareModelsPlace to '
      'delete it.';

  /// The pills for one version. Quantisation and size are facts, so they stay
  /// neutral; the two badges that carry a verdict — will it run here, is it
  /// already on disk — take the colour, which is what makes them findable when
  /// the menu lists a dozen versions.
  List<AppSelectBadge> _versionBadges(ModelVersion v) => [
    AppSelectBadge(v.version ?? '—'),
    AppSelectBadge(modelSizeLabel(v.sizeBytes)),
    if (v.status case final status?)
      AppSelectBadge(
        status.label,
        tone: switch (status) {
          VersionStatus.runnable => AppBadgeTone.positive,
          VersionStatus.partial => AppBadgeTone.warning,
          VersionStatus.lowQuality => AppBadgeTone.warning,
          VersionStatus.tooLarge => AppBadgeTone.danger,
        },
      ),
    if (_isVersionDownloaded(v))
      const AppSelectBadge('Downloaded', tone: AppBadgeTone.positive),
  ];

  /// How far the download has got, beside the button.
  ///
  /// The bar the CLI streams is per file, so a split model would otherwise run
  /// 0→100% once per part with nothing saying why — hence the part counter,
  /// which only appears when there is more than one.
  String _progressText(ModelPulling pulling) {
    final part = pulling.total > 1
        ? 'Part ${pulling.current} of ${pulling.total} · '
        : '';
    final progress = pulling.progress;
    if (progress == null) return '${part}Starting…';
    final done = _amount(progress.doneMb);
    return switch (progress.totalMb) {
      final total? => '$part$done/${_amount(total)}',
      _ => '$part$done',
    };
  }

  static String _amount(double mb) => mb >= 1000
      ? '${(mb / 1000).toStringAsFixed(1)} GB'
      : '${mb.toStringAsFixed(0)} MB';

  @override
  Widget build(BuildContext context) {
    AppTheme.watch(context);
    final theme = Theme.of(context);
    final iconUrl = urlForModel(widget.detail.repoId);

    // A download that ends has to say so. Failing silently is what made a
    // download that never landed look like a button that does nothing.
    ref.listen<ModelPullState>(modelPullControllerProvider, (_, next) {
      if (!mounted || !_awaitingOutcome) return;
      switch (next) {
        case ModelPulling():
          return;
        case ModelPullIdle():
          setState(() => _awaitingOutcome = false);
        case ModelPullDone():
          setState(() {
            _awaitingOutcome = false;
            _error = null;
          });
        case ModelPullFailed(:final message):
          setState(() {
            _awaitingOutcome = false;
            _error = message;
          });
      }
    });

    // Whether this model is coming down / going away, and what to say if the
    // delete failed — all read from the controller, which is the only thing
    // that knows. A second local copy of "is it deleting" drifts the moment
    // anything else finishes the job (see [_startDownload]).
    final files = _fileNamesFor(_selected);
    final label = files.isEmpty ? '' : _modelLabel(files);
    final deleteState = ref.watch(modelDeleteControllerProvider);
    final deleting = switch (deleteState) {
      ModelDeleting(label: final deletingLabel) => deletingLabel == label,
      _ => false,
    };
    final deleteError = switch (deleteState) {
      ModelDeleteFailed(label: final failedLabel, :final message)
          when failedLabel == label =>
        message,
      _ => null,
    };
    // Never offer to delete the weights the engine is reading right now.
    final serving = ref.watch(servingModelProvider);
    final inUse = files.any((file) => isModelInUse(file, serving));

    final pullState = ref.watch(modelPullControllerProvider);
    final pulling = pullState is ModelPulling ? pullState : null;
    final specs = _specsFor(_selected);
    // Whether the download in flight is THIS model's. The button's disabled
    // state stays global — one `grid pull` at a time is what the controller
    // tracks — but Cancel must not be: from another model's panel it would kill
    // a transfer the reader never started and cannot see. Matched against every
    // part, since a split model is mid-flight on any one of them.
    final cancellable = pulling != null && specs.contains(pulling.spec);

    return Stack(
      children: [
        ListView(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
          children: [
            // Header row: icon + name + format badge
            Row(
              children: [
                if (iconUrl != null) ...[
                  CachedNetworkImage(
                    imageUrl: iconUrl,
                    width: 36,
                    height: 36,
                    fit: BoxFit.contain,
                    errorWidget: (_, _, _) => Container(
                      width: 36,
                      height: 36,
                      decoration: BoxDecoration(
                        color: AppPalette.textSecondary.withValues(alpha: 0.15),
                        borderRadius: BorderRadius.circular(4),
                      ),
                      child: Icon(
                        Icons.dns_outlined,
                        size: 22,
                        color: AppPalette.textSecondary,
                      ),
                    ),
                  ),
                  const SizedBox(width: 12),
                ],
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        _displayName(widget.detail.repoId),
                        style: theme.textTheme.headlineSmall?.copyWith(
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        widget.detail.repoId,
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: AppPalette.textSecondary,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
            const SizedBox(height: 12),
            // Metadata grid: Parameters, Architecture, Format, Capability
            ModelDetailBadgeGrid(detail: widget.detail),
            const SizedBox(height: 12),
            // Version dropdown label
            Text(
              'Version',
              style: theme.textTheme.labelLarge?.copyWith(
                color: AppPalette.textSecondary,
              ),
            ),
            const SizedBox(height: 6),
            // Version selector using app's standard select field
            AppSelectField<ModelVersion>(
              label: '',
              showLabel: false,
              value: _selected,
              options: [
                for (final v in widget.detail.versions)
                  AppSelectOption<ModelVersion>(
                    value: v,
                    label: _displayName(widget.detail.repoId),
                    badges: _versionBadges(v),
                  ),
              ],
              onChanged: (v) => setState(() {
                _selected = v;
                _error = null;
              }),
            ),
          ],
        ),
        // Download + Delete buttons pinned to the bottom, with room on the left
        // for the failure line — which needs the full width, not the leftovers
        // of a min-width row, or a long message overflows the panel.
        Positioned(
          left: 16,
          right: 16,
          bottom: 16,
          child: Row(
            children: [
              Expanded(
                child: switch (_error ?? deleteError) {
                  final message? => ErrorBox(message: message, maxHeight: 72),
                  _ => const SizedBox.shrink(),
                },
              ),
              const SizedBox(width: 12),
              if (_isDownloaded) ...[
                _DeleteButton(
                  deleting: deleting,
                  blockedReason: inUse ? _inUseReason : null,
                  onPressed: () => _confirmAndDelete(context),
                ),
                const SizedBox(width: 8),
              ],
              _DownloadButton(
                pulling: pulling,
                cancellable: cancellable,
                isDownloaded: _isDownloaded,
                progressText: pulling == null ? null : _progressText(pulling),
                // Disabled only for reasons the button itself can't resolve:
                // nothing to fetch, a transfer already running, or it's already
                // here. A version's verdict is never one of them — see
                // [_startDownload].
                onPressed:
                    (specs.isNotEmpty && pulling == null && !_isDownloaded)
                    ? () => _startDownload(context)
                    : null,
              ),
            ],
          ),
        ),
      ],
    );
  }
}

/// The quiet way to get a model's space back, beside the download button.
///
/// [blockedReason] both disables it and becomes its tooltip: a dead button with
/// no word on why is the thing that sends people to support.
class _DeleteButton extends StatelessWidget {
  const _DeleteButton({
    required this.deleting,
    required this.blockedReason,
    required this.onPressed,
  });

  final bool deleting;
  final String? blockedReason;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    AppTheme.watch(context);
    final button = TextButton.icon(
      onPressed: deleting || blockedReason != null ? null : onPressed,
      style: TextButton.styleFrom(foregroundColor: AppPalette.textSecondary),
      icon: deleting
          ? const SizedBox(
              width: 14,
              height: 14,
              child: CircularProgressIndicator(strokeWidth: 2),
            )
          : const Icon(Icons.delete_outline, size: 16),
      label: Text(deleting ? 'Deleting' : 'Delete'),
    );
    return switch (blockedReason) {
      final reason? => Tooltip(message: reason, child: button),
      _ => button,
    };
  }
}

/// The download control: how far the transfer has got, a way to stop it, and
/// the button itself.
///
/// [cancellable] is separate from [pulling] on purpose — the button greys out
/// for *any* running download (the controller tracks one at a time), but Cancel
/// belongs only to the panel whose model is actually coming down.
class _DownloadButton extends StatelessWidget {
  const _DownloadButton({
    required this.pulling,
    required this.cancellable,
    required this.isDownloaded,
    required this.progressText,
    required this.onPressed,
  });

  final ModelPulling? pulling;
  final bool cancellable;
  final bool isDownloaded;
  final String? progressText;
  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) {
    AppTheme.watch(context);
    final theme = Theme.of(context);
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (progressText case final text?) ...[
          Text(
            text,
            style: theme.textTheme.bodySmall?.copyWith(
              color: AppPalette.textSecondary,
              fontWeight: FontWeight.w600,
            ),
          ),
          const SizedBox(width: 8),
        ],
        if (cancellable) ...[
          const CancelDownloadButton(),
          const SizedBox(width: 8),
        ],
        ElevatedButton.icon(
          onPressed: onPressed,
          icon: pulling != null
              ? const SizedBox(
                  width: 16,
                  height: 16,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : Icon(
                  isDownloaded ? Icons.check_circle : LucideIcons.download,
                  size: 16,
                ),
          label: Text(
            pulling != null
                ? 'Downloading'
                : isDownloaded
                ? 'Downloaded'
                : 'Download',
          ),
          style: ElevatedButton.styleFrom(
            backgroundColor: isDownloaded
                ? AppPalette.online
                : AppPalette.accent,
            foregroundColor: Colors.white,
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(AppCard.insetRadius),
            ),
          ),
        ),
      ],
    );
  }
}

class _DetailMessage extends StatelessWidget {
  const _DetailMessage({required this.icon, required this.text});
  final IconData icon;
  final String text;

  @override
  Widget build(BuildContext context) {
    AppTheme.watch(context);
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 32, color: AppPalette.textSecondary),
            const SizedBox(height: 12),
            Text(text, style: TextStyle(color: AppPalette.textSecondary)),
          ],
        ),
      ),
    );
  }
}

/// `Qwen/Qwen2.5-3B-Instruct-GGUF` → `Qwen2.5 3B Instruct GGUF`.
/// Replaces `-`/`_` with spaces, keeps numbers and GGUF intact.
String _displayName(String repoId) {
  if (repoId.isEmpty) return 'Unknown model';
  final tail = repoId.contains('/') ? repoId.split('/').last : repoId;
  return tail
      .split(RegExp(r'[-_]'))
      .where((w) => w.isNotEmpty)
      .map((w) => w[0].toUpperCase() + w.substring(1))
      .join(' ');
}
