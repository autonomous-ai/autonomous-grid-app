import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../shared/widgets/app_dialog.dart';
import '../../../../shared/theme/app_theme.dart';
import '../../../../shared/widgets/error_box.dart';
import '../../../../shared/widgets/labeled_field.dart';
import '../../../../shared/widgets/toast.dart';
import '../../../../infrastructure/cli/git_providers.dart';
import '../../../../infrastructure/cli/git_repo.dart';
import '../../logic/code_projects_controller.dart';
import '../../logic/project_status_controller.dart';
import 'code_dialog.dart';
import 'repo_folder_field.dart';

/// Bring an existing repository, with its history, into a project that has
/// none.
///
/// **The only way a project gets its code**, and it is one shot per project:
/// nothing here can rewrite a trunk once it is set. A refused import leaves the
/// project with no trunk on purpose, so the fix is to address what the grid
/// names and import again.
Future<void> showImportRepoDialog(
  BuildContext context, {
  required String projectId,
}) => showAppDialog<void>(
  context: context,
  builder: (_) => _ImportRepoDialog(projectId: projectId),
);

class _ImportRepoDialog extends ConsumerStatefulWidget {
  const _ImportRepoDialog({required this.projectId});

  final String projectId;

  @override
  ConsumerState<_ImportRepoDialog> createState() => _ImportRepoDialogState();
}

class _ImportRepoDialogState extends ConsumerState<_ImportRepoDialog> {
  final _branch = TextEditingController(text: 'HEAD');

  String? _folder;

  /// What Git makes of [_folder], or null while that is still being asked.
  GitFolder? _git;

  bool _busy = false;
  String? _error;

  @override
  void dispose() {
    _branch.dispose();
    super.dispose();
  }

  Future<void> _pickFolder() async {
    final path = await pickRepoFolder();
    if (path == null || !mounted) return;
    setState(() {
      _folder = path;
      _git = null;
    });
    final git = await ref.read(gitRepoServiceProvider).inspect(path);
    if (!mounted || _folder != path) return;
    setState(() => _git = git);
  }

  Future<void> _import() async {
    final folder = _folder;
    if (folder == null) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final result = await ref
          .read(codeProjectsProvider.notifier)
          .importRepository(
            projectId: widget.projectId,
            path: folder,
            branch: _branch.text.trim().isEmpty ? 'HEAD' : _branch.text.trim(),
          );
      // The screen's whole shape depends on whether a trunk exists, so it is
      // re-read rather than guessed at.
      await ref
          .read(projectStatusProvider(widget.projectId).notifier)
          .refresh();
      if (!mounted) return;
      Navigator.of(context).pop();
      ToastScope.show(
        context,
        ToastSpec(
          message: result.warnings.isEmpty
              ? 'Imported. ${result.trunk} is at ${_short(result.commit)}.'
              : 'Imported, with a note: ${result.warnings.first}',
          severity: result.warnings.isEmpty
              ? ToastSeverity.success
              : ToastSeverity.warning,
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

  static String _short(String commit) =>
      commit.length <= 8 ? commit : commit.substring(0, 8);

  @override
  Widget build(BuildContext context) {
    AppTheme.watch(context);
    return CodeDialog(
      title: 'Bring in a repository',
      confirmLabel: 'Import',
      busy: _busy,
      onConfirm: (_folder == null || !RepoGitNote.usable(_git))
          ? null
          : _import,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const SizedBox(height: 6),
          const FieldLabel('Repository on this computer'),
          if (_folder case final folder?) ...[
            RepoFolderRow(folder: folder, onChange: _pickFolder),
            RepoGitNote(folder: folder, git: _git),
          ] else
            RepoFolderPicker(onPick: _pickFolder),
          const SizedBox(height: 16),
          LabeledField(
            label: 'Which branch',
            controller: _branch,
            hint: 'HEAD — whatever is checked out',
          ),
          const SizedBox(height: 14),
          Text(
            'The whole history is uploaded, so a large repository takes a '
            'while — the grid reads every version of every file before it '
            'accepts one.\n\n'
            'It is refused if the repository has a submodule, a symlink '
            'pointing outside it, or anything under .grid/. Nothing is left '
            'half-done: a refused import leaves the project empty, and you can '
            'fix what it names and try again.',
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
