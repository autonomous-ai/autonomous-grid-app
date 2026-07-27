import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../infrastructure/api/models/model_catalog.dart';
import '../../../shared/theme/app_theme.dart';
import '../../plugins/presentation/widgets/extension_tile_surface.dart';
import '../logic/context_length.dart';
import '../logic/model_manager_filter.dart';
import '../logic/model_pull_controller.dart';
import '../logic/model_shelf.dart';
import '../logic/models_providers.dart';
import '../logic/suggested_catalog.dart';
import 'discover_tab.dart';
import 'shelf_model_tile.dart';

/// The ranked-suggestions body of the Discover tab.
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
    required this.catalogReadable,
    this.filter = '',
  });

  /// The offline `grid catalog` suggestions to show when the API is unavailable
  /// — already filtered down to what isn't downloaded yet.
  final List<ShelfModel> fallback;

  /// Whether the offline catalog is still loading (so a transient API failure
  /// doesn't flash an empty fallback before it arrives).
  final bool fallbackLoading;

  /// Whether `grid catalog` returned anything at all. See [_fallbackSection].
  final bool catalogReadable;

  /// What's typed in the Discover search box. Empty shows everything.
  final String filter;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    AppTheme.watch(context);
    final outcome = ref.watch(suggestedCatalogProvider);

    return outcome.when(
      loading: () => const DiscoverStatusRow(
        icon: null,
        title: 'Finding models for this computer',
        message: 'Reading your hardware and asking the catalog…',
      ),
      // An unexpected throw (not a mapped outcome) still degrades to the offline
      // list rather than an error box.
      error: (_, _) => _fallbackSection(ref),
      data: (result) => switch (result) {
        SuggestReady(:final ranked, :final pick) => _ApiSuggestions(
          ranked: ranked,
          pick: pick,
          filter: filter,
        ),
        SuggestNoMatch() => const DiscoverStatusRow(
          icon: Icons.search_off_rounded,
          title: 'No model fits this computer',
          message: 'You can still paste one in the box above.',
        ),
        SuggestSignInRequired() => const DiscoverStatusRow(
          icon: Icons.person_outline,
          title: 'Sign in to see models for this computer',
          message: 'Or paste a owner/repo:file.gguf in the box above.',
        ),
        SuggestUnavailable() => _fallbackSection(ref),
      },
    );
  }

  /// The offline list, or — when there isn't one — a row saying why.
  ///
  /// Three ways this list can come up empty, and they are *not* the same thing:
  ///
  ///  1. still loading;
  ///  2. `grid catalog` answered, but every model it knows about is already on
  ///     disk ([catalogReadable] true, [fallback] empty);
  ///  3. `grid catalog` gave us nothing at all.
  ///
  /// Only (3) is a failure. An earlier version keyed the error row on
  /// `fallback.isEmpty` alone, so a machine that had simply downloaded
  /// everything the catalog offers — one model, on this developer's Mac — was
  /// told the catalog couldn't be reached while `grid catalog` was answering
  /// fine. "Empty because it's all filtered out" is not "empty because it
  /// broke".
  Widget _fallbackSection(WidgetRef ref) {
    final matches = filterInstalled(fallback, filter);

    if (fallbackLoading && fallback.isEmpty) {
      return const DiscoverStatusRow(
        icon: null,
        title: 'Looking for models',
        message: 'Reading the offline catalog…',
      );
    }
    if (fallback.isEmpty && catalogReadable) {
      return const DiscoverStatusRow(
        icon: Icons.check_circle_outline,
        title: "You've already got everything suggested",
        message:
            'Nothing new for this computer right now. Paste a '
            'owner/repo:file.gguf above to add another.',
      );
    }
    if (fallback.isEmpty) {
      return DiscoverStatusRow(
        icon: Icons.cloud_off_rounded,
        title: "Couldn't reach the model catalog",
        message: 'Check your connection, or paste a model in the box above.',
        // Invalidating both is deliberate: the API call is what usually failed,
        // but a missing CLI takes out the offline list too, and a user pressing
        // Retry means "try all of it again".
        onRetry: () {
          ref.invalidate(suggestedCatalogProvider);
          ref.invalidate(catalogModelsProvider);
        },
      );
    }
    if (matches.isEmpty) return DiscoverNoMatch(needle: filter.trim());

    return _SectionBody(
      count: matches.length,
      children: [for (final model in matches) ShelfModelTile(model: model)],
    );
  }
}

/// The API-ranked list: the recommended pick, its alternatives, and a divider
/// marking where models start running noticeably slower on this machine.
class _ApiSuggestions extends ConsumerWidget {
  const _ApiSuggestions({
    required this.ranked,
    required this.pick,
    required this.filter,
  });

  final List<CatalogModelPick> ranked;
  final CatalogModelPick pick;
  final String filter;

  /// Below this tokens/sec a model runs noticeably slower — the doc's cue for a
  /// "── slower below here ──" divider so the user sees the boundary.
  static const _slowBelow = 8.0;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    AppTheme.watch(context);
    // Cross-reference what's already on disk (by GGUF filename) so a suggestion
    // already downloaded reads "Downloaded" instead of offering Get again.
    final onDisk = {
      for (final m in ref.watch(localModelsProvider)) m.name.toLowerCase(),
    };

    final matches = filterPicks(ranked, filter);
    if (matches.isEmpty) return DiscoverNoMatch(needle: filter.trim());

