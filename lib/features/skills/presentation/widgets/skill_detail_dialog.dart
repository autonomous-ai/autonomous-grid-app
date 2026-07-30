import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_markdown_plus/flutter_markdown_plus.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../shared/theme/app_theme.dart';
import '../../../../shared/widgets/app_icon_button.dart';
import '../../../../shared/widgets/app_spinner.dart';
import '../../../../shared/widgets/code_text_scope.dart';
import '../../../agents/logic/agent_skill.dart';
import '../../logic/skill_files.dart';

/// Opens a skill: what it says it does, and every file in its folder.
///
/// A skill is a folder, not a row — the card is only its cover page, and the
/// scripts underneath are what it actually runs. Read-only wherever it came
/// from: this is for understanding a skill (and for checking what a public one
/// will do before it does it), not for editing one.
Future<void> showSkillDetail(BuildContext context, AgentSkill skill) =>
    showDialog<void>(
      context: context,
      builder: (_) => _SkillDetailDialog(skill: skill),
    );

class _SkillDetailDialog extends ConsumerStatefulWidget {
  const _SkillDetailDialog({required this.skill});

  final AgentSkill skill;

  @override
  ConsumerState<_SkillDetailDialog> createState() => _SkillDetailDialogState();
}

class _SkillDetailDialogState extends ConsumerState<_SkillDetailDialog> {
  /// Relative path of the file being read. Null until the folder is listed —
  /// then the card, which is what the user came to see.
  String? _selected;

  /// Rendered rather than raw. Only ever true for markdown; a script has no
  /// second way to look at it.
  bool _preview = true;

  @override
  Widget build(BuildContext context) {
    // Dialog/overlay content: watch brightness so tokens re-color on theme flip.
    AppTheme.watch(context);
    final theme = Theme.of(context);
    final skill = widget.skill;
    final files = ref.watch(skillFilesProvider(skill.path));
    final loaded = switch (files) {
      AsyncData(:final value) => value,
      _ => null,
    };
    final size = MediaQuery.sizeOf(context);

    return AlertDialog(
      backgroundColor: AppGlass.surfaceFill,
      surfaceTintColor: Colors.transparent,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
      titlePadding: const EdgeInsets.fromLTRB(28, 24, 20, 0),
      contentPadding: const EdgeInsets.fromLTRB(28, 14, 28, 4),
      actionsPadding: const EdgeInsets.fromLTRB(28, 10, 22, 20),
      title: _Header(skill: skill, count: loaded?.length),
      content: SizedBox(
        width: math.min(760, size.width * 0.86),
        height: math.min(460, size.height * 0.66),
        child: switch (files) {
          AsyncData(:final value) when value.isEmpty => Center(
            child: Text(
              'This folder has no files in it — the skill was probably '
              'deleted from disk.',
              style: theme.textTheme.bodyMedium?.copyWith(
                color: AppPalette.textSecondary,
              ),
            ),
          ),
          AsyncData(:final value) => _Body(
            skill: skill,
            files: value,
            selected: _selectionIn(value),
            onSelect: (path) => setState(() {
              _selected = path;
              _preview = true;
            }),
            preview: _preview,
            onPreview: (on) => setState(() => _preview = on),
          ),
          AsyncError(:final error) => Center(
            child: Text(
              "Couldn't read the skill's folder: $error",
              style: theme.textTheme.bodyMedium?.copyWith(
                color: AppPalette.textSecondary,
              ),
            ),
          ),
          _ => const Center(child: AppSpinner()),
        },
      ),
      actions: [
        // The folder itself, selectable — the answer to "where is this?" and
        // the only way to act on a skill the app won't edit for you.
        Expanded(
          child: CodeTextScope(
            child: SelectableText(
              skill.path,
              maxLines: 1,
              style: AppFont.codeStyle(
                color: AppPalette.textFaint,
                scale: 0.92,
              ),
            ),
          ),
        ),
        const SizedBox(width: 12),
        FilledButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Close'),
        ),
      ],
    );
  }

  /// The file being shown, kept valid against the list that actually loaded —
  /// a refresh mid-read can drop the file the user was on.
  String _selectionIn(List<SkillFile> files) {
    final chosen = _selected;
    final found = files.any((file) => file.relativePath == chosen);
    return found ? chosen! : files.first.relativePath;
  }
}

