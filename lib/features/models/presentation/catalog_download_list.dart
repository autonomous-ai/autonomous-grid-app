import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../infrastructure/cli/parsers/catalog_entry.dart';
import '../../../infrastructure/state/models/local_files.dart';
import '../../../shared/theme/app_theme.dart';
import '../logic/model_pull_controller.dart';
import '../logic/models_providers.dart';

/// True when a catalog model is already sitting under `~/.grid/models` — matched
/// leniently by filename (case-insensitive) so a slightly different saved name
/// still reads as "downloaded". Shared by the tile so the check stays in one
/// place.
bool isCatalogModelDownloaded(CatalogEntry entry, List<LocalModel> local) {
  final want = entry.quantizedFile.toLowerCase();
  return local.any((m) {
    final name = m.name.toLowerCase();
    return name == want || name.endsWith(want);
  });
}

/// "Suggested models" — the curated catalog (`grid catalog`) surfaced as a
/// one-tap download list, each row tagged with the device it targets so users
/// pick the build for their machine instead of typing a `repo:file` spec.
/// Hides itself entirely while the catalog is unavailable (offline, no CLI).
class CatalogDownloadSection extends ConsumerWidget {
  const CatalogDownloadSection({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final catalog = ref.watch(catalogModelsProvider);
    return catalog.maybeWhen(
      loading: () => const _CatalogLoading(),
      data: (entries) =>
          entries.isEmpty ? const SizedBox.shrink() : _CatalogBody(entries: entries),
      // Any failure (offline, no CLI) just hides the optional section — the
      // free-text download field above still works.
      orElse: () => const SizedBox.shrink(),
    );
  }
}

/// Header + bordered list of catalog rows. Split from the section so the
/// visibility branches above stay flat.
class _CatalogBody extends StatelessWidget {
  const _CatalogBody({required this.entries});

  final List<CatalogEntry> entries;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text('Suggested models', style: theme.textTheme.titleMedium),
        const SizedBox(height: 4),
        Text(
          'Curated builds for common hardware — pick the one for your device.',
          style: theme.textTheme.bodySmall
              ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
        ),
        const SizedBox(height: 12),
        Container(
          decoration: BoxDecoration(
            color: AppPalette.cardBg,
            borderRadius: BorderRadius.circular(10),
            border: Border.all(color: AppPalette.divider),
          ),
          child: Column(children: _rows()),
        ),
        // Owned here (not by the dialog) so hiding the section leaves no gap.
        const SizedBox(height: 32),
      ],
    );
  }

  List<Widget> _rows() {
    final rows = <Widget>[];
    for (var i = 0; i < entries.length; i++) {
      rows.add(_CatalogTile(entry: entries[i]));
      if (i != entries.length - 1) {
        rows.add(const Divider(height: 1, indent: 14, endIndent: 14));
      }
    }
    return rows;
  }
}

/// One suggested model: file name, a device tag + memory hint, and a Download
/// action. Shows "Downloaded" instead when the file is already on disk, and
/// disables the button while any download is running (only one pull at a time).
class _CatalogTile extends ConsumerWidget {
  const _CatalogTile({required this.entry});

  final CatalogEntry entry;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final downloaded =
        isCatalogModelDownloaded(entry, ref.watch(localModelsProvider));
    final pulling = ref.watch(modelPullControllerProvider) is ModelPulling;

    return Padding(
      padding: const EdgeInsets.fromLTRB(14, 10, 8, 10),
      child: Row(
        children: [
          Container(
            width: 34,
            height: 34,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: AppPalette.windowBg,
              borderRadius: BorderRadius.circular(8),
            ),
            child: const Icon(Icons.cloud_download_outlined, size: 18),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(entry.quantizedFile,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.bodyMedium),
                const SizedBox(height: 4),
                _MetaRow(entry: entry),
              ],
            ),
          ),
          const SizedBox(width: 8),
          _action(context, ref, downloaded: downloaded, pulling: pulling),
        ],
      ),
    );
  }

  Widget _action(BuildContext context, WidgetRef ref,
      {required bool downloaded, required bool pulling}) {
    final theme = Theme.of(context);
    if (downloaded) {
      return Padding(
        padding: const EdgeInsets.symmetric(horizontal: 8),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.check_circle, size: 16, color: AppPalette.online),
            const SizedBox(width: 6),
            Text('Downloaded',
                style: theme.textTheme.bodySmall
                    ?.copyWith(color: AppPalette.online)),
          ],
        ),
      );
    }
    return TextButton.icon(
      onPressed: pulling
          ? null
          : () =>
              ref.read(modelPullControllerProvider.notifier).pull(entry.pullSpec),
      icon: const Icon(Icons.download_outlined, size: 16),
      label: const Text('Download'),
      style: TextButton.styleFrom(visualDensity: VisualDensity.compact),
    );
  }
}

/// Device tag (e.g. "Apple Silicon") + a plain memory hint, so users can tell at
/// a glance which build suits their machine.
class _MetaRow extends StatelessWidget {
  const _MetaRow({required this.entry});

  final CatalogEntry entry;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final muted =
        theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant);
    return Row(
      children: [
        if (entry.target != null) ...[
          _DeviceChip(label: entry.target!),
          const SizedBox(width: 8),
        ],
        Text('${entry.minVramGb.toStringAsFixed(0)} GB+ memory', style: muted),
      ],
    );
  }
}

/// A small pill for the target device, styled off the theme rather than
/// hardcoded colors.
class _DeviceChip extends StatelessWidget {
  const _DeviceChip({required this.label});

  final String label;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
      decoration: BoxDecoration(
        color: AppPalette.windowBg,
        borderRadius: BorderRadius.circular(6),
        border: Border.all(color: AppPalette.divider),
      ),
      child: Text(label,
          style: theme.textTheme.labelSmall
              ?.copyWith(color: theme.colorScheme.onSurfaceVariant)),
    );
  }
}

/// A quiet placeholder while `grid catalog` is being read, so the section
/// doesn't pop in abruptly.
class _CatalogLoading extends StatelessWidget {
  const _CatalogLoading();

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            const SizedBox(
              width: 14,
              height: 14,
              child: CircularProgressIndicator(strokeWidth: 2),
            ),
            const SizedBox(width: 10),
            Text('Loading suggested models…',
                style: theme.textTheme.bodySmall
                    ?.copyWith(color: theme.colorScheme.onSurfaceVariant)),
          ],
        ),
        const SizedBox(height: 32),
      ],
    );
  }
}
