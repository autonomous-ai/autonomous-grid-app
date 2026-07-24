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
import '../../../shared/widgets/pill_choice.dart';
import '../../../shared/widgets/section_scaffold.dart';
import '../../../shared/widgets/toast.dart';
import '../../onboarding/preflight_providers.dart';
import '../../onboarding/preflight_report.dart';

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
          _FilterBar(
            logs: logs,
            selected: _filter,
            onSelect: (f) => setState(() => _filter = f),
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
        itemBuilder: (context, i) => _LogTile(log: visible[i]),
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
        _ToolbarButton(
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

/// Status/kind lenses with live counts, so "is anything red?" is answered
/// before the list is even read. Failed hides itself when the count is zero —
/// an always-there "Failed 0" pill trains the eye to ignore it.
class _FilterBar extends StatelessWidget {
  const _FilterBar({
    required this.logs,
    required this.selected,
    required this.onSelect,
  });

  final List<GridCommandLog> logs;
  final _LogFilter selected;
  final ValueChanged<_LogFilter> onSelect;

  @override
  Widget build(BuildContext context) {
    final visible = [
      for (final f in _LogFilter.values)
        if (f != _LogFilter.failed ||
            selected == _LogFilter.failed ||
            logs.any((l) => l.status == CliCallStatus.failed))
          f,
    ];
    return Row(
      children: [
        for (final f in visible)
          Padding(
            padding: const EdgeInsets.only(right: 8),
            child: PillChoice(
              selected: f == selected,
              onTap: () => onSelect(f),
              label: _FilterLabel(
                label: f.label,
                count: logs.where(f.matches).length,
                danger: f == _LogFilter.failed,
                selected: f == selected,
              ),
            ),
          ),
      ],
    );
  }
}

/// A pill's text plus a dimmer trailing count — the count reads as metadata, not
/// as part of the label.
class _FilterLabel extends StatelessWidget {
  const _FilterLabel({
    required this.label,
    required this.count,
    required this.danger,
    required this.selected,
  });

  final String label;
  final int count;
  final bool danger;
  final bool selected;

  @override
  Widget build(BuildContext context) {
    AppTheme.watch(context); // reads AppPalette tokens — follow theme flips.
    // On a selected (accent) pill the count sits on white; otherwise it's a
    // faint trailing figure, red when it's the failed lens carrying a hit.
    final countColor = selected
        ? Colors.white70
        : danger && count > 0
        ? Theme.of(context).colorScheme.error
        : AppPalette.textFaint;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(label),
        const SizedBox(width: 6),
        Text(
          '$count',
          style: TextStyle(
            fontSize: 12.5,
            fontWeight: AppFont.medium,
            color: countColor,
            fontFeatures: const [FontFeature.tabularFigures()],
          ),
        ),
      ],
    );
  }
}

/// A lifted pill action for the Debug toolbar — matches the button shape used
/// across the reference tabs (fill + shadow, no border, radius 11).
class _ToolbarButton extends StatefulWidget {
  const _ToolbarButton({
    required this.icon,
    required this.label,
    required this.onPressed,
  });

  final IconData icon;
  final String label;
  final VoidCallback? onPressed;

  @override
  State<_ToolbarButton> createState() => _ToolbarButtonState();
}

class _ToolbarButtonState extends State<_ToolbarButton> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    AppTheme.watch(context); // reads AppGlass/AppPalette tokens.
    final enabled = widget.onPressed != null;
    // Glyph climbs to full color on hover; drops back and dims when disabled.
    final fg = !enabled
        ? AppPalette.textFaint
        : _hovered
        ? AppPalette.textPrimary
        : AppPalette.textSecondary;
    return Material(
      color: AppGlass.surfaceFill,
      borderRadius: BorderRadius.circular(11),
      child: InkWell(
        borderRadius: BorderRadius.circular(11),
        onTap: widget.onPressed,
        onHover: (v) => setState(() => _hovered = v),
        child: Container(
          height: 34,
          padding: const EdgeInsets.symmetric(horizontal: 14),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(11),
            boxShadow: AppGlass.cardShadow,
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(widget.icon, size: 16, color: fg),
              const SizedBox(width: 8),
              Text(
                widget.label,
                style: TextStyle(
                  color: fg,
                  fontSize: 13,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ],
          ),
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
    return _ToolbarButton(
      icon: Icons.folder_open_rounded,
      label: 'Open logs',
      onPressed: () => _open(context, ref),
    );
  }
}

class _LogTile extends StatelessWidget {
  const _LogTile({required this.log});
  final GridCommandLog log;

  @override
  Widget build(BuildContext context) {
    AppTheme.watch(context); // list item — must self-watch to follow flips.
    final theme = Theme.of(context);
    return GlassCard(
      style: GlassCardStyle.inset,
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _StatusIcon(status: log.status),
              const SizedBox(width: 10),
              Expanded(
                child: SelectableText(
                  log.command,
                  style: theme.textTheme.bodyMedium?.copyWith(
                    fontFamily: AppFont.mono,
                    fontFamilyFallback: AppFont.monoFallback,
                    color: AppPalette.textPrimary,
                  ),
                ),
              ),
              const SizedBox(width: 10),
              _Meta(log: log),
            ],
          ),
          if (log.error != null) ...[
            const SizedBox(height: 6),
            Padding(
              padding: const EdgeInsets.only(left: 26),
              child: SelectableText(
                log.error!,
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.error,
                  fontFamily: AppFont.mono,
                  fontFamilyFallback: AppFont.monoFallback,
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }
}

class _StatusIcon extends StatelessWidget {
  const _StatusIcon({required this.status});
  final CliCallStatus status;

  @override
  Widget build(BuildContext context) {
    AppTheme.watch(context); // reads AppPalette.online — follow theme flips.
    return switch (status) {
      CliCallStatus.running => const AppSpinner(),
      CliCallStatus.success => Icon(
        Icons.check_circle,
        size: 16,
        color: AppPalette.online,
      ),
      CliCallStatus.failed => Icon(
        Icons.error,
        size: 16,
        color: Theme.of(context).colorScheme.error,
      ),
    };
  }
}

class _Meta extends StatelessWidget {
  const _Meta({required this.log});
  final GridCommandLog log;

  @override
  Widget build(BuildContext context) {
    AppTheme.watch(context); // reads AppPalette.textFaint — follow theme flips.
    final style = Theme.of(context).textTheme.bodySmall?.copyWith(
      color: AppPalette.textFaint,
      fontFamily: AppFont.mono,
      fontFamilyFallback: AppFont.monoFallback,
      fontSize: 11.5,
    );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.end,
      children: [
        Text(log.kind.name, style: style),
        const SizedBox(height: 2),
        Text(_detail(log), style: style),
      ],
    );
  }

  String _detail(GridCommandLog log) {
    final time = _formatTime(log.startedAt);
    if (log.status == CliCallStatus.running) return '$time · running…';
    final dur = log.duration == null
        ? ''
        : ' · ${_formatDuration(log.duration!)}';
    final code = switch (log.exitCode) {
      null => '',
      final c when log.kind == CliCallKind.http => ' · HTTP $c',
      final c => ' · exit $c',
    };
    return '$time$dur$code';
  }
}

String _formatTime(DateTime t) {
  String two(int n) => n.toString().padLeft(2, '0');
  return '${two(t.hour)}:${two(t.minute)}:${two(t.second)}';
}

String _formatDuration(Duration d) {
  final ms = d.inMilliseconds;
  if (ms < 1000) return '${ms}ms';
  return '${(ms / 1000).toStringAsFixed(ms < 10000 ? 1 : 0)}s';
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
