import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../../../infrastructure/api/model_catalog_client.dart';
import '../../../infrastructure/api/models/model_detail.dart';
import '../../../infrastructure/api/models/model_icon_service.dart';
import '../../../infrastructure/providers.dart';
import '../../../shared/theme/app_theme.dart';
import '../../../shared/widgets/app_select_field.dart';
import '../../auth/logic/session_controller.dart';
import '../logic/model_delete_controller.dart';
import '../logic/model_pull_controller.dart';
import '../logic/models_providers.dart';
import '../logic/suggested_catalog.dart';
import '../../../infrastructure/cli/parsers/download_progress.dart' as cli_progress;

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
  }) =>
      ModelCatalogClient.detail(
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
  bool _isDownloading = false;
  bool _isDeleting = false;
  final listenable = ValueNotifier<bool>(false);

  @override
  void dispose() {
    listenable.dispose();
    super.dispose();
  }

  @override
  void initState() {
    super.initState();
    _selected = widget.detail.versions.firstWhere(
      (v) => v.status == VersionStatus.runnable,
      orElse: () => widget.detail.versions.first,
    );
  }

  bool get _isDownloaded {
    final files = ref.read(localModelsProvider);
    final filename = _selected.pullSpec?.split(':').last;
    if (filename == null) return false;
    return files.any((f) => f.name.toLowerCase() == filename.toLowerCase());
  }

  bool _isVersionDownloaded(ModelVersion version) {
    final files = ref.read(localModelsProvider);
    final filename = version.pullSpec?.split(':').last;
    if (filename == null) return false;
    return files.any((f) => f.name.toLowerCase() == filename.toLowerCase());
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

  void _startDownload() {
    if (_selected.pullSpec == null || _selected.pullSpec!.isEmpty) return;
    
    setState(() => _isDownloading = true);

    final pullController = ref.read(modelPullControllerProvider.notifier);
    pullController.pull(_selected.pullSpec!);
  }

  Future<void> _confirmAndDelete(BuildContext context) async {
    final filename = _selected.pullSpec?.split(':').last;
    if (filename == null) return;

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Delete model?'),
        content: Text(
          '"$filename" will be removed from this computer. '
          'You can download it again later.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            style: FilledButton.styleFrom(
              backgroundColor: AppPalette.textSecondary,
            ),
            child: const Text('Delete'),
          ),
        ],
      ),
    );

    if (confirmed != true) return;

    setState(() => _isDeleting = true);

    final deleteController = ref.read(modelDeleteControllerProvider.notifier);
    await deleteController.delete([filename], label: filename);

    setState(() => _isDeleting = false);
  }

  String _sizeLabel(int bytes) {
    final gb = bytes / 1e9;
    return gb >= 10 ? '${gb.toStringAsFixed(0)} GB' : '${gb.toStringAsFixed(1)} GB';
  }

  List<Widget> _buildProgressSection(
    cli_progress.DownloadProgress progress,
    double fraction,
    ThemeData theme,
  ) {
    final doneMb = progress.doneMb ?? 0;
    final totalMb = progress.totalMb ?? 0;
    final doneStr = doneMb >= 1000 ? '${(doneMb / 1000).toStringAsFixed(1)} GB' : '${doneMb.toStringAsFixed(0)} MB';
    final totalStr = totalMb >= 1000 ? '${(totalMb / 1000).toStringAsFixed(1)} GB' : '${totalMb.toStringAsFixed(0)} MB';
    return [
      Text(
        '$doneStr/$totalStr',
        style: theme.textTheme.bodySmall?.copyWith(
          color: AppPalette.textSecondary,
          fontWeight: FontWeight.w600,
        ),
      ),
      const SizedBox(width: 8),
    ];
  }

  @override
  Widget build(BuildContext context) {
    AppTheme.watch(context);
    final theme = Theme.of(context);
    final iconUrl = urlForModel(widget.detail.repoId);

    // Watch for download state changes
    ref.listen<ModelPullState>(modelPullControllerProvider, (prev, next) {
      if (!mounted) return;
      if (next is ModelPullDone) {
        setState(() => _isDownloading = false);
      } else if (next is ModelPullFailed) {
        setState(() => _isDownloading = false);
      }
    });

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
                    errorWidget: (_, __, ___) => Container(
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
                        style: theme.textTheme.headlineSmall?.copyWith(fontWeight: FontWeight.w600),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        widget.detail.repoId,
                        style: theme.textTheme.bodySmall?.copyWith(color: AppPalette.textSecondary),
                      ),
                    ],
                  ),
                ),
              ],
            ),
            const SizedBox(height: 12),
            // Metadata grid: Parameters, Architecture, Format, Capability
            _DetailBadgeGrid(detail: widget.detail),
            const SizedBox(height: 12),
            // Version dropdown label
            Text(
              'Version',
              style: theme.textTheme.labelLarge?.copyWith(color: AppPalette.textSecondary),
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
                    detail: '${v.version ?? "—"} · ${_sizeLabel(v.sizeBytes)} · ${v.status?.label ?? "unknown"}${_isVersionDownloaded(v) ? ' · ✓ Downloaded' : ''}',
                  ),
              ],
              onChanged: (v) => setState(() => _selected = v),
            ),
          ],
        ),
        // Download + Delete buttons pinned to bottom-right
        Positioned(
          right: 16,
          bottom: 16,
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (_isDownloaded) ...[
                TextButton(
                  onPressed: _isDeleting ? null : () => _confirmAndDelete(context),
                  style: TextButton.styleFrom(
                    foregroundColor: AppPalette.textSecondary,
                    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      if (_isDeleting)
                        const SizedBox(
                          width: 16,
                          height: 16,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      else
                        const Icon(Icons.delete_outline, size: 16),
                      if (!_isDeleting) const SizedBox(width: 4),
                      if (!_isDeleting) const Text('Delete'),
                      if (_isDeleting) const Text(' Deleting'),
                    ],
                  ),
                ),
                const SizedBox(width: 8),
              ],
              AnimatedBuilder(
                animation: listenable,
                builder: (context, _) {
                  final pulling = ref.watch(modelPullControllerProvider) is ModelPulling;
                  final pullState = ref.watch(modelPullControllerProvider);
                  final progress = pulling
                      ? (pullState as ModelPulling).progress
                      : null;
                  final fraction = (progress != null && !progress.isIndeterminate)
                      ? progress.pct! / 100
                      : null;

                  return Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      if (pulling && fraction != null) ..._buildProgressSection(progress!, fraction, theme),
                      ElevatedButton.icon(
                        onPressed: (_selected.status == VersionStatus.runnable &&
                                !_isDownloading &&
                                !_isDownloaded)
                            ? _startDownload
                            : null,
                        icon: pulling
                            ? const SizedBox(
                                width: 16,
                                height: 16,
                                child: CircularProgressIndicator(strokeWidth: 2),
                              )
                            : Icon(
                                _isDownloaded ? Icons.check_circle : LucideIcons.download,
                                size: 16,
                              ),
                        label: Text(pulling
                            ? 'Downloading'
                            : _isDownloaded
                                ? 'Downloaded'
                                : 'Download'),
                        style: ElevatedButton.styleFrom(
                          backgroundColor: pulling
                              ? AppPalette.accent
                              : _isDownloaded
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
                },
              ),
            ],
          ),
        ),
      ],
    );
  }
}