    final children = <Widget>[];
    var dividerShown = false;
    for (final model in matches) {
      final slow = model.estTokPerSec > 0 && model.estTokPerSec < _slowBelow;
      if (slow && !dividerShown && children.isNotEmpty) {
        children.add(const _SlowerDivider());
        dividerShown = true;
      }
      children.add(
        _SuggestedTile(
          model: model,
          // Only while unfiltered: with a query typed, whichever row happens to
          // match first is not "the recommendation", and washing it accent
          // would say it is.
          recommended: identical(model, pick) && filter.trim().isEmpty,
          downloaded:
              model.file != null && onDisk.contains(model.file!.toLowerCase()),
        ),
      );
    }

    return _SectionBody(count: matches.length, children: children);
  }
}

/// Header + spaced tiles, kept in one place so the API and fallback lists look
/// identical.
class _SectionBody extends StatelessWidget {
  const _SectionBody({required this.count, required this.children});

  final int count;
  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        ExtensionSectionHeader(label: 'Ranked for this computer', count: count),
        for (final child in children) ...[child, const SizedBox(height: 8)],
      ],
    );
  }
}

/// One catalog suggestion: name, a facts line (quant · size · context · speed),
/// and the one action — Get, or a "Downloaded" tag when it's already here.
///
/// The top pick is raised onto an accent wash instead of wearing a pill. A
/// filled "Recommended" chip measured **3.78:1** against that wash in dark
/// (accentOnSurface on `tint25` over `tint18`), under the 4.5:1 a label of that
/// size needs; the wash itself carries the meaning, and the label rides on the
/// row where it reaches 4.73:1.
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
    final row = Row(
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
              _TitleRow(name: _displayName(model), recommended: recommended),
              const SizedBox(height: 4),
              _MetaLine(model: model),
            ],
          ),
        ),
        const SizedBox(width: 12),
        _Action(model: model, downloaded: downloaded, recommended: recommended),
      ],
    );

    if (!recommended) return ExtensionTileSurface(onDialog: true, child: row);

    // The wash is the marker, so it's built by hand — GlassCard would add its
    // own indigo wash and aura on top of this one (§2).
    return DecoratedBox(
      decoration: BoxDecoration(
        color: AppCard.tint18,
        borderRadius: BorderRadius.circular(14),
        boxShadow: AppGlass.cardShadow,
      ),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(15, 12, 14, 12),
        child: row,
      ),
    );
  }
}

/// The model name, with the "Recommended" label on the top pick.
class _TitleRow extends StatelessWidget {
  const _TitleRow({required this.name, required this.recommended});

  final String name;
  final bool recommended;

  @override
  Widget build(BuildContext context) {
    AppTheme.watch(context);
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
        if (recommended) ...[
          const SizedBox(width: 8),
          Icon(
            Icons.auto_awesome,
            size: 11,
            // accentOnSurface (#6E8BFF dark), not accentStrong (#5C7CFF): on
            // this wash accentStrong measures 4.02:1, accentOnSurface 4.73:1.
            color: AppPalette.accentOnSurface,
          ),
          const SizedBox(width: 4),
          Text(
            'Recommended',
            style: TextStyle(
              fontSize: 11,
              height: 1.2,
              fontWeight: FontWeight.w700,
              color: AppPalette.accentOnSurface,
            ),
          ),
        ],
      ],
    );
  }
}

/// One quiet facts line: quant · download size · context · estimated speed.
class _MetaLine extends StatelessWidget {
  const _MetaLine({required this.model});

  final CatalogModelPick model;

  @override
  Widget build(BuildContext context) {
    AppTheme.watch(context);
    final parts = <String>[
      if (model.version != null && model.version!.isNotEmpty) model.version!,
      if (model.sizeBytes > 0) formatGb(model.sizeBytes),
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
        fontFeatures: AppFont.tabularFigures,
        color: AppPalette.textSecondary,
      ),
    );
  }
}

/// Get / Downloaded — mirrors the shelf tile's action so the two lists behave
/// the same. Only one download runs at a time (the global
/// [modelPullControllerProvider]), so every Get disables while one is in flight;
/// its progress shows as a row at the top of this same list.
class _Action extends ConsumerWidget {
  const _Action({
    required this.model,
    required this.downloaded,
    required this.recommended,
  });

  final CatalogModelPick model;
  final bool downloaded;

  /// The top pick's Get is filled — one primary action per list, on the row the
  /// server says to take.
  final bool recommended;

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
    final onPressed = (pulling || spec == null)
        ? null
        : () => ref.read(modelPullControllerProvider.notifier).pull(spec);
    final icon = const Icon(Icons.download_outlined, size: AppControl.iconSize);
    const label = Text('Get');

    if (recommended) {
      return FilledButton.icon(
        onPressed: onPressed,
        icon: icon,
        label: label,
        style: FilledButton.styleFrom(
          minimumSize: const Size(0, AppControl.heightSmall),
          padding: AppControl.paddingSmall,
        ),
      );
    }
    return TextButton.icon(
      onPressed: onPressed,
      icon: icon,
      label: label,
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
    AppTheme.watch(context);
    final color = AppPalette.divider;
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

/// `Qwen/Qwen2.5-3B-Instruct-GGUF` → `Qwen2.5-3B-Instruct` — the model name
/// without the owner prefix or the `-GGUF` suffix that every row would repeat.
String _displayName(CatalogModelPick model) {
  final repo = model.repoId ?? model.file ?? 'Model';
  final tail = repo.contains('/') ? repo.split('/').last : repo;
  return tail.replaceAll(RegExp(r'[-_]GGUF$', caseSensitive: false), '');
}

/// Estimated tokens/sec rounded for display — whole numbers read cleaner than
/// `8.1` on a card, and the value is an estimate anyway.
String _speed(double tokPerSec) => tokPerSec >= 1
    ? tokPerSec.round().toString()
    : tokPerSec.toStringAsFixed(1);
