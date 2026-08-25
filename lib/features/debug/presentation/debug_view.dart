import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/grid_paths.dart';
import '../../../infrastructure/cli/command_log.dart';
import '../../../infrastructure/cli/host_shell_service.dart';
import '../../../infrastructure/providers.dart';
import '../../../shared/theme/app_theme.dart';
import '../../../shared/widgets/app_spinner.dart';
import '../../../shared/widgets/empty_state.dart';
import '../../../shared/widgets/glass_card.dart';
import '../../../shared/widgets/section_scaffold.dart';
import '../../../shared/widgets/toast.dart';
import '../../onboarding/preflight_providers.dart';
import '../../onboarding/preflight_report.dart';
import 'debug_filter_bar.dart';
import 'debug_toolbar_button.dart';
import 'log_tile.dart';

/// The status/kind lens the list is filtered to. Named so an empty result can
/// say "nothing matches this filter" rather than "nothing has run".
enum _LogFilter { all, failed, http, cli }

extension on _LogFilter {
  String get label => switch (this) {
    _LogFilter.all => 'All',
    _LogFilter.failed => 'Failed',
    _LogFilter.http => 'HTTP',
    _LogFilter.cli => 'CLI',
  };

  /// Whether [log] belongs in this lens.
  bool matches(GridCommandLog log) => switch (this) {
    _LogFilter.all => true,
    _LogFilter.failed => log.status == CliCallStatus.failed,
    _LogFilter.http => log.kind == CliCallKind.http,
    _LogFilter.cli => log.kind != CliCallKind.http,
  };
}

/// Debug tab — a live log of every `grid` command and relay request the app
/// runs (newest first). Fed by [LoggingGridCliService] and the direct-HTTP
/// paths; handy for seeing exactly what the UI does and whether it succeeded.
///
/// A search box and status lenses sit above the list because the useful signal
/// (the one failure, the one chat request) is usually buried under repeated
/// `overview` polls — scrolling 200 near-identical rows by hand isn't debugging.
class DebugView extends ConsumerStatefulWidget {
  const DebugView({super.key});

  @override
  ConsumerState<DebugView> createState() => _DebugViewState();
}

class _DebugViewState extends ConsumerState<DebugView> {
  final _search = TextEditingController();
  String _query = '';
  _LogFilter _filter = _LogFilter.all;

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  bool _matchesQuery(GridCommandLog log) {
    final q = _query.trim().toLowerCase();
    if (q.isEmpty) return true;
    return log.command.toLowerCase().contains(q) ||
        (log.error?.toLowerCase().contains(q) ?? false);
  }

  @override
  Widget build(BuildContext context) {
    final logs = ref.watch(commandLogProvider);
    final visible = [
      for (final log in logs)
        if (_filter.matches(log) && _matchesQuery(log)) log,
    ];

    return SectionScaffold(
      title: 'Debug',
      subtitle: 'Every grid command and relay request this app runs',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const _WhichGridCard(),
          const SizedBox(height: 16),
          _Toolbar(total: logs.length),
          const SizedBox(height: 12),
          _SearchField(
            controller: _search,
            onChanged: (value) => setState(() => _query = value),
          ),
          const SizedBox(height: 12),
          DebugFilterBar(
            lenses: [
              for (final f in _LogFilter.values)
                FilterLens(
                  label: f.label,
                  count: logs.where(f.matches).length,
                  selected: f == _filter,
                  onTap: () => setState(() => _filter = f),
                  danger: f == _LogFilter.failed,
                  hideWhenEmpty: f == _LogFilter.failed,
                ),
            ],
          ),
          const SizedBox(height: 12),
          Expanded(child: _list(logs.isEmpty, visible)),
        ],
      ),
    );
  }

  Widget _list(bool nothingRun, List<GridCommandLog> visible) {
    if (visible.isNotEmpty) {
      return ListView.separated(
        itemCount: visible.length,
        separatorBuilder: (_, _) => const SizedBox(height: 8),
        itemBuilder: (context, i) => LogTile(log: visible[i]),
      );
    }
    // Nothing exists yet vs the filter hid everything — two different stories, so
    // the query still shows above and the user has a way back out.
    if (nothingRun) {
      return const EmptyState(
        icon: Icons.terminal_rounded,
        title: 'No commands yet',
        message:
            'Interact with the app and every grid command and relay request '
            'it runs will show up here.',
      );
    }
    return const EmptyState.noMatches(
      message: 'No command matches this filter or search.',
    );
  }
}

