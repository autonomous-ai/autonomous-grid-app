import 'dart:async';

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../infrastructure/api/models/model_catalog.dart';
import '../../../shared/theme/app_theme.dart';
import '../../../shared/widgets/labeled_field.dart' show appMenuStyle;
import '../logic/model_manager_filter.dart';
import '../logic/models_providers.dart';
import '../logic/suggested_catalog.dart';
import 'model_detail_panel.dart';

enum _SortMode { recommended, trending, mostLiked, newest }

extension on _SortMode {
  String get label => switch (this) {
        _SortMode.recommended => 'Recommended',
        _SortMode.trending => 'Trending',
        _SortMode.mostLiked => 'Most liked',
        _SortMode.newest => 'Newest',
      };

  /// Value sent as `sort` on `POST /v1/grid/catalog`. Empty for the local-only
  /// "Recommended" mode (the suggest endpoint has its own ranking), which means
  /// the key is left out of the body entirely.
  ///
  /// These are the API's own keys — it accepts `trending | downloads | likes |
  /// created` and silently falls back to `trending` for anything else, so
  /// "Newest" has to send `created`, not the word in its label.
  String get apiValue => switch (this) {
        _SortMode.recommended => '',
        _SortMode.trending => 'trending',
        _SortMode.mostLiked => 'likes',
        _SortMode.newest => 'created',
      };
}

/// Whether the column shows everything, only what's already on this computer,
/// or only what isn't.
///
/// This is the Installed/Discover split as a filter rather than as two tabs:
/// the same question ("do I have this one?"), asked without splitting the list
/// in two and without a second search box and a second scroll position to keep
/// in sync.
enum _InstallFilter { all, installed, notInstalled }

extension on _InstallFilter {
  String get label => switch (this) {
        _InstallFilter.all => 'All models',
        _InstallFilter.installed => 'Installed',
        _InstallFilter.notInstalled => 'Not installed',
      };

  /// Whether a row in [state] survives this filter.
  bool admits({required bool installed}) => switch (this) {
        _InstallFilter.all => true,
        _InstallFilter.installed => installed,
        _InstallFilter.notInstalled => !installed,
      };
}

class ModelManagerSplitView extends ConsumerStatefulWidget {
  const ModelManagerSplitView({super.key});

  @override
  ConsumerState<ModelManagerSplitView> createState() => _ModelManagerSplitViewState();
}

/// How long the search box waits after the last keystroke before it asks the
/// catalog. Long enough that typing a repo name is one request rather than a
/// dozen, short enough that the list still feels like it's following along.
const _searchDebounce = Duration(milliseconds: 350);

class _ModelManagerSplitViewState extends ConsumerState<ModelManagerSplitView> {
  String? _selectedRepoId;

  /// What's in the search box right now, updated on every keystroke. Never hits
  /// the network by itself — it's here so picking a sort can send the term the
  /// user can *see*, even mid-debounce.
  String _input = '';

  /// The term actually sent to the catalog: [_input] once it has settled.
  String _query = '';

  _SortMode _sort = _SortMode.recommended;
  _InstallFilter _install = _InstallFilter.all;
  Timer? _debounce;

  @override
  void initState() {
    super.initState();
    // Auto-select the first model once the list/suggestion resolves.
    _autoSelectFirst();
  }

  @override
  void dispose() {
    _debounce?.cancel();
    super.dispose();
  }

  /// A keystroke. The request goes out on [_searchDebounce], carrying `q` only:
  /// a search isn't a ranking, so it drops back to Recommended rather than
  /// quietly filtering inside whichever sort was left selected — that way the
  /// menu's label always names what was actually sent.
  void _onQuery(String value) {
    _input = value;
    _debounce?.cancel();
    if (_sort != _SortMode.recommended) {
      setState(() => _sort = _SortMode.recommended);
    }
    _debounce = Timer(_searchDebounce, () {
      if (!mounted) return;
      final settled = value.trim();
      if (settled == _query) return;
      setState(() => _query = settled);
    });
  }

  /// A pick from the sort menu — the one gesture that sends a `sort`. It also
  /// flushes any pending keystrokes, so the results are ranked over the term
  /// showing in the box rather than the one from a third of a second ago.
  void _onSort(_SortMode mode) {
    _debounce?.cancel();
    setState(() {
      _sort = mode;
      _query = _input.trim();
    });
  }

