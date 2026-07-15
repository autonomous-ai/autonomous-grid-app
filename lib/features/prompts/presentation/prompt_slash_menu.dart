import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../shared/theme/app_theme.dart';
import '../logic/prompt_library_controller.dart';
import '../logic/prompt_slash.dart';
import '../logic/saved_prompt.dart';
import 'prompt_dialog.dart';

/// The `/` menu that floats above the composer while the user types a slash
/// command: the saved prompts whose name matches, plus a way to make a new one.
///
/// Picking a prompt hands its body back through [onPick] (the composer replaces
/// what was typed with it). Kept presentational — the match is the pure
/// [matchingPrompts]; this only renders it and routes taps.
class PromptSlashMenu extends ConsumerWidget {
  const PromptSlashMenu({super.key, required this.query, required this.onPick});

  /// The text after the leading `/` (see [slashQuery]); empty shows everything.
  final String query;

  /// Called with the chosen prompt's body, ready to drop into the composer.
  final ValueChanged<String> onPick;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final all = ref.watch(promptLibraryProvider);
    final matches = matchingPrompts(all, query);
    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      decoration: BoxDecoration(
        color: AppPalette.windowBg,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: AppPalette.divider),
        boxShadow: AppSurface.composerShadow,
      ),
      clipBehavior: Clip.antiAlias,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (matches.isEmpty)
            _EmptyRow(hasAny: all.isNotEmpty)
          else
            ConstrainedBox(
              constraints: const BoxConstraints(maxHeight: 280),
              child: ListView.builder(
                shrinkWrap: true,
                padding: const EdgeInsets.symmetric(vertical: 6),
                itemCount: matches.length,
                itemBuilder: (context, i) => _PromptRow(
                  prompt: matches[i],
                  onPick: () => onPick(matches[i].body),
                  onEdit: () => showEditPromptDialog(context, matches[i]),
                ),
              ),
            ),
          const Divider(height: 1),
          _NewPromptRow(onTap: () => showNewPromptDialog(context)),
        ],
      ),
    );
  }
}

/// One prompt in the menu: name over a one-line preview of its text; the whole
/// row picks it, and a pencil (on hover) opens it for editing.
class _PromptRow extends StatefulWidget {
  const _PromptRow({
    required this.prompt,
    required this.onPick,
    required this.onEdit,
  });

  final SavedPrompt prompt;
  final VoidCallback onPick;
  final VoidCallback onEdit;

  @override
  State<_PromptRow> createState() => _PromptRowState();
}

class _PromptRowState extends State<_PromptRow> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    return MouseRegion(
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() => _hovered = false),
      child: Material(
        color: _hovered ? AppPalette.cardBgHover : Colors.transparent,
        child: InkWell(
          onTap: widget.onPick,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 9, 8, 9),
            child: Row(
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        widget.prompt.name,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          fontSize: 13.5,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        widget.prompt.body.replaceAll('\n', ' '),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: 12,
                          color: AppPalette.textFaint,
                        ),
                      ),
                    ],
                  ),
                ),
                if (_hovered)
                  IconButton(
                    tooltip: 'Edit prompt',
                    iconSize: 16,
                    visualDensity: VisualDensity.compact,
                    color: AppPalette.textSecondary,
                    icon: const Icon(Icons.edit_outlined),
                    onPressed: widget.onEdit,
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// The footer row that opens the new-prompt dialog.
class _NewPromptRow extends StatelessWidget {
  const _NewPromptRow({required this.onTap});

  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 11),
          child: Row(
            children: [
              Icon(Icons.add_rounded, size: 17, color: AppPalette.accent),
              const SizedBox(width: 8),
              Text(
                'New prompt',
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

/// Shown when the query matches nothing: a gentle nudge that changes with
/// whether the library is empty or just this search came up short.
class _EmptyRow extends StatelessWidget {
  const _EmptyRow({required this.hasAny});

  final bool hasAny;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 14, 16, 12),
      child: Text(
        hasAny
            ? 'No prompt matches that.'
            : 'No saved prompts yet — create one below to reuse it with /.',
        style: TextStyle(fontSize: 12.5, color: AppPalette.textSecondary),
      ),
    );
  }
}