/// The command count and the two disk/clear actions. Count reflects everything
/// captured this session, not the filtered view — it's the buffer's fill level.
class _Toolbar extends ConsumerWidget {
  const _Toolbar({required this.total});
  final int total;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    AppTheme.watch(context); // reads AppPalette tokens — follow theme flips.
    final theme = Theme.of(context);
    return Row(
      children: [
        // bodyMedium already carries the secondary color from the text theme.
        Text(
          '$total command${total == 1 ? '' : 's'}',
          style: theme.textTheme.bodyMedium?.copyWith(
            color: AppPalette.textSecondary,
          ),
        ),
        const Spacer(),
        const _OpenLogsButton(),
        const SizedBox(width: 8),
        DebugToolbarButton(
          icon: Icons.delete_outline_rounded,
          label: 'Clear',
          onPressed: total == 0
              ? null
              : () => ref.read(commandLogProvider.notifier).clear(),
        ),
      ],
    );
  }
}

/// The search box — same lifted recipe as the reference tabs (surface fill +
/// shadow, no border). Filters on the command line and any error text.
class _SearchField extends StatelessWidget {
  const _SearchField({required this.controller, required this.onChanged});

  final TextEditingController controller;
  final ValueChanged<String> onChanged;

  @override
  Widget build(BuildContext context) {
    AppTheme.watch(context); // reads AppGlass tokens — follow theme flips.
    return DecoratedBox(
      decoration: BoxDecoration(
        color: AppGlass.surfaceFill,
        borderRadius: BorderRadius.circular(14),
        boxShadow: AppGlass.cardShadow,
      ),
      child: TextField(
        controller: controller,
        onChanged: onChanged,
        style: const TextStyle(fontSize: 13),
        decoration: const InputDecoration(
          filled: false,
          hintText: 'Search commands, URLs, errors',
          prefixIcon: Icon(Icons.search_rounded, size: 18),
          border: InputBorder.none,
          enabledBorder: InputBorder.none,
          focusedBorder: InputBorder.none,
          contentPadding: EdgeInsets.symmetric(horizontal: 12, vertical: 12),
        ),
      ),
    );
  }
}

/// Opens `~/.grid/logs` in the file manager.
///
/// The list above is only this session's commands, held in memory — the files on
/// disk are what survive a crash and what a user can actually attach to a bug
/// report. Without this they'd have to be told a hidden path to type into Finder.
class _OpenLogsButton extends ConsumerWidget {
  const _OpenLogsButton();

  Future<void> _open(BuildContext context, WidgetRef ref) async {
    final directory = GridPaths.logsDir;
    final toast = ToastScope.of(context);
    // Nothing has been logged yet on a fresh install — the folder simply isn't
    // there, and "couldn't open it" would be the wrong story.
    if (!directory.existsSync()) {
      toast?.show(
        const ToastSpec(
          message: 'No logs yet — nothing has run.',
          severity: ToastSeverity.info,
        ),
      );
      return;
    }
    final opened = await ref
        .read(hostShellServiceProvider)
        .openFolder(directory.path);
    if (opened) return;
    toast?.show(
      ToastSpec(
        message: "Couldn't open ${directory.path}",
        severity: ToastSeverity.error,
      ),
    );
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return DebugToolbarButton(
      icon: Icons.folder_open_rounded,
      label: 'Open logs',
      onPressed: () => _open(context, ref),
    );
  }
}

/// Shows which `grid` binary the app resolved (and from where), plus whether it
/// actually runs — the first thing to check when commands fail (e.g. a wrong
/// path or an arch mismatch). Re-check re-resolves and re-runs the preflight.
class _WhichGridCard extends ConsumerWidget {
  const _WhichGridCard();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    AppTheme.watch(context); // reads AppPalette tokens — follow theme flips.
    final theme = Theme.of(context);
    final path = ref.watch(gridPathProvider);
    final preflight = ref.watch(preflightProvider);
    final gridBin = Platform.environment['GRID_BIN'];