  Future<void> _autoSelectFirst() async {
    final picks = await ref.read(suggestedCatalogProvider.future);
    if (!mounted) return;
    if (picks is SuggestReady && picks.ranked.isNotEmpty) {
      final first = picks.ranked.firstWhere(
        (m) => m.repoId != null && m.repoId!.isNotEmpty,
        orElse: () => picks.ranked.first,
      );
      if (first.repoId != null && mounted) {
        setState(() => _selectedRepoId = first.repoId);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    AppTheme.watch(context);
    final asyncSuggestion = ref.watch(suggestedCatalogProvider);

    // Also auto-select when the suggestion transitions from loading → ready
    // (initState's read might race with the first frame).
    ref.listen<AsyncValue<SuggestOutcome>>(suggestedCatalogProvider, (prev, next) {
      if (_selectedRepoId != null) return;
      final value = next.asData?.value;
      if (value is SuggestReady && value.ranked.isNotEmpty) {
        final first = value.ranked.firstWhere(
          (m) => m.repoId != null && m.repoId!.isNotEmpty,
          orElse: () => value.ranked.first,
        );
        if (first.repoId != null) {
          setState(() => _selectedRepoId = first.repoId);
        }
      }
    });

    return Row(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
         SizedBox(
           width: 340,
           child: _Sidebar(
            suggestion: asyncSuggestion,
            selectedRepoId: _selectedRepoId,
            query: _query,
            sort: _sort,
            install: _install,
            onQuery: _onQuery,
            onSort: _onSort,
            onInstall: (f) => setState(() => _install = f),
            onSelect: (id) => setState(() => _selectedRepoId = id),
          ),
        ),
        VerticalDivider(width: 1, color: AppPalette.divider),
        Expanded(
          child: _selectedRepoId == null
              ? const _EmptyDetail()
              : ModelDetailPanel(repoId: _selectedRepoId!),
        ),
      ],
    );
  }
}

class _Sidebar extends ConsumerWidget {
  const _Sidebar({
    required this.suggestion,
    required this.selectedRepoId,
    required this.query,
    required this.sort,
    required this.install,
    required this.onQuery,
    required this.onSort,
    required this.onInstall,
    required this.onSelect,
  });

  final AsyncValue<SuggestOutcome> suggestion;
  final String? selectedRepoId;
  final String query;
  final _SortMode sort;
  final _InstallFilter install;
  final ValueChanged<String> onQuery;
  final ValueChanged<_SortMode> onSort;
  final ValueChanged<_InstallFilter> onInstall;
  final ValueChanged<String> onSelect;

