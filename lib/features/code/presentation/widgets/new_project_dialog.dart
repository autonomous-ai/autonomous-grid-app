import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../core/folder_name.dart';
import '../../../../infrastructure/cli/git_providers.dart';
import '../../../../infrastructure/cli/git_repo.dart';
import '../../../../shared/theme/app_theme.dart';
import '../../../../shared/widgets/error_box.dart';
import '../../../../shared/widgets/labeled_field.dart';
import '../../../../shared/widgets/toast.dart';
import '../../logic/code_projects_controller.dart';
import 'code_dialog.dart';
import 'repo_folder_field.dart';

/// Start a shared project from a folder on this computer.
///
/// One dialog, the same shape as Home's: say what you are working on, point it
/// at a folder, done. It is one dialog rather than two because the two halves
/// are not separable — a project with no repository in it cannot run a task,
/// and the only way it ever gets one is this import.
Future<void> showNewProjectDialog(BuildContext context) => showDialog<void>(
  context: context,
  builder: (_) => const _NewProjectDialog(),
);

class _NewProjectDialog extends ConsumerStatefulWidget {
  const _NewProjectDialog();

  @override
  ConsumerState<_NewProjectDialog> createState() => _NewProjectDialogState();
}

class _NewProjectDialogState extends ConsumerState<_NewProjectDialog> {
  final _name = TextEditingController();

  /// Null until a folder is chosen — which is also what tells the two steps
  /// apart, exactly as Home's dialog does it.
  String? _folder;

  /// What Git makes of [_folder], or null while that is still being asked.
  GitFolder? _git;

  bool _busy = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _name.addListener(_onChanged);
  }

  @override
  void dispose() {
    _name.removeListener(_onChanged);
    _name.dispose();
    super.dispose();
  }

  void _onChanged() => setState(() {});

  bool get _canCreate =>
      _folder != null &&
      _name.text.trim().isNotEmpty &&
      RepoGitNote.usable(_git) &&
      !_busy;

  Future<void> _pickFolder() async {
    final path = await pickRepoFolder();
    if (path == null || !mounted) return;
    setState(() {
      _folder = path;
      _git = null;
      // Seed the name from the folder only when it hasn't been typed, so a
      // title they already wrote is never overwritten.
      if (_name.text.trim().isEmpty) _name.text = folderName(path);
    });

    final git = await ref.read(gitRepoServiceProvider).inspect(path);
    // They may have swapped folders while this was out; only the current one's
    // answer is worth anything.
    if (!mounted || _folder != path) return;
    setState(() => _git = git);
  }

  void _clearFolder() => setState(() {
    _folder = null;
    _git = null;
  });

  Future<void> _create() async {
    if (!_canCreate) return;
    final folder = _folder!;
    setState(() {
      _busy = true;
      _error = null;
    });
    final controller = ref.read(codeProjectsProvider.notifier);
    try {
      final project = await controller.create(_name.text.trim());
      ref.read(selectedCodeProjectProvider.notifier).select(project.id);
      try {
        await controller.importRepository(projectId: project.id, path: folder);
      } on Object catch (error) {
        // The project exists and the code does not. Said plainly rather than
        // rolled back: there is no delete for a project, and the fix — import
        // again — is offered on the project's own screen.
        if (!mounted) return;
        setState(() {
          _busy = false;
          _error =
              'The project was created, but the code could not be brought '
              'in: $error\n\nOpen it and try bringing the repository in '
              'again.';
        });
        return;
      }
      if (!mounted) return;
      Navigator.of(context).pop();
      ToastScope.show(
        context,
        ToastSpec(
          message: '${project.name} is on the grid, with your code in it.',
          severity: ToastSeverity.success,
        ),
      );
    } on Object catch (error) {
      if (!mounted) return;
      setState(() {
        _busy = false;
        _error = '$error';
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    AppTheme.watch(context);
    return CodeDialog(
      title: 'Create a shared project',
      confirmLabel: 'Create project',
      busy: _busy,
      onConfirm: _canCreate ? _create : null,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const SizedBox(height: 6),
          LabeledField(
            label: 'What are you working on?',
            controller: _name,
            hint: 'Name your project',
            autofocus: true,
          ),
          const SizedBox(height: 16),
          if (_folder case final folder?) ...[
            const FieldLabel('Folder on this computer'),
            RepoFolderRow(
              folder: folder,
              onChange: _pickFolder,
              onClear: _clearFolder,
            ),
            RepoGitNote(folder: folder, git: _git),
          ] else
            RepoFolderPicker(onPick: _pickFolder),
          const SizedBox(height: 14),
          Text(
            'Everyone you add gets their own copy of the work. Tasks run '
            'against it on other people’s computers, and results come back on '
            'your copy — nobody can push over anybody else’s.',
            style: TextStyle(
              fontSize: 12.5,
              height: 1.45,
              color: AppPalette.textSecondary,
            ),
          ),
          if (_error case final message?) ...[
            const SizedBox(height: 14),
            ErrorBox(message: message),
          ],
        ],
      ),
    );
  }
}
