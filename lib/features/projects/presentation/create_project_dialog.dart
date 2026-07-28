import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../shared/theme/app_theme.dart';
import '../../../shared/widgets/labeled_field.dart';
import '../logic/project.dart';

/// Create a project the way Cowork does: say what you're working on, then point
/// it at a folder — which reveals the fuller form — and it's made.
///
/// Returns the new project, or null if the user backed out. A Grid project is a
/// folder the assistant reads, so a folder is what turns the "Create" button on;
/// until one is chosen the dialog stays on its first, lighter step.
Future<Project?> showCreateProjectDialog(BuildContext context) =>
    showDialog<Project?>(
      context: context,
      builder: (_) => const _CreateProjectDialog(),
    );

class _CreateProjectDialog extends ConsumerStatefulWidget {
  const _CreateProjectDialog();

  @override
  ConsumerState<_CreateProjectDialog> createState() =>
      _CreateProjectDialogState();
}

class _CreateProjectDialogState extends ConsumerState<_CreateProjectDialog> {
  final _name = TextEditingController();
  final _instructions = TextEditingController();

  /// Null until the user picks a folder — which is also what tells the two steps
  /// apart: no folder is the opening "what are you working on" step, a folder is
  /// the fuller "name it, rule it, confirm the folder" step.
  String? _folder;

  @override
  void initState() {
    super.initState();
    // The Create button turns on with a name *and* a folder — rebuild on either.
    _name.addListener(_onChanged);
  }

  @override
  void dispose() {
    _name.removeListener(_onChanged);
    _name.dispose();
    _instructions.dispose();
    super.dispose();
  }

  void _onChanged() => setState(() {});

  bool get _canCreate => _folder != null && _name.text.trim().isNotEmpty;

  Future<void> _pickFolder() async {
    final path = await getDirectoryPath(confirmButtonText: 'Use folder');
    if (path == null || !mounted) return;
    setState(() {
      _folder = path;
      // Seed the name from the folder only when the user hasn't named it yet, so
      // a title they already typed is never overwritten.
      if (_name.text.trim().isEmpty) _name.text = folderName(path);
    });
  }

  void _clearFolder() => setState(() => _folder = null);

  void _create() {
    if (!_canCreate) return;
    final project = ref
        .read(projectsProvider.notifier)
        .create(
          path: _folder!,
          name: _name.text,
          instructions: _instructions.text,
        );
    Navigator.of(context).pop(project);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return AlertDialog(
      backgroundColor: AppPalette.windowBg,
      surfaceTintColor: Colors.transparent,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
      titlePadding: const EdgeInsets.fromLTRB(28, 24, 20, 0),
      contentPadding: const EdgeInsets.fromLTRB(28, 16, 28, 4),
      actionsPadding: const EdgeInsets.fromLTRB(28, 12, 22, 22),
      title: Row(
        children: [
          Expanded(
            child: Text(
              'Create a project',
              style: theme.textTheme.headlineSmall?.copyWith(
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
          IconButton(
            tooltip: 'Close',
            iconSize: 20,
            color: AppPalette.textSecondary,
            icon: const Icon(Icons.close_rounded),
            onPressed: () => Navigator.of(context).pop(),
          ),
        ],
      ),
      content: SizedBox(
        width: 460,
        child: SingleChildScrollView(
          child: _folder == null
              ? _WorkingOnStep(
                  name: _name,
                  goals: _instructions,
                  onUseFolder: _pickFolder,
                )
              : _FolderStep(
                  name: _name,
                  instructions: _instructions,
                  folder: _folder!,
                  onChangeFolder: _pickFolder,
                  onClearFolder: _clearFolder,
                ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        const SizedBox(width: 4),
        FilledButton(
          onPressed: _canCreate ? _create : null,
          child: const Text('Create project'),
        ),
      ],
    );
  }
}

/// Step one: the light, no-commitment start — what you're working on and what
/// you're after — with the one action that moves it forward: point it at a
/// folder.
class _WorkingOnStep extends StatelessWidget {
  const _WorkingOnStep({
    required this.name,
    required this.goals,
    required this.onUseFolder,
  });

  final TextEditingController name;
  final TextEditingController goals;
  final VoidCallback onUseFolder;

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const SizedBox(height: 6),
        LabeledField(
          label: 'What are you working on?',
          controller: name,
          hint: 'Name your project',
          autofocus: true,
        ),
        const SizedBox(height: 16),
        LabeledField(
          label: 'What are you trying to achieve?',
          controller: goals,
          hint: 'Describe your project, goals, subject, etc.',
          minLines: 3,
          maxLines: 6,
        ),
        const SizedBox(height: 16),
        Align(
          alignment: Alignment.centerLeft,
          child: TextButton.icon(
            onPressed: onUseFolder,
            icon: const Icon(Icons.create_new_folder_outlined, size: 18),
            label: const Text('Use a folder'),
          ),
        ),
        const SizedBox(height: 4),
        Padding(
          padding: const EdgeInsets.only(left: 2),
          child: Text(
            'A project reads one folder on this computer — add it to create.',
            style: TextStyle(fontSize: 12, color: AppPalette.textFaint),
          ),
        ),
      ],
    );
  }
}

/// Step two: a folder is chosen, so the fuller form — name it, tell the
/// assistant how to work in it, confirm which folder, and know it stays local.
class _FolderStep extends StatelessWidget {
  const _FolderStep({
    required this.name,
    required this.instructions,
    required this.folder,
    required this.onChangeFolder,
    required this.onClearFolder,
  });

  final TextEditingController name;
  final TextEditingController instructions;
  final String folder;
  final VoidCallback onChangeFolder;
  final VoidCallback onClearFolder;

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const SizedBox(height: 6),
        LabeledField(
          label: 'Name',
          controller: name,
          hint: 'Name your project',
          autofocus: true,
        ),
        const SizedBox(height: 16),
        LabeledField(
          label: 'Instructions',
          controller: instructions,
          hint: 'Tell the assistant how to work in this project (optional)',
          minLines: 3,
          maxLines: 8,
        ),
        const SizedBox(height: 16),
        const FieldLabel('Local folder'),
        _FolderRow(
          folder: folder,
          onChange: onChangeFolder,
          onClear: onClearFolder,
        ),
        const SizedBox(height: 14),
        const _LocalNote(),
      ],
    );
  }
}