  /// True when the device-fit suggestion came back with nothing to show, so the
  /// column falls back to the plain catalog list instead of an empty panel.
  /// Signed-out isn't one of these — that case has its own message.
  bool get _suggestionFellThrough => switch (suggestion) {
        AsyncData(:final value) => value is SuggestNoMatch || value is SuggestUnavailable,
        AsyncError() => true,
        _ => false,
      };

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    AppTheme.watch(context);
    final needle = query.trim();
    // The list call is only made when something asks for it: a search term, a
    // chosen ranking, or a suggestion that fell through. Recommended-with-no-
    // search stays on the suggest endpoint and costs no extra request.
    final wantsList =
        needle.isNotEmpty || sort.apiValue.isNotEmpty || _suggestionFellThrough;
    final listAsync = wantsList
        ? ref.watch(catalogListProvider((sort: sort.apiValue, query: needle)))
        : const AsyncValue<List<CatalogListEntry>?>.data(null);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 12, 12, 8),
          child: TextField(
            decoration: InputDecoration(
              hintText: 'Search models…',
              prefixIcon: const Icon(Icons.search, size: 18),
              isDense: true,
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(AppCard.insetRadius),
                borderSide: BorderSide.none,
              ),
              filled: true,
              fillColor: AppGlass.bubbleFill,
            ),
            style: const TextStyle(fontSize: 13),
            onChanged: onQuery,
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 0, 12, 6),
          // Sized to their own labels, not to the column: a picker that spans
          // the full width reads as a second, heavier search field. Wrapped so
          // a narrow column stacks them instead of clipping the second.
          child: Wrap(
            spacing: 6,
            runSpacing: 6,
            children: [
              _PillDropdown<_SortMode>(
                value: sort,
                options: _SortMode.values,
                labelOf: (mode) => mode.label,
                icon: Icons.sort,
                semanticLabel: 'Sort models',
                onChanged: onSort,
              ),
              _PillDropdown<_InstallFilter>(
                value: install,
                options: _InstallFilter.values,
                labelOf: (filter) => filter.label,
                icon: Icons.inventory_2_outlined,
                semanticLabel: 'Filter by install state',
                onChanged: onInstall,
              ),
            ],
          ),
        ),
        Expanded(
          // A search term always means catalog results — the device-fit picks
          // are a ranking of what fits this Mac, not something to filter.
          child: sort == _SortMode.recommended && needle.isEmpty
              ? _suggestionBody(ref, listAsync)
              : _listBody(ref, listAsync),
        ),
      ],
    );
  }

  Widget _suggestionBody(WidgetRef ref, AsyncValue<List<CatalogListEntry>?> listAsync) {
    return switch (suggestion) {
      AsyncData(:final value) => switch (value) {
          SuggestReady(:final ranked) => _rankedListOrEmpty(_keepPicks(ranked, ref)),
          SuggestNoMatch() || SuggestUnavailable() => _listBody(ref, listAsync),
          SuggestSignInRequired() => const _SidebarMessage(
              icon: Icons.lock_outline,
              text: 'Sign in to see suggestions.',
            ),
        },
      AsyncError() => _listBody(ref, listAsync),
      _ => const Center(child: CircularProgressIndicator()),
    };
  }

  Widget _listBody(WidgetRef ref, AsyncValue<List<CatalogListEntry>?> listAsync) {
    return switch (listAsync) {
      AsyncData(:final value) when value != null && value.isNotEmpty =>
        _entryListOrEmpty(_keepEntries(value, ref)),
      AsyncData() => const _SidebarMessage(
          icon: Icons.search_off_outlined,
          text: 'No models found.',
        ),
      AsyncError() => const _SidebarMessage(
          icon: Icons.error_outline,
          text: "Couldn't load the catalog.",
        ),
      _ => const Center(child: CircularProgressIndicator()),
    };
  }

  Widget _entryListOrEmpty(List<CatalogListEntry> entries) => entries.isEmpty
      ? _emptyForFilter
      : _EntryList(
          entries: entries,
          selectedRepoId: selectedRepoId,
          onSelect: onSelect,
        );

  Widget _rankedListOrEmpty(List<CatalogModelPick> ranked) => ranked.isEmpty
      ? _emptyForFilter
      : _RankedList(
          ranked: ranked,
          selectedRepoId: selectedRepoId,
          onSelect: onSelect,
        );

  /// Distinct from "No models found": the catalog *did* answer, and the install
  /// filter is what emptied the column — so the message names the filter rather
  /// than sending the user off to fix a search that isn't wrong.
  Widget get _emptyForFilter => _SidebarMessage(
        icon: Icons.filter_alt_off_outlined,
        text: install == _InstallFilter.installed
            ? "None of these are on this computer yet."
            : 'Every model here is already installed.',
      );

  /// The names on disk, as the install test wants them. Read through the widget
  /// ref so the column re-filters the moment a download lands.
  List<String> _localNames(WidgetRef ref) =>
      [for (final model in ref.watch(localModelsProvider)) model.name];

  List<CatalogListEntry> _keepEntries(List<CatalogListEntry> entries, WidgetRef ref) {
    if (install == _InstallFilter.all) return entries;
    final local = _localNames(ref);
    return [
      for (final entry in entries)
        if (install.admits(
          installed: isCatalogModelInstalled(
            repoId: entry.repoId,
            localFileNames: local,
          ),
        ))
          entry,
    ];
  }

  List<CatalogModelPick> _keepPicks(List<CatalogModelPick> picks, WidgetRef ref) {
    if (install == _InstallFilter.all) return picks;
    final local = _localNames(ref);
    return [
      for (final pick in picks)
        if (install.admits(
          installed: isCatalogModelInstalled(
            repoId: pick.repoId ?? '',
            file: pick.file,
            localFileNames: local,
          ),
        ))
          pick,
    ];
  }
}

/// The catalog's results. No local filtering: the search term went to the API
/// as `q`, so what came back *is* the match set — narrowing it again here would
/// hide rows the server matched on fields the repo id doesn't show.
class _EntryList extends StatelessWidget {
  const _EntryList({
    required this.entries,
    required this.selectedRepoId,
    required this.onSelect,
  });

  final List<CatalogListEntry> entries;
  final String? selectedRepoId;
  final ValueChanged<String> onSelect;

