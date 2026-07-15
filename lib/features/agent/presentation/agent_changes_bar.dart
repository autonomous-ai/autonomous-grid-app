import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../shared/theme/app_theme.dart';
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
    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.fromLTRB(14, 8, 8, 8),
      decoration: BoxDecoration(
        color: AppPalette.windowBg,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: AppPalette.divider),
        boxShadow: AppSurface.composerShadow,
      ),
      child: Row(
        children: [
          Icon(
            Icons.history_rounded,
            size: 17,
            color: AppPalette.textSecondary,
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              'The assistant changed ${changes.length} '
              '${changes.length == 1 ? 'file' : 'files'}',
              style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600),
            ),
          ),
          TextButton(
            onPressed: () => showAgentChangesDialog(context),
            child: const Text('Review'),
          ),
          const SizedBox(width: 4),
          const _UndoAllButton(),
        ],
      ),
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
    final messenger = ScaffoldMessenger.of(context);
    setState(() => _busy = true);
    final error = await ref.read(agentChangesProvider.notifier).revertAll();
    if (mounted) setState(() => _busy = false);
    messenger.showSnackBar(
      SnackBar(content: Text(error ?? 'Undid the assistant\'s changes.')),
    );
  }

  @override
  Widget build(BuildContext context) {
    return FilledButton.tonalIcon(
      onPressed: _busy ? null : _undoAll,
      icon: _busy
          ? const SizedBox(
              width: 14,
              height: 14,
              child: CircularProgressIndicator(strokeWidth: 2),
            )
          : const Icon(Icons.undo_rounded, size: 16),
      label: const Text('Undo all'),
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
    final messenger = ScaffoldMessenger.of(context);
    setState(() => _busy = true);
    final error = await ref
        .read(agentChangesProvider.notifier)
        .revert(widget.change);
    if (!mounted) return;
    setState(() => _busy = false);
    if (error != null) {
      messenger.showSnackBar(SnackBar(content: Text(error)));
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
