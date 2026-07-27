import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../infrastructure/cli/parsers/catalog_entry.dart';
import '../../../shared/theme/app_theme.dart';
import '../../../shared/widgets/app_icon_button.dart';
import '../../../shared/widgets/app_segmented.dart';
import '../logic/model_manager_filter.dart';
import '../logic/model_pull_controller.dart';
import '../logic/model_shelf.dart';
import '../logic/models_providers.dart';
import 'manager_search_field.dart';
import 'discover_tab.dart';
import 'installed_tab.dart';

/// "Manage models" — the model hub that used to be its own tab: download a GGUF
/// and see every model already under `~/.grid/models`. Opened from the local
/// engine block. (Node setup / installing llama.cpp lives in the Engines tab.)
///
/// Split into two tabs ([ModelManagerTab]). The single-column version stacked
/// three unrelated jobs — the shelf, the catalog's suggestions, and a fold-out
/// paste box — inside one 720px-tall dialog whose content rarely filled half of
/// it. Now each tab answers one question, the dialog is sized by what's in it,
/// and a running download is a row in the list rather than something folded away.
Future<void> showModelManager(BuildContext context) => showDialog<void>(
  context: context,
  // A download can be running in the background — an accidental tap outside
  // shouldn't dismiss the dialog. Only the Close/X button closes it.
  barrierDismissible: false,
  builder: (_) => const ModelManagerDialog(),
);

@visibleForTesting
class ModelManagerDialog extends ConsumerStatefulWidget {
  const ModelManagerDialog({super.key});

  @override
  ConsumerState<ModelManagerDialog> createState() => _ModelManagerDialogState();
}

class _ModelManagerDialogState extends ConsumerState<ModelManagerDialog> {
  var _tab = ModelManagerTab.installed;

  /// One controller per tab. Sharing one would carry a filename typed under
  /// Installed into Discover, where it filters the catalog to nothing and looks
  /// like the catalog failed.
  final _installedQuery = TextEditingController();
  final _discoverQuery = TextEditingController();

  @override
  void dispose() {
    _installedQuery.dispose();
    _discoverQuery.dispose();
    super.dispose();
  }

  /// Jumps to Discover — used by the Installed tab's empty state and its
  /// "Add a model" button, so the only two dead ends on that tab both lead
  /// somewhere.
  void _goDiscover() => setState(() => _tab = ModelManagerTab.discover);

  @override
  Widget build(BuildContext context) {
    AppTheme.watch(context); // dialog content: re-colour on a theme flip.
    final catalog = ref.watch(catalogModelsProvider);
    final groups = ref.watch(modelGroupsProvider);
    // The catalog is optional — offline or without the CLI it simply resolves
    // empty, and the shelf is then whatever is already on disk.
    final entries = catalog.asData?.value ?? const <CatalogEntry>[];
    final shelf = buildModelShelf(catalog: entries, groups: groups);
    final installed = [
      for (final model in shelf)
        if (model.isDownloaded) model,
    ];
    final available = [
      for (final model in shelf)
        if (!model.isDownloaded) model,
    ];

    final screen = MediaQuery.sizeOf(context);
    final maxWidth = screen.width < 800 ? screen.width - 96 : 640.0;
    // A ceiling, not a height. The old dialog set 720 and left the middle empty
    // whenever the content came up short; the Column below is `min`, so it now
    // shrink-wraps and only hits this bound when a list is genuinely long.
    final maxHeight = screen.height < 860 ? screen.height * 0.9 : 660.0;

    // No backgroundColor override: the app's dialogTheme already sets the lifted
    // menuFill (#1E1E1E dark / white light). AppPalette.windowBg is #0A0A0A in
    // dark — *darker* than the page behind the dialog, so overriding with it
    // sank the modal instead of lifting it.
    return Dialog(
      child: ConstrainedBox(
        constraints: BoxConstraints(maxWidth: maxWidth, maxHeight: maxHeight),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          mainAxisSize: MainAxisSize.min,
          children: [
            _Header(
              tab: _tab,
              installed: installed,
              onClose: () => Navigator.of(context).pop(),
            ),
            _Controls(
              tab: _tab,
              installedCount: installed.length,
              controller: _tab == ModelManagerTab.installed
                  ? _installedQuery
                  : _discoverQuery,
              onTab: (tab) => setState(() => _tab = tab),
            ),
            Flexible(
              child: switch (_tab) {
                ModelManagerTab.installed => InstalledTab(
                  installed: installed,
                  query: _installedQuery,
                  onDiscover: _goDiscover,
                ),
                ModelManagerTab.discover => DiscoverTab(
                  fallback: available,
                  fallbackLoading: catalog.isLoading && groups.isEmpty,
                  // Whether `grid catalog` itself answered, which is *not* the
                  // same question as whether `available` has rows in it — see
                  // SuggestedForDevice._fallbackSection.
                  catalogReadable: entries.isNotEmpty,
                  query: _discoverQuery,
                ),
              },
            ),
            _Footer(tab: _tab, onAdd: _goDiscover),
          ],
        ),
      ),
    );
  }
}