  @override
  Widget build(BuildContext context) {
    AppTheme.watch(context);
    return ListView.separated(
      padding: const EdgeInsets.symmetric(horizontal: 8),
      itemCount: entries.length,
      separatorBuilder: (_, __) => const SizedBox(height: 2),
      itemBuilder: (_, i) {
        final e = entries[i];
        final selected = e.repoId == selectedRepoId;
        return _SidebarTile(
          title: _displayName(e.repoId),
          likes: e.likes,
          downloads: e.downloads,
          createdAt: e.createdAt,
          selected: selected,
          iconUrl: e.iconUrl,
          onTap: () => onSelect(e.repoId),
        );
      },
    );
  }
}

class _RankedList extends StatelessWidget {
  const _RankedList({
    required this.ranked,
    required this.selectedRepoId,
    required this.onSelect,
  });

  final List<CatalogModelPick> ranked;
  final String? selectedRepoId;
  final ValueChanged<String> onSelect;

  @override
  Widget build(BuildContext context) {
    AppTheme.watch(context);
    return ListView.separated(
      padding: const EdgeInsets.symmetric(horizontal: 8),
      itemCount: ranked.length,
      separatorBuilder: (_, __) => const SizedBox(height: 2),
      itemBuilder: (_, i) {
        final m = ranked[i];
        final repoId = m.repoId ?? '';
        final selected = repoId.isNotEmpty && repoId == selectedRepoId;
        return _SidebarTile(
          title: _displayName(repoId),
          likes: m.likes,
          downloads: m.downloads,
          createdAt: m.createdAt,
          selected: selected,
          iconUrl: m.iconUrl,
          onTap: repoId.isEmpty ? null : () => onSelect(repoId),
        );
      },
    );
  }
}

/// One model in the column. Highlights exactly like the app's own sidebar rows
/// ([SidebarItem]): the neutral selected fill rather than an accent wash, a
/// lighter fill under the pointer, and the 3px accent rail on the selected row —
/// two lists in the same window that mean "this one" two different ways read as
/// two different apps.
class _SidebarTile extends StatefulWidget {
  const _SidebarTile({
    required this.title,
    this.likes = 0,
    this.downloads = 0,
    this.createdAt,
    required this.selected,
    this.iconUrl,
    this.onTap,
  });

  final String title;
  final int likes;
  final int downloads;
  final DateTime? createdAt;
  final bool selected;
  final String? iconUrl;
  final VoidCallback? onTap;

  @override
  State<_SidebarTile> createState() => _SidebarTileState();
}