class _Header extends StatelessWidget {
  const _Header({required this.skill, required this.count});

  final AgentSkill skill;
  final int? count;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(
              child: Text(
                skill.name,
                style: theme.textTheme.headlineSmall?.copyWith(
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
            AppIconButton(
              tooltip: 'Close',
              icon: Icons.close_rounded,
              onPressed: () => Navigator.of(context).pop(),
            ),
          ],
        ),
        const SizedBox(height: 4),
        Text(
          count == null
              ? 'by ${skill.owner.label}'
              : 'by ${skill.owner.label} · $count ${count == 1 ? 'file' : 'files'}',
          style: theme.textTheme.bodySmall?.copyWith(
            color: AppPalette.textSecondary,
          ),
        ),
        if (skill.description.isNotEmpty) ...[
          const SizedBox(height: 10),
          // The card's own description in full — the row could only show a
          // sentence of it, and this is the line the agent matches on.
          Text(
            skill.description,
            style: theme.textTheme.bodyMedium?.copyWith(
              color: AppPalette.textSecondary,
              height: 1.45,
            ),
          ),
        ],
      ],
    );
  }
}

/// The two panes: what's in the folder, and what's in the file.
class _Body extends StatelessWidget {
  const _Body({
    required this.skill,
    required this.files,
    required this.selected,
    required this.onSelect,
    required this.preview,
    required this.onPreview,
  });

  final AgentSkill skill;
  final List<SkillFile> files;
  final String selected;
  final ValueChanged<String> onSelect;
  final bool preview;
  final ValueChanged<bool> onPreview;

  @override
  Widget build(BuildContext context) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SizedBox(
          width: 208,
          child: _FileList(
            files: files,
            selected: selected,
            onSelect: onSelect,
          ),
        ),
        const SizedBox(width: 14),
        Expanded(
          child: _FileView(
            path: '${skill.path}/$selected',
            name: selected,
            preview: preview,
            onPreview: onPreview,
          ),
        ),
      ],
    );
  }
}

class _FileList extends StatelessWidget {
  const _FileList({
    required this.files,
    required this.selected,
    required this.onSelect,
  });

  final List<SkillFile> files;
  final String selected;
  final ValueChanged<String> onSelect;

  @override
  Widget build(BuildContext context) {
    AppTheme.watch(context); // reads AppSurface/AppPalette tokens
    // Grouped by folder, in the order the files already came in, so `scripts/`
    // reads as a place rather than as a prefix repeated down the column.
    final entries = <Widget>[];
    var folder = '';
    var first = true;
    for (final file in files) {
      if (file.folder != folder || first) {
        folder = file.folder;
        if (folder.isNotEmpty) {
          entries.add(_FolderLabel(folder: folder, topGap: !first));
        }
      }
      first = false;
      entries.add(
        _FileRow(
          file: file,
          selected: file.relativePath == selected,
          indented: file.folder.isNotEmpty,
          onTap: () => onSelect(file.relativePath),
        ),
      );
    }

    return Container(
      decoration: BoxDecoration(
        color: AppSurface.recess,
        borderRadius: BorderRadius.circular(14),
      ),
      padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 6),
      child: ListView(children: entries),
    );
  }
}

class _FolderLabel extends StatelessWidget {
  const _FolderLabel({required this.folder, required this.topGap});

  final String folder;
  final bool topGap;

