import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../infrastructure/api/models/model_catalog.dart';
import '../../../shared/theme/app_theme.dart';
import '../../../shared/widgets/app_spinner.dart';
import '../../../shared/widgets/extension_tile_surface.dart';
import '../logic/context_length.dart';
import '../logic/model_pull_controller.dart';
import '../logic/model_shelf.dart';
import '../logic/models_providers.dart';
import '../logic/suggested_catalog.dart';
import 'model_detail_panel.dart';
import 'shelf_model_tile.dart';

/// The "Suggested for your device" block of the model manager.
///
/// Asks the catalog API (`POST /v1/grid/catalog` with this machine's hardware)
/// for models ranked best-first for this computer, showing each with its size,
/// context and estimated speed. Falls back to the offline `grid catalog` list
/// ([fallback]) when the API can't be reached, so an offline or old build never
/// loses its suggestions.
class SuggestedForDevice extends ConsumerWidget {
  const SuggestedForDevice({
    super.key,
    required this.fallback,
    required this.fallbackLoading,
  });

  /// The offline `grid catalog` suggestions to show when the API is unavailable.
  final List<ShelfModel> fallback;

  /// Whether the offline catalog is still loading (so a transient API failure
  /// doesn't flash an empty fallback before it arrives).
  final bool fallbackLoading;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    AppTheme.watch(context);
    final outcome = ref.watch(suggestedCatalogProvider);

    return outcome.when(
      loading: () => const _SuggestStatus(
        icon: null,
        text: 'Finding models that fit this computer…',
      ),
      // An unexpected throw (not a mapped outcome) still degrades to the offline
      // list rather than an error box.
      error: (_, _) => _fallbackSection(),
      data: (result) => switch (result) {
        SuggestReady(:final ranked) => _ApiSuggestions(ranked: ranked),
        SuggestNoMatch() => const _SuggestStatus(
          icon: Icons.search_off_outlined,
          text:
              'No model fits this computer yet. You can still paste one below.',
        ),
        SuggestSignInRequired() => const _SignInHint(),
        SuggestUnavailable() => _fallbackSection(),
      },
    );
  }

  Widget _fallbackSection() {
    if (fallbackLoading && fallback.isEmpty) {
      return const _SuggestStatus(icon: null, text: 'Looking for models…');
    }
    if (fallback.isEmpty) {
      return const _SuggestStatus(
        icon: Icons.cloud_off_outlined,
        text: "Couldn't load suggestions — paste a model below.",
      );
    }
    return _SectionBody(
      count: fallback.length,
      children: [for (final model in fallback) ShelfModelTile(model: model)],
    );
  }
}

/// The API-ranked list: best-first, with a divider marking where models start
/// running noticeably slower on this machine.
class _ApiSuggestions extends ConsumerWidget {
  const _ApiSuggestions({required this.ranked});

  final List<CatalogModelPick> ranked;

  /// Below this tokens/sec a model runs noticeably slower — the doc's cue for a
  /// "── slower below here ──" divider so the user sees the boundary.
  static const _slowBelow = 8.0;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    AppTheme.watch(context);
    // Cross-reference what's already on disk (by GGUF filename) so a suggestion
    // already downloaded reads "On this computer" instead of offering Get again.
    final onDisk = {
      for (final m in ref.watch(localModelsProvider)) m.name.toLowerCase(),
    };

    final children = <Widget>[];
    var dividerShown = false;
    for (var i = 0; i < ranked.length; i++) {
      final model = ranked[i];
      final slow = model.estTokPerSec > 0 && model.estTokPerSec < _slowBelow;
      if (slow && !dividerShown && children.isNotEmpty) {
        children.add(const _SlowerDivider());
        dividerShown = true;
      }
      children.add(
        _SuggestedTile(
          model: model,
          recommended: i == 0,
          downloaded:
              model.file != null && onDisk.contains(model.file!.toLowerCase()),
        ),
      );
    }

    return _SectionBody(count: ranked.length, children: children);
  }
}

/// Header + spaced tiles — the layout the shelf sections use, kept in one place
/// so the API and fallback lists look identical.
class _SectionBody extends StatelessWidget {
  const _SectionBody({required this.count, required this.children});

