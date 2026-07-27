import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../infrastructure/api/models/model_catalog.dart';
import '../../../shared/theme/app_theme.dart';
import '../../../shared/widgets/labeled_field.dart';
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

  /// Value sent to `?sort=` on `GET /v1/grid/catalog`. Empty for the local-only
  /// "Recommended" mode (the suggest endpoint has its own ranking).
  String get apiValue => switch (this) {
        _SortMode.recommended => '',
        _SortMode.trending => 'trending',
        _SortMode.mostLiked => 'likes',
        _SortMode.newest => 'newest',
      };
}

class ModelManagerSplitView extends ConsumerStatefulWidget {
  const ModelManagerSplitView({super.key});

  @override
  ConsumerState<ModelManagerSplitView> createState() => _ModelManagerSplitViewState();
}

class _ModelManagerSplitViewState extends ConsumerState<ModelManagerSplitView> {
  String? _selectedRepoId;
  String _query = '';
  _SortMode _sort = _SortMode.recommended;

  @override
  void initState() {
    super.initState();
    // Auto-select the first model once the list/suggestion resolves.
    _autoSelectFirst();
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
            onQuery: (q) => setState(() => _query = q),
            onSort: (s) => setState(() => _sort = s),
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
    required this.onQuery,
    required this.onSort,
    required this.onSelect,
  });

  final AsyncValue<SuggestOutcome> suggestion;
  final String? selectedRepoId;
  final String query;
  final _SortMode sort;
  final ValueChanged<String> onQuery;
  final ValueChanged<_SortMode> onSort;
  final ValueChanged<String> onSelect;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    AppTheme.watch(context);
    final listAsync = sort.apiValue.isEmpty
        ? const AsyncValue<List<CatalogListEntry>?>.data(null)
        : ref.watch(catalogListProvider(sort.apiValue));

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
          child: _SortDropdown(
            value: sort,
            onChanged: onSort,
          ),
        ),
        Expanded(
          child: switch (sort) {
            _SortMode.recommended => _suggestionBody(ref, listAsync),
            _SortMode.trending || _SortMode.mostLiked || _SortMode.newest =>
              _listBody(ref, listAsync),
          },
        ),
      ],
    );
  }

  Widget _suggestionBody(WidgetRef ref, AsyncValue<List<CatalogListEntry>?> listAsync) {
    return switch (suggestion) {
      AsyncData(:final value) => switch (value) {
          SuggestReady(:final ranked) => _RankedList(
              ranked: _filterPicks(ranked, query),
              selectedRepoId: selectedRepoId,
              onSelect: onSelect,
            ),
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
      AsyncData(:final value) when value != null && value.isNotEmpty => _EntryList(
          entries: value,
          query: query,
          selectedRepoId: selectedRepoId,
          onSelect: onSelect,
        ),
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

  List<CatalogModelPick> _filterPicks(List<CatalogModelPick> picks, String q) {
    final needle = q.trim().toLowerCase();
    if (needle.isEmpty) return picks;
    return picks
        .where((m) => (m.repoId ?? '').toLowerCase().contains(needle))
        .toList();
  }
}

class _EntryList extends StatelessWidget {
  const _EntryList({
    required this.entries,
    required this.query,
    required this.selectedRepoId,
    required this.onSelect,
  });

  final List<CatalogListEntry> entries;
  final String query;
  final String? selectedRepoId;
  final ValueChanged<String> onSelect;

  @override
  Widget build(BuildContext context) {
    AppTheme.watch(context);
    final needle = query.trim().toLowerCase();
    final filtered = needle.isEmpty
        ? entries
        : entries.where((e) => e.repoId.toLowerCase().contains(needle)).toList();
    return ListView.separated(
      padding: const EdgeInsets.symmetric(horizontal: 8),
      itemCount: filtered.length,
      separatorBuilder: (_, __) => const SizedBox(height: 2),
      itemBuilder: (_, i) {
        final e = filtered[i];
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

class _SidebarTile extends StatelessWidget {
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
  Widget build(BuildContext context) {
    AppTheme.watch(context);
    final theme = Theme.of(context);
    final bg = selected
        ? AppPalette.accent.withValues(alpha: 0.15)
        : Colors.transparent;
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        GestureDetector(
          onTap: onTap,
          child: DecoratedBox(
            decoration: BoxDecoration(
              color: bg,
              borderRadius: BorderRadius.circular(AppCard.insetRadius),
            ),
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
                          imageUrl: iconUrl!,
                          fit: BoxFit.cover,
                          errorWidget: (_, __, ___) => Container(
                            color: Colors.white,
                            decoration: BoxDecoration(
                              color: AppPalette.textSecondary.withValues(alpha: 0.15),
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
                          title,
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
                            if (likes > 0) ...[
                              Icon(Icons.favorite_border, size: 14, color: AppPalette.textSecondary),
                              const SizedBox(width: 4),
                              Text(
                                _formatCount(likes),
                                style: theme.textTheme.labelSmall?.copyWith(color: AppPalette.textSecondary),
                              ),
                              const SizedBox(width: 12),
                            ],
                            if (downloads > 0) ...[
                              Icon(Icons.download_outlined, size: 14, color: AppPalette.textSecondary),
                              const SizedBox(width: 4),
                              Text(
                                _formatCount(downloads),
                                style: theme.textTheme.labelSmall?.copyWith(color: AppPalette.textSecondary),
                              ),
                            ],
                            if (createdAt != null) ...[
                              const Spacer(),
                              Text(
                                '${createdAt!.year}-${createdAt!.month.toString().padLeft(2, '0')}-${createdAt!.day.toString().padLeft(2, '0')}',
                                style: theme.textTheme.labelSmall?.copyWith(color: AppPalette.textSecondary),
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

/// Sort-mode picker: matches the chat composer's model pill in construction —
/// a borderless capsule field that opens a `MenuAnchor` panel with styled rows.
class _SortDropdown extends StatefulWidget {
  const _SortDropdown({required this.value, required this.onChanged});

  final _SortMode value;
  final ValueChanged<_SortMode> onChanged;

  @override
  State<_SortDropdown> createState() => _SortDropdownState();
}

class _SortDropdownState extends State<_SortDropdown> {
  final _menu = MenuController();

  @override
  Widget build(BuildContext context) {
    AppTheme.watch(context);
    return MenuAnchor(
      controller: _menu,
      style: appMenuStyle(),
      alignmentOffset: const Offset(0, 6),
      builder: (context, controller, _) => Semantics(
        label: 'Sort models',
        child: InkWell(
          onTap: controller.isOpen ? controller.close : controller.open,
          borderRadius: BorderRadius.circular(AppCard.insetRadius),
          child: InputDecorator(
            isEmpty: false,
            decoration: labeledFieldDecoration('', fill: AppCard.inset),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(Icons.sort, size: 14, color: AppPalette.textSecondary),
                const SizedBox(width: 6),
                Text(
                  widget.value.label,
                  style: TextStyle(fontSize: 12, color: AppPalette.textSecondary),
                ),
                const SizedBox(width: 4),
                Icon(
                  Icons.arrow_drop_down,
                  size: 20,
                  color: AppPalette.textSecondary,
                ),
              ],
            ),
          ),
        ),
      ),
      menuChildren: [
        for (final m in _SortMode.values)
          _SortOptionRow(
            mode: m,
            selected: m == widget.value,
            onTap: () {
              _menu.close();
              widget.onChanged(m);
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

class _SortOptionRow extends StatelessWidget {
  const _SortOptionRow({
    required this.mode,
    required this.selected,
    required this.onTap,
  });

  final _SortMode mode;
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
                    mode.label,
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
