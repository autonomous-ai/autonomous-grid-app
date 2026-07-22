import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../shared/theme/app_theme.dart';
import '../../../shared/widgets/app_spinner.dart';
import '../../../shared/widgets/composer_notice_bar.dart';
import '../../../shared/widgets/toast.dart';
import '../logic/agent_changes.dart';
import '../logic/edit_diff.dart';
import 'diff_view.dart';

/// A slim bar above the composer summarising what the agent changed this session,
/// with one tap to review the changes and one to undo them all.
///
/// Shown only when there's something to undo — the honest answer to Full access's
/// old "Nothing to undo". Hidden otherwise so it never nags an empty chat.
class AgentChangesBar extends ConsumerWidget {
  const AgentChangesBar({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final changes = ref.watch(agentChangesProvider);
    if (changes.isEmpty) return const SizedBox.shrink();
    return ComposerNoticeBar(
      icon: Icons.history_rounded,
      label:
          'The assistant changed ${changes.length} '
          '${changes.length == 1 ? 'file' : 'files'}',
      actions: [
        TextButton(
          onPressed: () => showAgentChangesDialog(context),
          child: const Text('Review'),
        ),
        const _UndoAllButton(),
      ],
    );
  }
}

class _UndoAllButton extends ConsumerStatefulWidget {
  const _UndoAllButton();

  @override
  ConsumerState<_UndoAllButton> createState() => _UndoAllButtonState();
}

class _UndoAllButtonState extends ConsumerState<_UndoAllButton> {
  bool _busy = false;

  Future<void> _undoAll() async {
    final toast = ToastScope.of(context);
    setState(() => _busy = true);
    final error = await ref.read(agentChangesProvider.notifier).revertAll();
    if (mounted) setState(() => _busy = false);
    toast?.show(
      error != null
          ? ToastSpec(message: error, severity: ToastSeverity.error)
          : const ToastSpec(
              message: 'Undid the assistant\'s changes.',
              severity: ToastSeverity.success,
            ),
    );
  }

  @override
  Widget build(BuildContext context) {
    AppTheme.watch(context); // rebuild on theme flip — reads accent token
    // A soft accent-tinted pill, not the solid blue tonal button — it sat too
    // loud on this quiet bar. Still reads as the primary action next to Review.
    return Material(
      color: AppPalette.accent.withValues(alpha: 0.10),
      borderRadius: BorderRadius.circular(11),
      child: InkWell(
        borderRadius: BorderRadius.circular(11),
        onTap: _busy ? null : _undoAll,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 9),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (_busy)
                const AppSpinner(color: AppPalette.accent)
              else
                Icon(Icons.undo_rounded, size: 16, color: AppPalette.accent),
              const SizedBox(width: 8),
              Text(
                'Undo all',
                style: TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w600,
                  color: AppPalette.accent,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// The full list of what the agent changed, each with its diff and its own undo,
/// so the user can put back one file without losing the rest.
Future<void> showAgentChangesDialog(BuildContext context) =>
    showDialog<void>(context: context, builder: (_) => const _ChangesDialog());

class _ChangesDialog extends ConsumerWidget {
  const _ChangesDialog();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // Dialog content is a detached overlay — no top-down rebuild reaches it, so
    // it must watch the theme itself to repaint its palette tokens on a flip.
    AppTheme.watch(context);
    final theme = Theme.of(context);
    final changes = ref.watch(agentChangesProvider);
    return AlertDialog(
      backgroundColor: AppPalette.windowBg,
      surfaceTintColor: Colors.transparent,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
      titlePadding: const EdgeInsets.fromLTRB(28, 26, 28, 0),
      contentPadding: const EdgeInsets.fromLTRB(28, 14, 28, 4),
      actionsPadding: const EdgeInsets.fromLTRB(28, 10, 22, 22),
      title: Text(
        'Changes this session',
        style: theme.textTheme.headlineSmall?.copyWith(
          fontWeight: FontWeight.w600,
        ),
      ),
      content: SizedBox(
        width: 620,
        child: changes.isEmpty
            ? Padding(
                padding: const EdgeInsets.symmetric(vertical: 24),
                child: Text(
                  'Nothing left to undo.',
                  style: TextStyle(color: AppPalette.textSecondary),
                ),
              )
            : SingleChildScrollView(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    for (final change in changes) _ChangeRow(change: change),
                  ],
                ),
              ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Close'),
        ),
      ],
    );
  }
}

class _ChangeRow extends ConsumerStatefulWidget {
  const _ChangeRow({required this.change});

  final AgentChange change;

  @override
  ConsumerState<_ChangeRow> createState() => _ChangeRowState();
}

class _ChangeRowState extends ConsumerState<_ChangeRow> {
  bool _busy = false;

  Future<void> _undo() async {
    final toast = ToastScope.of(context);
    setState(() => _busy = true);
    final error = await ref
        .read(agentChangesProvider.notifier)
        .revert(widget.change);
    if (!mounted) return;
    setState(() => _busy = false);
    if (error != null) {
      toast?.show(ToastSpec(message: error, severity: ToastSeverity.error));
    }
  }

  @override
  Widget build(BuildContext context) {
    final change = widget.change;
    return Padding(
      padding: const EdgeInsets.only(bottom: 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  change.name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    fontSize: 13.5,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
              if (change.isNew) const _NewTag(),
              const SizedBox(width: 8),
              TextButton(
                onPressed: _busy ? null : _undo,
                child: Text(_busy ? 'Undoing…' : 'Undo'),
              ),
            ],
          ),
          const SizedBox(height: 6),
          DiffView(lines: buildEditDiff(change.before, change.after)),
        ],
      ),
    );
  }
}

class _NewTag extends StatelessWidget {
  const _NewTag();

  @override
  Widget build(BuildContext context) {
    // Lives inside the detached changes dialog — watch so it repaints on a flip.
    AppTheme.watch(context);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        // A light accent tint, not the solid avatar fill — the old fill was
        // near-indigo under near-indigo text, so the label all but vanished.
        color: AppPalette.accent.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(6),
      ),
      child: Text(
        'New file',
        style: TextStyle(
          fontSize: 11,
          fontWeight: FontWeight.w700,
          color: AppPalette.accent,
        ),
      ),
    );
  }
}