  final int count;
  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const SizedBox(height: 10),
        ExtensionSectionHeader(
          label: 'Suggested for your device',
          count: count,
        ),
        for (final child in children) ...[child, const SizedBox(height: 8)],
      ],
    );
  }
}

/// One catalog suggestion: name, a facts line (quant · size · context · speed),
/// and the one action — Get, a spinner while any download runs, or a
/// "Downloaded" tag when it's already here.
class _SuggestedTile extends ConsumerWidget {
  const _SuggestedTile({
    required this.model,
    required this.recommended,
    required this.downloaded,
  });

  final CatalogModelPick model;
  final bool recommended;
  final bool downloaded;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    AppTheme.watch(context);
    return InkWell(
      onTap: () => _openDetailSheet(context, model.repoId ?? ''),
      borderRadius: BorderRadius.circular(AppCard.insetRadius),
      child: ExtensionTileSurface(
        onDialog: true,
        child: Row(
          children: [
            ExtensionIconBadge(
              icon: downloaded
                  ? Icons.memory_outlined
                  : Icons.cloud_download_outlined,
              active: downloaded || recommended,
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  _TitleRow(
                    name: _displayName(model),
                    recommended: recommended,
                  ),
                  const SizedBox(height: 4),
                  _MetaLine(model: model),
                ],
              ),
            ),
            const SizedBox(width: 12),
            _Action(model: model, downloaded: downloaded),
          ],
        ),
      ),
    );
  }
}

void _openDetailSheet(BuildContext context, String repoId) {
  if (repoId.isEmpty) return;
  showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    builder: (_) => DraggableScrollableSheet(
      expand: false,
      initialChildSize: 0.7,
      minChildSize: 0.4,
      maxChildSize: 0.95,
      builder: (_, controller) => ModelDetailPanel(repoId: repoId),
    ),
  );
}

/// The model name with a "Recommended" pill on the top pick.
class _TitleRow extends StatelessWidget {
  const _TitleRow({required this.name, required this.recommended});

  final String name;
  final bool recommended;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Flexible(
          child: Text(
            name,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              fontSize: 13,
              height: 1.2,
              fontWeight: AppFont.medium,
              color: AppPalette.textPrimary,
            ),
          ),
        ),
        if (recommended) ...[const SizedBox(width: 8), const _PickBadge()],
      ],
    );
  }
}

/// The "Recommended" pill on the server's top pick for this device.
class _PickBadge extends StatelessWidget {
  const _PickBadge();

  @override
  Widget build(BuildContext context) {
    final color = AppPalette.online;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.14),
        borderRadius: BorderRadius.circular(6),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.auto_awesome, size: 11, color: color),
          const SizedBox(width: 4),
          Text(
            'Recommended',
            style: TextStyle(
              fontSize: 10.5,
              fontWeight: FontWeight.w700,
              color: color,
            ),
          ),
        ],
      ),
    );
  }
}

/// One quiet facts line: quant · download size · context · estimated speed.
class _MetaLine extends StatelessWidget {
  const _MetaLine({required this.model});

  final CatalogModelPick model;

  @override
  Widget build(BuildContext context) {
    final parts = <String>[
      if (model.version != null && model.version!.isNotEmpty) model.version!,
      if (model.sizeBytes > 0) _gbLabel(model.sizeBytes),
      if (model.maxCtx > 0) 'ctx ${formatContextLength(model.maxCtx)}',
      if (model.estTokPerSec > 0) '~${_speed(model.estTokPerSec)} tok/s',
    ];
    if (parts.isEmpty) return const SizedBox.shrink();
    return Text(
      parts.join(' · '),
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
      style: TextStyle(
        fontSize: 12,
        height: 1.28,
        color: AppPalette.textSecondary,
      ),
    );
  }
}

/// Get / spinner / Downloaded — mirrors the shelf tile's action so the two
/// lists behave the same. Only one download runs at a time (the global
/// [modelPullControllerProvider]), so every Get disables while one is in flight;
/// the progress bar shows in the "Paste a model" card, which auto-expands.
class _Action extends ConsumerWidget {
  const _Action({required this.model, required this.downloaded});

