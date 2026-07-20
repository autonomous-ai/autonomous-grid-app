import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../infrastructure/cli/parsers/catalog_entry.dart';
import '../../../shared/theme/app_theme.dart';
import '../../../shared/widgets/app_spinner.dart';
import '../../plugins/presentation/widgets/extension_tile_surface.dart';
import '../logic/model_pull_controller.dart';
import '../logic/model_shelf.dart';
import '../logic/models_providers.dart';
import 'model_pull_card.dart';
import 'shelf_model_tile.dart';

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
    final summary = downloaded == 0
        ? 'Nothing downloaded yet — pick one below to get started.'
        : '$downloaded of $total ready to serve on this computer.';

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

/// The merged shelf: every model once, downloaded ones first.
///
/// Separated by air and a hover lift rather than by `Divider`s inside a bordered
/// card — the construction the Plugins and Skills lists use.
class _ShelfList extends StatelessWidget {
  const _ShelfList({required this.shelf, required this.loading});

  final List<ShelfModel> shelf;
  final bool loading;

  @override
  Widget build(BuildContext context) {
    AppTheme.watch(context);
    if (loading) return const _ShelfLoading();
    if (shelf.isEmpty) return const _ShelfEmpty();

    // Downloaded models lead: what's already here is what you can serve now,
    // and it's the reason most visits to this dialog happen.
    final ready = shelf.where((m) => m.isDownloaded).toList();
    final available = shelf.where((m) => !m.isDownloaded).toList();

    final items = <Widget>[];
    if (ready.isNotEmpty) {
      items.add(
        ExtensionSectionHeader(label: 'On this computer', count: ready.length),
      );
      for (final model in ready) {
        items.add(ShelfModelTile(model: model));
        items.add(const SizedBox(height: 8));
      }
      if (available.isNotEmpty) items.add(const SizedBox(height: 10));
    }
    if (available.isNotEmpty) {
      items.add(
        ExtensionSectionHeader(
          label: 'Suggested for your device',
          count: available.length,
        ),
      );
      for (final model in available) {
        items.add(ShelfModelTile(model: model));
        items.add(const SizedBox(height: 8));
      }
    }

    return ListView(
      shrinkWrap: true,
      padding: EdgeInsets.zero,
      children: items,
    );
  }
}

/// A quiet placeholder while `grid catalog` is being read.
class _ShelfLoading extends StatelessWidget {
  const _ShelfLoading();

  @override
  Widget build(BuildContext context) {
    AppTheme.watch(context);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 28),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          const AppSpinner(),
          const SizedBox(width: 10),
          Text(
            'Looking for models…',
            style: TextStyle(fontSize: 13, color: AppPalette.textSecondary),
          ),
        ],
      ),
    );
  }
}

/// No catalog and nothing on disk — the CLI is unreachable or offline. Points at
/// the advanced field below, which still works.
class _ShelfEmpty extends StatelessWidget {
  const _ShelfEmpty();

  @override
  Widget build(BuildContext context) {
    AppTheme.watch(context);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 28, horizontal: 8),
      child: Column(
        children: [
          Icon(Icons.cloud_off_outlined, size: 22, color: AppPalette.textFaint),
          const SizedBox(height: 10),
          Text(
            "No models here yet, and suggestions couldn't be loaded.",
            textAlign: TextAlign.center,
            style: TextStyle(fontSize: 13, color: AppPalette.textSecondary),
          ),
          const SizedBox(height: 4),
          Text(
            'You can still paste a Hugging Face model below.',
            textAlign: TextAlign.center,
            style: TextStyle(fontSize: 12, color: AppPalette.textFaint),
          ),
        ],
      ),
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
            fontWeight: FontWeight.w600,
            color: AppPalette.textPrimary,
          ),
        ),
        children: const [ModelPullCard()],
      ),
    );
  }
}