class _SidebarTileState extends State<_SidebarTile> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    AppTheme.watch(context);
    final theme = Theme.of(context);
    final selected = widget.selected;
    final iconUrl = widget.iconUrl;
    final bg = selected
        ? AppSurface.selectedFill
        : (_hovered && widget.onTap != null
            ? AppSurface.hoverFill
            : Colors.transparent);
    final radius = BorderRadius.circular(AppCard.insetRadius);
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        MouseRegion(
          cursor: widget.onTap == null
              ? SystemMouseCursors.basic
              : SystemMouseCursors.click,
          onEnter: (_) => setState(() => _hovered = true),
          onExit: (_) => setState(() => _hovered = false),
          child: GestureDetector(
            onTap: widget.onTap,
            child: Stack(
              children: [
                AnimatedContainer(
                  duration: const Duration(milliseconds: 130),
                  curve: Curves.easeOut,
                  decoration: BoxDecoration(color: bg, borderRadius: radius),
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(12, 12, 12, 12),
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        // Icon with white border
                        if (iconUrl != null) ...[
                          Container(
                            width: 40,
                            height: 40,
                            decoration: BoxDecoration(
                              color: Colors.white,
                              borderRadius: BorderRadius.circular(8),
                              border: Border.all(color: Colors.white, width: 2),
                            ),
                            child: ClipRRect(
                              borderRadius: BorderRadius.circular(6),
                              child: CachedNetworkImage(
                                imageUrl: iconUrl,
                                fit: BoxFit.cover,
                                errorWidget: (_, __, ___) => Container(
                                  color: Colors.white,
                                  decoration: BoxDecoration(
                                    color: AppPalette.textSecondary
                                        .withValues(alpha: 0.15),
                                    borderRadius: BorderRadius.circular(6),
                                  ),
                                  child: Icon(
                                    Icons.dns_outlined,
                                    size: 24,
                                    color: AppPalette.textSecondary,
                                  ),
                                ),
                              ),
                            ),
                          ),
                          const SizedBox(width: 12),
                        ],
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              // Title
                              Text(
                                widget.title,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: theme.textTheme.bodySmall?.copyWith(
                                  fontWeight: FontWeight.w700,
                                  color: AppPalette.textPrimary,
                                ),
                              ),
                              const SizedBox(height: 4),
                              // Likes, Downloads & Created at - same row
                              Row(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  if (widget.likes > 0) ...[
                                    Icon(Icons.favorite_border,
                                        size: 14, color: AppPalette.textSecondary),
                                    const SizedBox(width: 4),
                                    Text(
                                      _formatCount(widget.likes),
                                      style: theme.textTheme.labelSmall?.copyWith(
                                          color: AppPalette.textSecondary),
                                    ),
                                    const SizedBox(width: 12),
                                  ],
                                  if (widget.downloads > 0) ...[
                                    Icon(Icons.download_outlined,
                                        size: 14, color: AppPalette.textSecondary),
                                    const SizedBox(width: 4),
                                    Text(
                                      _formatCount(widget.downloads),
                                      style: theme.textTheme.labelSmall?.copyWith(
                                          color: AppPalette.textSecondary),
                                    ),
                                  ],
                                  if (widget.createdAt case final created?) ...[
                                    const Spacer(),
                                    Text(
                                      _formatDate(created),
                                      style: theme.textTheme.labelSmall?.copyWith(
                                          color: AppPalette.textSecondary),
                                    ),
                                  ],
                                ],
                              ),
                            ],
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
                // The accent rail, hugging the selected row's left edge — the
                // same mark the app sidebar uses, sliding in from the left so
                // moving the selection glides rather than blinks.
                Positioned(
                  left: 0,
                  top: 0,
                  bottom: 0,
                  child: Center(
                    child: AnimatedSlide(
                      offset: Offset(selected ? 0 : -0.6, 0),
                      duration: const Duration(milliseconds: 160),
                      curve: Curves.easeOut,
                      child: AnimatedOpacity(
                        opacity: selected ? 1 : 0,
                        duration: const Duration(milliseconds: 140),
                        curve: Curves.easeOut,
                        child: Container(
                          width: 3,
                          height: 22,
                          decoration: BoxDecoration(
                            color: AppPalette.accentOnSurface,
                            borderRadius: const BorderRadius.horizontal(
                              right: Radius.circular(3),
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
        Divider(height: 1, color: AppPalette.divider),
      ],
    );
  }

  static String _formatCount(int count) {
    if (count >= 1000000) return '${(count / 1000000).toStringAsFixed(1)}M';
    if (count >= 1000) return '${(count / 1000).toStringAsFixed(1)}K';
    return '$count';
  }

  static String _formatDate(DateTime d) =>
      '${d.year}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';
}

class _EmptyDetail extends StatelessWidget {
  const _EmptyDetail();

  @override
  Widget build(BuildContext context) {
    AppTheme.watch(context);
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.touch_app_outlined, size: 36, color: AppPalette.textSecondary),
            const SizedBox(height: 12),
            Text(
              'Pick a model on the left to see its versions.',
              style: TextStyle(color: AppPalette.textSecondary),
            ),
          ],
        ),
      ),
    );
  }
}

class _SidebarMessage extends StatelessWidget {
  const _SidebarMessage({required this.icon, required this.text});
  final IconData icon;
  final String text;

  @override
  Widget build(BuildContext context) {
    AppTheme.watch(context);
    return Padding(
      padding: const EdgeInsets.all(20),
      child: Row(
        children: [
          Icon(icon, size: 18, color: AppPalette.textSecondary),
          const SizedBox(width: 10),
          Expanded(
            child: Text(text, style: TextStyle(color: AppPalette.textSecondary)),
          ),
        ],
      ),
    );
  }
}

/// `Qwen/Qwen2.5-3B-Instruct-GGUF` → `Qwen2.5 3B Instruct GGUF`.
/// Replaces `-`/`_` with spaces, keeps numbers and GGUF intact.
String _displayName(String repoId) {
  if (repoId.isEmpty) return 'Unknown';
  final tail = repoId.contains('/') ? repoId.split('/').last : repoId;
  return tail
      .split(RegExp(r'[-_]'))
      .where((w) => w.isNotEmpty)
      .map((w) => w[0].toUpperCase() + w.substring(1))
      .join(' ');
}

/// The column's filter pills — sort, and install state. Matches the chat
/// composer's model pill in construction: a borderless capsule that opens a
/// `MenuAnchor` panel with styled rows.
///
/// Deliberately *not* a form field. Rendered through `labeledFieldDecoration`
/// it inherited a text field's height and stretched to the column's width,
/// which put a control taller and wider than the search box directly above
/// it — the picker read as the primary input and the search as an afterthought.
/// So it shrink-wraps its label and sits at [AppControl.heightSmall], a step
/// under the search field's [AppControl.heightField].
///
/// Generic over its value so the two pills are the same control rather than two
/// near-copies that drift apart the first time one of them is restyled.
class _PillDropdown<T> extends StatefulWidget {
  const _PillDropdown({
    super.key,
    required this.value,
    required this.options,
    required this.labelOf,
    required this.icon,
    required this.semanticLabel,
    required this.onChanged,
  });

  final T value;
  final List<T> options;
  final String Function(T) labelOf;
  final IconData icon;

  /// The control's accessible name — the pill shows only its current value,
  /// which says nothing about what it sets.
  final String semanticLabel;
  final ValueChanged<T> onChanged;

  @override
  State<_PillDropdown<T>> createState() => _PillDropdownState<T>();
}

class _PillDropdownState<T> extends State<_PillDropdown<T>> {
  final _menu = MenuController();
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    AppTheme.watch(context);
    final radius = BorderRadius.circular(AppControl.radius);
    return MenuAnchor(
      controller: _menu,
      style: appMenuStyle(),
      alignmentOffset: const Offset(0, 6),
      builder: (context, controller, _) => Semantics(
        label: widget.semanticLabel,
        button: true,
        child: MouseRegion(
          cursor: SystemMouseCursors.click,
          onEnter: (_) => setState(() => _hovered = true),
          onExit: (_) => setState(() => _hovered = false),
          child: GestureDetector(
            onTap: controller.isOpen ? controller.close : controller.open,
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 130),
              curve: Curves.easeOut,
              height: AppControl.heightSmall,
              padding: const EdgeInsets.symmetric(horizontal: 8),
              decoration: BoxDecoration(
                color: _hovered || controller.isOpen
                    ? AppSurface.recessHover
                    : AppCard.inset,
                borderRadius: radius,
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(widget.icon, size: 14, color: AppPalette.textSecondary),
                  const SizedBox(width: 6),
                  Text(
                    widget.labelOf(widget.value),
                    style: TextStyle(fontSize: 12, color: AppPalette.textSecondary),
                  ),
                  const SizedBox(width: 2),
                  Icon(
                    Icons.arrow_drop_down,
                    size: 18,
                    color: AppPalette.textSecondary,
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
      menuChildren: [
        for (final option in widget.options)
          _PillOptionRow(
            label: widget.labelOf(option),
            selected: option == widget.value,
            onTap: () {
              _menu.close();
              widget.onChanged(option);
            },
          ),
      ],
    );
  }
}

const _sortRowGutter = 6.0;
const _sortRowInnerPad = 9.0;
const _sortRowTickSlot = 16.0;
const _sortRowTickGap = 9.0;

class _PillOptionRow extends StatelessWidget {
  const _PillOptionRow({
    required this.label,
    required this.selected,
    required this.onTap,
  });

  final String label;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    AppTheme.watch(context);
    final radius = BorderRadius.circular(AppControl.radius);
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: _sortRowGutter, vertical: 1),
      child: Material(
        color: Colors.transparent,
        borderRadius: radius,
        child: InkWell(
          onTap: onTap,
          borderRadius: radius,
          hoverColor: AppSurface.hoverFill,
          splashFactory: NoSplash.splashFactory,
          child: Ink(
            decoration: BoxDecoration(
              color: selected ? AppSurface.accentWash : Colors.transparent,
              borderRadius: radius,
            ),
            padding: const EdgeInsets.symmetric(horizontal: _sortRowInnerPad, vertical: 8),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                SizedBox(
                  width: _sortRowTickSlot,
                  child: selected
                      ? Icon(
                          Icons.check_rounded,
                          size: AppControl.iconSize,
                          color: AppPalette.accentMuted,
                        )
                      : null,
                ),
                const SizedBox(width: _sortRowTickGap),
                Expanded(
                  child: Text(
                    label,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: AppControl.fontSize,
                      height: 1.2,
                      fontWeight: selected ? FontWeight.w600 : FontWeight.w400,
                      color: AppPalette.textPrimary,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