/// The chosen folder, with a way to swap it or drop it (which steps back to the
/// opening question).
class _FolderRow extends StatelessWidget {
  const _FolderRow({
    required this.folder,
    required this.onChange,
    required this.onClear,
  });

  final String folder;
  final VoidCallback onChange;
  final VoidCallback onClear;

  @override
  Widget build(BuildContext context) {
    AppTheme.watch(context);
    return Row(
      children: [
        Expanded(
          child: Container(
            padding: const EdgeInsets.fromLTRB(14, 11, 8, 11),
            decoration: BoxDecoration(
              color: AppPalette.cardBg,
              borderRadius: BorderRadius.circular(12),
            ),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    folder,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 13,
                      fontFamily: AppFont.mono,
                      fontFamilyFallback: AppFont.monoFallback,
                      color: AppPalette.textSecondary,
                    ),
                  ),
                ),
                IconButton(
                  tooltip: 'Remove folder',
                  iconSize: 16,
                  visualDensity: VisualDensity.compact,
                  padding: EdgeInsets.zero,
                  constraints: const BoxConstraints(
                    minWidth: 26,
                    minHeight: 26,
                  ),
                  color: AppPalette.textFaint,
                  icon: const Icon(Icons.close_rounded),
                  onPressed: onClear,
                ),
              ],
            ),
          ),
        ),
        const SizedBox(width: 8),
        TextButton(onPressed: onChange, child: const Text('Change')),
      ],
    );
  }
}

/// Says plainly where the project lives — the honest stand-in for Cowork's
/// visibility control, since a Grid project is always local: nothing syncs or
/// uploads, the assistant just reads the folder in place.
class _LocalNote extends StatelessWidget {
  const _LocalNote();

  @override
  Widget build(BuildContext context) {
    AppTheme.watch(context);
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Icon(
          Icons.lock_outline_rounded,
          size: 15,
          color: AppPalette.textSecondary,
        ),
        const SizedBox(width: 9),
        Expanded(
          child: Text(
            'Local · stays on this computer. Nothing syncs or uploads — the '
            'assistant reads the files in this folder as context.',
            style: TextStyle(
              fontSize: 12.5,
              height: 1.4,
              color: AppPalette.textSecondary,
            ),
          ),
        ),
      ],
    );
  }
}