class _DetailBadgeGrid extends StatelessWidget {
  const _DetailBadgeGrid({required this.detail});

  final ModelDetail detail;

  @override
  Widget build(BuildContext context) {
    AppTheme.watch(context);
    final items = <_BadgeItemData>[
      if (detail.likes > 0)
        _BadgeItemData(label: 'Likes', value: _formatCount(detail.likes)),
      if (detail.downloads > 0)
        _BadgeItemData(label: 'Downloads', value: _formatCount(detail.downloads)),
      if (detail.paramsB != null)
        _BadgeItemData(label: 'Parameters', value: '${detail.paramsB!.toStringAsFixed(1)}B'),
      if (detail.architecture != null && detail.architecture!.isNotEmpty)
        _BadgeItemData(label: 'Architecture', value: _formatValue(detail.architecture!)),
      if (detail.format != null)
        _BadgeItemData(label: 'Format', value: _formatValue(detail.format!)),
      if (detail.task != null && detail.task!.isNotEmpty)
        _BadgeItemData(label: 'Capability', value: _formatValue(detail.task!)),
    ];
    if (items.isEmpty) return const SizedBox.shrink();
    return Wrap(
      spacing: 8,
      runSpacing: 6,
      children: items.map((item) => _BadgeItem(data: item)).toList(),
    );
  }

  static String _formatCount(int count) {
    if (count >= 1000000) return '${(count / 1000000).toStringAsFixed(1)}M';
    if (count >= 1000) return '${(count / 1000).toStringAsFixed(1)}K';
    return '$count';
  }

  static String _formatValue(String value) {
    return value
        .replaceAll('-', ' ')
        .replaceAll('_', ' ')
        .split(RegExp(r'\s+'))
        .where((w) => w.isNotEmpty)
        .map((w) => w[0].toUpperCase() + w.substring(1).toLowerCase())
        .join(' ');
  }
}

class _BadgeItemData {
  const _BadgeItemData({required this.label, required this.value});
  final String label;
  final String value;
}

class _BadgeItem extends StatelessWidget {
  const _BadgeItem({required this.data});

  final _BadgeItemData data;

  @override
  Widget build(BuildContext context) {
    AppTheme.watch(context);
    final theme = Theme.of(context);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: AppGlass.bubbleFill,
        borderRadius: BorderRadius.circular(6),
      ),
      child: Text(
        '${data.label}: ${data.value}',
        style: theme.textTheme.bodySmall?.copyWith(
          color: AppPalette.textPrimary,
          fontWeight: FontWeight.w500,
        ),
      ),
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