/// Title, one line reporting the actual state of this computer, and close.
///
/// The subtitle used to read "1 of 1 ready to use" — a ratio that is always
/// `n of n` once everything suggested is downloaded, and which never mentions
/// the number this screen exists to act on. It now leads with disk.
class _Header extends StatelessWidget {
  const _Header({
    required this.tab,
    required this.installed,
    required this.onClose,
  });

  final ModelManagerTab tab;
  final List<ShelfModel> installed;
  final VoidCallback onClose;

  @override
  Widget build(BuildContext context) {
    AppTheme.watch(context);
    final theme = Theme.of(context);
    final bytes = totalInstalledBytes(installed);
    final summary = switch (tab) {
      ModelManagerTab.discover => 'Models ranked for this computer.',
      _ when installed.isEmpty => 'Nothing downloaded yet.',
      _ =>
        '${formatGb(bytes)} used by '
            '${installed.length} model${installed.length == 1 ? '' : 's'}',
    };

    return Padding(
      padding: const EdgeInsets.fromLTRB(24, 20, 16, 0),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Manage models',
                  style: theme.textTheme.titleLarge?.copyWith(
                    fontSize: 19,
                    fontWeight: FontWeight.w600,
                    letterSpacing: -0.2,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  summary,
                  style: TextStyle(
                    fontSize: 13,
                    height: 1.28,
                    color: AppPalette.textSecondary,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(width: 12),
          AppIconButton(
            icon: Icons.close,
            // 18 — a dialog's close, the size the app draws it at elsewhere.
            size: 18,
            tooltip: 'Close',
            onPressed: onClose,
          ),
        ],
      ),
    );
  }
}

/// The tab switch and the search box, on one strip.
///
/// They share a row because they act on the same thing: the switch picks which
/// list is showing, the box narrows it. Stacked, the box would read as belonging
/// to the dialog rather than to the tab under it.
class _Controls extends StatelessWidget {
  const _Controls({
    required this.tab,
    required this.installedCount,
    required this.controller,
    required this.onTab,
  });

  final ModelManagerTab tab;
  final int installedCount;
  final TextEditingController controller;
  final ValueChanged<ModelManagerTab> onTab;

  @override
  Widget build(BuildContext context) {
    AppTheme.watch(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(24, 16, 24, 0),
      child: Row(
        children: [
          AppSegmented(
            segments: [
              SegmentSpec(
                label: ModelManagerTab.installed.label,
                // Hidden at zero: a "0" beside the tab reads as a broken
                // counter, and the empty state on the tab says it better.
                count: installedCount == 0 ? null : installedCount,
              ),
              SegmentSpec(label: ModelManagerTab.discover.label),
            ],
            selected: tab.index,
            onChanged: (i) => onTab(ModelManagerTab.values[i]),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: ManagerSearchField(
              controller: controller,
              // Discover's box doubles as the paste box — see DiscoverTab.
              hint: tab == ModelManagerTab.installed
                  ? 'Filter…'
                  : 'Search, or paste owner/repo:file.gguf',
            ),
          ),
        ],
      ),
    );
  }
}

/// The strip under the list: where the files live, and the way to the other tab.
///
/// Discover's half carries the Hugging Face link that used to sit inside the
/// fold-out paste card, where it was only reachable after expanding a tile.
class _Footer extends ConsumerWidget {
  const _Footer({required this.tab, required this.onAdd});

  final ModelManagerTab tab;
  final VoidCallback onAdd;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    AppTheme.watch(context);
    // A download in flight owns the footer: it's the one thing in the dialog
    // that can still be acted on while everything else waits.
    final pulling = ref.watch(modelPullControllerProvider) is ModelPulling;

    return Padding(
      padding: const EdgeInsets.fromLTRB(24, 16, 24, 20),
      child: Row(
        children: [
          Expanded(
            child: Text(
              switch (tab) {
                ModelManagerTab.installed =>
                  'Models are stored in ~/.grid/models',
                ModelManagerTab.discover when pulling =>
                  'The download continues if you close this.',
                ModelManagerTab.discover =>
                  'Paste owner/repo:file.gguf above — one line per file.',
              },
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: 12,
                height: 1.28,
                color: AppPalette.textSecondary,
              ),
            ),
          ),
          const SizedBox(width: 12),
          if (tab == ModelManagerTab.installed)
            FilledButton.icon(
              onPressed: onAdd,
              icon: const Icon(Icons.add, size: AppControl.iconSize),
              label: const Text('Add a model'),
            )
          else
            const _BrowseButton(),
        ],
      ),
    );
  }
}

/// Opens Hugging Face's GGUF listing in the browser.
class _BrowseButton extends StatelessWidget {
  const _BrowseButton();

  @override
  Widget build(BuildContext context) {
    return TextButton.icon(
      onPressed: openHuggingFaceGguf,
      icon: const Icon(Icons.open_in_new, size: AppControl.iconSize),
      // The field above already says Hugging Face; repeating it here would
      // spend half the label saying where the user knows they are.
      label: const Text('Browse models'),
      style: TextButton.styleFrom(
        minimumSize: const Size(0, AppControl.heightSmall),
        padding: AppControl.paddingSmall,
      ),
    );
  }
}