  final CatalogModelPick model;
  final bool downloaded;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    AppTheme.watch(context);
    if (downloaded) {
      return Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.check_circle, size: 15, color: AppPalette.online),
          const SizedBox(width: 5),
          Text(
            'Downloaded',
            style: TextStyle(
              fontSize: 11.5,
              fontWeight: FontWeight.w600,
              color: AppPalette.textSecondary,
            ),
          ),
        ],
      );
    }

    final pulling = ref.watch(modelPullControllerProvider) is ModelPulling;
    final spec = model.pullSpec;
    return TextButton.icon(
      onPressed: (pulling || spec == null)
          ? null
          : () => ref.read(modelPullControllerProvider.notifier).pull(spec),
      icon: const Icon(Icons.download_outlined, size: AppControl.iconSize),
      label: const Text('Get'),
      style: TextButton.styleFrom(
        minimumSize: const Size(0, AppControl.heightSmall),
        padding: AppControl.paddingSmall,
      ),
    );
  }
}

/// The doc's "── below here runs slower ──" boundary, drawn where estimated
/// speed drops under the comfortable threshold.
class _SlowerDivider extends StatelessWidget {
  const _SlowerDivider();

  @override
  Widget build(BuildContext context) {
    final color = AppPalette.textFaint;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        children: [
          Expanded(child: Divider(color: color, height: 1)),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 8),
            child: Text(
              'slower on this computer',
              style: TextStyle(fontSize: 10.5, color: AppPalette.textSecondary),
            ),
          ),
          Expanded(child: Divider(color: color, height: 1)),
        ],
      ),
    );
  }
}

/// A one-line status row (loading / no-match) in the suggested section.
class _SuggestStatus extends StatelessWidget {
  const _SuggestStatus({required this.icon, required this.text});

  final IconData? icon;
  final String text;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 22),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          if (icon == null)
            const AppSpinner()
          else
            Icon(icon, size: 18, color: AppPalette.textFaint),
          const SizedBox(width: 10),
          Flexible(
            child: Text(
              text,
              style: TextStyle(fontSize: 13, color: AppPalette.textSecondary),
            ),
          ),
        ],
      ),
    );
  }
}

/// Shown when there's no session token: the catalog needs the user signed in to
/// rank models for their device.
class _SignInHint extends ConsumerWidget {
  const _SignInHint();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    AppTheme.watch(context);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 20, horizontal: 8),
      child: Column(
        children: [
          Icon(Icons.person_outline, size: 20, color: AppPalette.textFaint),
          const SizedBox(height: 8),
          Text(
            'Sign in to see models picked for this computer.',
            textAlign: TextAlign.center,
            style: TextStyle(fontSize: 13, color: AppPalette.textSecondary),
          ),
          const SizedBox(height: 4),
          Text(
            'Or paste a model from Hugging Face below.',
            textAlign: TextAlign.center,
            style: TextStyle(fontSize: 12, color: AppPalette.textFaint),
          ),
        ],
      ),
    );
  }
}

/// `Qwen/Qwen2.5-3B-Instruct-GGUF` → `Qwen2.5 3B Instruct` — the model name
/// without the owner prefix or the `-GGUF` suffix that every row would repeat.
String _displayName(CatalogModelPick model) {
  final repo = model.repoId ?? model.file ?? 'Model';
  final tail = repo.contains('/') ? repo.split('/').last : repo;
  final stripped = tail.replaceAll(
    RegExp(r'[-_]GGUF$', caseSensitive: false),
    '',
  );
  return stripped
      .split(RegExp(r'[-_]'))
      .where((w) => w.isNotEmpty)
      .map((w) => w[0].toUpperCase() + w.substring(1))
      .join(' ');
}

/// Bytes → a compact GB label: `2.4 GB`, or `12 GB` once it's big enough that a
/// decimal is noise.
String _gbLabel(int bytes) {
  final gb = bytes / 1e9;
  return gb >= 10
      ? '${gb.toStringAsFixed(0)} GB'
      : '${gb.toStringAsFixed(1)} GB';
}

/// Estimated tokens/sec rounded for display — whole numbers read cleaner than
/// `8.1` on a card, and the value is an estimate anyway.
String _speed(double tokPerSec) => tokPerSec >= 1
    ? tokPerSec.round().toString()
    : tokPerSec.toStringAsFixed(1);
