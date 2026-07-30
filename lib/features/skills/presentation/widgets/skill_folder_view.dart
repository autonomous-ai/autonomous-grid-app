import 'package:flutter/material.dart';
import 'package:flutter_markdown_plus/flutter_markdown_plus.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../shared/theme/app_theme.dart';
import '../../../../shared/widgets/app_icon_button.dart';
import '../../../../shared/widgets/app_spinner.dart';
import '../../../../shared/widgets/code_text_scope.dart';
import '../../logic/skill_files.dart';

/// What's inside a skill: its files down the left, the one you're reading on
/// the right.
///
/// One widget for both places a skill can be — installed on disk, or still in
/// the bundled catalog — because the question is the same either way: what does
/// this thing actually do? Reading a catalog skill *before* installing it is
/// most of the point of having a catalog.
class SkillFolderView extends ConsumerStatefulWidget {
  const SkillFolderView({super.key, required this.folder});

  final SkillFolder folder;

  @override
  ConsumerState<SkillFolderView> createState() => _SkillFolderViewState();
}

class _SkillFolderViewState extends ConsumerState<SkillFolderView> {
  /// Relative path of the file being read. Null until the folder is listed —
  /// then the card, which is what the user came to see.
  String? _selected;

  /// Rendered rather than raw. Only ever true for markdown; a script has no
  /// second way to look at it.
  bool _preview = true;

  @override
  void didUpdateWidget(SkillFolderView old) {
    super.didUpdateWidget(old);
    // A different skill is a different folder: keeping the old selection would
    // ask for a file this one may not have.
    if (old.folder != widget.folder) {
      _selected = null;
      _preview = true;
    }
  }

  @override
  Widget build(BuildContext context) {
    AppTheme.watch(context);
    final theme = Theme.of(context);
    final files = ref.watch(skillFilesProvider(widget.folder));

    return switch (files) {
      AsyncData(:final value) when value.isEmpty => Center(
        child: Text(
          "There are no files in this skill's folder.",
          style: theme.textTheme.bodyMedium?.copyWith(
            color: AppPalette.textSecondary,
          ),
        ),
      ),
      AsyncData(:final value) => _Panes(
        folder: widget.folder,
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
    };
  }

  /// The file being shown, kept valid against the list that actually loaded —
  /// a refresh mid-read can drop the file the user was on.
  String _selectionIn(List<SkillFile> files) {
    final chosen = _selected;
    final found = files.any((file) => file.relativePath == chosen);
    return found ? chosen! : files.first.relativePath;
  }
}

class _Panes extends StatelessWidget {
  const _Panes({
    required this.folder,
    required this.files,
    required this.selected,
    required this.onSelect,
    required this.preview,
    required this.onPreview,
  });

  final SkillFolder folder;
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
            file: (folder: folder, relativePath: selected),
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
          Icon(Icons.folder_outlined, size: 13, color: AppPalette.textFaint),
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
    required this.file,
    required this.preview,
    required this.onPreview,
  });

  final SkillFileRef file;
  final bool preview;
  final ValueChanged<bool> onPreview;

  bool get _isMarkdown => file.relativePath.toLowerCase().endsWith('.md');

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    AppTheme.watch(context);
    final text = ref.watch(skillFileTextProvider(file));
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            Expanded(
              child: Text(
                file.relativePath,
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
          p: Theme.of(context).textTheme.bodyMedium?.copyWith(height: 1.5),
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
