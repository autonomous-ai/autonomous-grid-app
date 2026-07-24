import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../infrastructure/cli/parsers/catalog_entry.dart';
import '../../../shared/theme/app_theme.dart';
import '../../plugins/presentation/widgets/extension_tile_surface.dart';
import '../logic/model_pull_controller.dart';
import '../logic/model_shelf.dart';
import '../logic/models_providers.dart';
import 'model_pull_card.dart';
import 'shelf_model_tile.dart';
import 'suggested_models_section.dart';

/// "Manage models" — the model hub that used to be its own tab: download a GGUF
/// and see every model already under `~/.grid/models`. Opened from the local
/// engine block. (Node setup / installing llama.cpp lives in the Engines tab.)
Future<void> showModelManager(BuildContext context) => showDialog<void>(
  context: context,
  // A download can be running in the background — an accidental tap outside
  // shouldn't dismiss the dialog. Only the Close/X button closes it.
  barrierDismissible: false,
  builder: (_) => const _ModelManagerDialog(),
);

class _ModelManagerDialog extends ConsumerWidget {
  const _ModelManagerDialog();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    AppTheme.watch(context); // dialog content: re-colour on a theme flip.
    final catalog = ref.watch(catalogModelsProvider);
    final groups = ref.watch(modelGroupsProvider);
    // The catalog is optional — offline or without the CLI it simply resolves
    // empty, and the shelf is then whatever is already on disk.
    final entries = catalog.asData?.value ?? const <CatalogEntry>[];
    final shelf = buildModelShelf(catalog: entries, groups: groups);
    final downloaded = shelf.where((m) => m.isDownloaded).length;

    final screen = MediaQuery.sizeOf(context);
    final maxWidth = screen.width < 800 ? screen.width - 96 : 640.0;
    final maxHeight = screen.height < 860 ? screen.height * 0.9 : 720.0;

    // No backgroundColor override: the app's dialogTheme already sets the lifted
    // menuFill (#1E1E1E dark / white light). AppPalette.windowBg is #0A0A0A in
    // dark — *darker* than the page behind the dialog, so overriding with it
    // sank the modal instead of lifting it.
    return Dialog(
      child: ConstrainedBox(
        constraints: BoxConstraints(maxWidth: maxWidth, maxHeight: maxHeight),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(26, 22, 26, 22),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            mainAxisSize: MainAxisSize.min,
            children: [
              _DialogHeader(downloaded: downloaded, total: shelf.length),
              const SizedBox(height: 18),
              Flexible(
                child: _ShelfList(
                  shelf: shelf,
                  loading: catalog.isLoading && groups.isEmpty,
                ),
              ),
              const SizedBox(height: 14),
              const _AdvancedPull(),
            ],
          ),
        ),
      ),
    );
  }
}

/// Title, a one-line subtitle that reports the actual state of this computer,
/// and close.
///
/// The subtitle used to be static copy ("Download a model to serve, or see
/// what's already on this computer") — a restatement of the title that told you
/// nothing. It now answers the question the dialog is opened to answer.
class _DialogHeader extends StatelessWidget {
  const _DialogHeader({required this.downloaded, required this.total});

  final int downloaded;
  final int total;

  @override
  Widget build(BuildContext context) {
    AppTheme.watch(context);
    final theme = Theme.of(context);
    // "on this computer" used to close this line, one row above a section
    // header that says ON THIS COMPUTER — the same three words twice.
    final summary = downloaded == 0
        ? 'Nothing downloaded yet — pick one below.'
        : '$downloaded of $total ready to use.';

    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'Manage models',
                style: theme.textTheme.titleLarge?.copyWith(
                  fontWeight: FontWeight.w600,
                ),
              ),
              const SizedBox(height: 4),
              Text(
                summary,
                style: theme.textTheme.bodyMedium?.copyWith(
                  color: AppPalette.textSecondary,
                ),
              ),
            ],
          ),
        ),
        const SizedBox(width: 12),
        IconButton(
          icon: const Icon(Icons.close, size: 18),
          tooltip: 'Close',
          visualDensity: VisualDensity.compact,
          onPressed: () => Navigator.of(context).pop(),
        ),
      ],
    );
  }
}

/// The model list: what's already on this computer, then device-aware
/// suggestions from the catalog API ([SuggestedForDevice], which handles its own
/// loading/empty/sign-in states and falls back to the offline `grid catalog`
/// list). Separated by air and a hover lift rather than `Divider`s, the
/// construction the Plugins and Skills lists use.
class _ShelfList extends StatelessWidget {
  const _ShelfList({required this.shelf, required this.loading});

  final List<ShelfModel> shelf;

  /// Whether the offline `grid catalog` fallback is still loading.
  final bool loading;

  @override
  Widget build(BuildContext context) {
    AppTheme.watch(context);

    // Downloaded models lead: what's already here is what you can serve now,
    // and it's the reason most visits to this dialog happen.
    final ready = shelf.where((m) => m.isDownloaded).toList();
    final available = shelf.where((m) => !m.isDownloaded).toList();

    return ListView(
      shrinkWrap: true,
      padding: EdgeInsets.zero,
      children: [
        if (ready.isNotEmpty) ...[
          ExtensionSectionHeader(label: 'On this computer', count: ready.length),
          for (final model in ready) ...[
            ShelfModelTile(model: model),
            const SizedBox(height: 8),
          ],
        ],
        SuggestedForDevice(fallback: available, fallbackLoading: loading),
      ],
    );
  }
}

/// The free-text `owner/repo:file.gguf` field, folded away.
///
/// It used to open the dialog — the first thing shown was a paste box demanding
/// a format most people don't know, above the one-tap list that makes it
/// unnecessary. It stays fully available, just no longer the opening ask.
///
/// Auto-expands while a download is running so the progress bar and its Cancel
/// button can't be hidden behind a collapsed tile.
class _AdvancedPull extends ConsumerWidget {
  const _AdvancedPull();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    AppTheme.watch(context);
    final pulling = ref.watch(modelPullControllerProvider) is ModelPulling;

    // bubbleFill, matching the rows above: the dialog's own fill is #1E1E1E
    // dark / white light, against which surfaceFill measures 1.023:1 / 1.000:1 —
    // invisible. bubbleFill lifts the right way in both themes, and the field
    // inside stays recessed against it.
    return DecoratedBox(
      decoration: BoxDecoration(
        color: AppGlass.bubbleFill,
        borderRadius: BorderRadius.circular(AppCard.insetRadius),
        boxShadow: AppGlass.cardShadow,
      ),
      child: ExpansionTile(
        // A running download must stay on screen; a finished/idle one starts
        // folded. `key` forces the tile to rebuild its initial state when the
        // download starts, since initiallyExpanded is only read on first build.
        key: ValueKey(pulling),
        initiallyExpanded: pulling,
        tilePadding: const EdgeInsets.symmetric(horizontal: 14),
        childrenPadding: const EdgeInsets.fromLTRB(14, 0, 14, 14),
        dense: true,
        visualDensity: VisualDensity.compact,
        leading: Icon(
          Icons.link_rounded,
          size: 17,
          color: AppPalette.textSecondary,
        ),
        title: Text(
          'Paste a model from Hugging Face',
          style: TextStyle(
            fontSize: 13,
            fontWeight: AppFont.medium,
            color: AppPalette.textPrimary,
          ),
        ),
        children: const [ModelPullCard()],
      ),
    );
  }
}