  @override
  Widget build(BuildContext context) {
    AppTheme.watch(context);
    return Padding(
      padding: EdgeInsets.fromLTRB(8, topGap ? 12 : 2, 8, 4),
      child: Row(
        children: [
          Icon(
            Icons.folder_outlined,
            size: 13,
            color: AppPalette.textFaint,
          ),
          const SizedBox(width: 6),
          Expanded(
            child: Text(
              folder,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: 11,
                fontWeight: FontWeight.w700,
                letterSpacing: 0.4,
                color: AppPalette.textFaint,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _FileRow extends StatefulWidget {
  const _FileRow({
    required this.file,
    required this.selected,
    required this.indented,
    required this.onTap,
  });

  final SkillFile file;
  final bool selected;
  final bool indented;
  final VoidCallback onTap;

  @override
  State<_FileRow> createState() => _FileRowState();
}

class _FileRowState extends State<_FileRow> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    AppTheme.watch(context);
    final selected = widget.selected;
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() => _hovered = false),
      child: GestureDetector(
        onTap: widget.onTap,
        child: Container(
          margin: const EdgeInsets.only(bottom: 2),
          padding: EdgeInsets.fromLTRB(widget.indented ? 20 : 8, 6, 8, 6),
          decoration: BoxDecoration(
            color: selected
                ? AppSurface.selectedFill
                : (_hovered ? AppSurface.hoverFill : Colors.transparent),
            borderRadius: BorderRadius.circular(9),
          ),
          child: Row(
            children: [
              Expanded(
                child: Text(
                  widget.file.name,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 12.5,
                    fontWeight: selected ? FontWeight.w600 : FontWeight.w500,
                    color: selected
                        ? AppPalette.textPrimary
                        : AppPalette.textSecondary,
                  ),
                ),
              ),
              const SizedBox(width: 6),
              Text(
                formatSkillFileSize(widget.file.sizeBytes),
                style: TextStyle(fontSize: 10.5, color: AppPalette.textFaint),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// One file's contents: markdown rendered, everything else as it is on disk.
class _FileView extends ConsumerWidget {
  const _FileView({
    required this.path,
    required this.name,
    required this.preview,
    required this.onPreview,
  });

  final String path;
  final String name;
  final bool preview;
  final ValueChanged<bool> onPreview;

  bool get _isMarkdown => name.toLowerCase().endsWith('.md');

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    AppTheme.watch(context);
    final text = ref.watch(skillFileTextProvider(path));
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            Expanded(
              child: Text(
                name,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                  color: AppPalette.textSecondary,
                ),
              ),
            ),
            // Only markdown has two ways to be read. A script shown "rendered"
            // would just be the same text with the indentation thrown away.
            if (_isMarkdown) ...[
              AppIconButton(
                tooltip: 'Rendered',
                icon: Icons.visibility_outlined,
                color: preview ? AppPalette.accent : AppPalette.textFaint,
                onPressed: () => onPreview(true),
              ),
              const SizedBox(width: 2),
              AppIconButton(
                tooltip: 'Source',
                icon: Icons.code_rounded,
                color: preview ? AppPalette.textFaint : AppPalette.accent,
                onPressed: () => onPreview(false),
              ),
            ],
          ],
        ),
        const SizedBox(height: 8),
        Expanded(
          child: Container(
            decoration: BoxDecoration(
              color: AppSurface.recess,
              borderRadius: BorderRadius.circular(14),
            ),
            padding: const EdgeInsets.fromLTRB(14, 12, 8, 12),
            child: switch (text) {
              AsyncData(:final value) => _Content(
                text: value,
                rendered: _isMarkdown && preview,
              ),
              AsyncError(:final error) => Text(
                "Couldn't read it: $error",
                style: Theme.of(context).textTheme.bodySmall?.copyWith(
                  color: AppPalette.textSecondary,
                ),
              ),
              _ => const Center(child: AppSpinner()),
            },
          ),
        ),
      ],
    );
  }
}

class _Content extends StatelessWidget {
  const _Content({required this.text, required this.rendered});

  final String text;
  final bool rendered;

  @override
  Widget build(BuildContext context) {
    AppTheme.watch(context);
    if (rendered) {
      return Markdown(
        data: text,
        padding: const EdgeInsets.only(right: 6),
        selectable: true,
        styleSheet: MarkdownStyleSheet.fromTheme(Theme.of(context)).copyWith(
          p: Theme.of(
            context,
          ).textTheme.bodyMedium?.copyWith(height: 1.5),
          code: AppFont.codeStyle(scale: 0.92),
          codeblockDecoration: BoxDecoration(
            color: AppCard.inset,
            borderRadius: BorderRadius.circular(10),
          ),
        ),
      );
    }
    // Source: the file as it is on disk, at the user's code size, scrollable
    // both ways — a script's long line must not be wrapped into a lie about
    // where it breaks.
    return CodeTextScope(
      child: SingleChildScrollView(
        child: SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          child: SelectableText(
            text,
            style: AppFont.codeStyle(
              color: AppPalette.textPrimary,
              height: 1.5,
            ),
          ),
        ),
      ),
    );
  }
}