    return GlassCard(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(Icons.terminal, size: 16, color: AppPalette.textFaint),
              const SizedBox(width: 8),
              Text('grid binary', style: theme.textTheme.titleSmall),
              const Spacer(),
              _RecheckButton(
                onPressed: () {
                  ref.invalidate(gridPathProvider);
                  ref.invalidate(preflightProvider);
                },
              ),
            ],
          ),
          const SizedBox(height: 4),
          _PathRow(
            label: 'path',
            value: path ?? 'Not found on this system',
            ok: path != null,
          ),
          if (gridBin != null && gridBin.isNotEmpty)
            _PathRow(label: 'GRID_BIN', value: gridBin, ok: true),
          const SizedBox(height: 6),
          _version(theme, preflight),
        ],
      ),
    );
  }

  Widget _version(ThemeData theme, AsyncValue<PreflightReport> preflight) {
    return preflight.when(
      loading: () => Row(
        children: [
          const AppSpinner(size: SpinnerSize.small),
          const SizedBox(width: 8),
          Text('checking…', style: theme.textTheme.bodySmall),
        ],
      ),
      error: (e, _) => SelectableText(
        'check failed: $e',
        style: theme.textTheme.bodySmall?.copyWith(
          color: theme.colorScheme.error,
        ),
      ),
      data: (report) {
        // Health is the exit-0 signal (`gridAvailable`), not the presence of a
        // version string — a working `grid` can exit 0 without printing one.
        if (report.gridAvailable) {
          return Row(
            children: [
              Icon(Icons.check_circle, size: 14, color: AppPalette.online),
              const SizedBox(width: 8),
              Expanded(
                child: SelectableText(
                  report.gridVersion ?? 'installed (version unknown)',
                  style: theme.textTheme.bodySmall?.copyWith(
                    fontFamily: AppFont.mono,
                    fontFamilyFallback: AppFont.monoFallback,
                  ),
                ),
              ),
            ],
          );
        }
        return Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(Icons.error, size: 14, color: theme.colorScheme.error),
            const SizedBox(width: 8),
            Expanded(
              child: SelectableText(
                report.gridError ?? 'grid not found',
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.error,
                ),
              ),
            ),
          ],
        );
      },
    );
  }
}

/// Re-resolves the binary and re-runs the preflight. A hand-rolled hover so the
/// glyph climbs to full color under the cursor (a bare IconButton stays dim).
class _RecheckButton extends StatefulWidget {
  const _RecheckButton({required this.onPressed});
  final VoidCallback onPressed;

  @override
  State<_RecheckButton> createState() => _RecheckButtonState();
}

class _RecheckButtonState extends State<_RecheckButton> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    AppTheme.watch(context); // reads AppSurface/AppPalette tokens.
    return Tooltip(
      message: 'Re-check',
      child: MouseRegion(
        onEnter: (_) => setState(() => _hovered = true),
        onExit: (_) => setState(() => _hovered = false),
        child: GestureDetector(
          onTap: widget.onPressed,
          child: Container(
            width: 28,
            height: 28,
            decoration: BoxDecoration(
              color: _hovered ? AppSurface.hoverFill : Colors.transparent,
              borderRadius: BorderRadius.circular(7),
            ),
            child: Icon(
              Icons.refresh_rounded,
              size: 16,
              color: _hovered ? AppPalette.textPrimary : AppPalette.textFaint,
            ),
          ),
        ),
      ),
    );
  }
}

class _PathRow extends StatelessWidget {
  const _PathRow({required this.label, required this.value, required this.ok});
  final String label;
  final String value;
  final bool ok;

  @override
  Widget build(BuildContext context) {
    AppTheme.watch(context); // reads AppPalette tokens — follow theme flips.
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 70,
            child: Text(
              label,
              style: theme.textTheme.bodySmall?.copyWith(
                color: AppPalette.textFaint,
              ),
            ),
          ),
          Expanded(
            child: SelectableText(
              value,
              style: theme.textTheme.bodySmall?.copyWith(
                fontFamily: AppFont.mono,
                fontFamilyFallback: AppFont.monoFallback,
                color: ok ? AppPalette.textPrimary : theme.colorScheme.error,
              ),
            ),
          ),
        ],
      ),
    );
  }
}
