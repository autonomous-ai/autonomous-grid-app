import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../../../../shared/theme/app_theme.dart';
import '../../../../shared/widgets/error_box.dart';
import '../../../../shared/widgets/labeled_field.dart';
import '../../logic/code_tasks_controller.dart';
import '../../logic/project_status.dart';
import '../../logic/project_status_controller.dart';
import 'code_dialog.dart';
import 'code_notice.dart';

/// Hand the grid a coding task.
///
/// A task outlives this dialog: a provider claims it, runs an agent against the
/// project's code on their own machine, and pushes the result back. Nothing is
/// held open, so it can take an hour — which is why the dialog closes on send
/// rather than waiting.
Future<void> showNewTaskDialog(
  BuildContext context, {
  required String projectId,
}) => showDialog<void>(
  context: context,
  builder: (_) => _NewTaskDialog(projectId: projectId),
);

class _NewTaskDialog extends ConsumerStatefulWidget {
  const _NewTaskDialog({required this.projectId});

  final String projectId;

  @override
  ConsumerState<_NewTaskDialog> createState() => _NewTaskDialogState();
}

class _NewTaskDialogState extends ConsumerState<_NewTaskDialog> {
  final _prompt = TextEditingController();

  /// Paths on this computer, uploaded with the task and committed before any
  /// provider can claim it — so the agent always finds them.
  final _files = <String>[];

  bool _busy = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _prompt.addListener(_onChanged);
  }

  @override
  void dispose() {
    _prompt.removeListener(_onChanged);
    _prompt.dispose();
    super.dispose();
  }

  void _onChanged() => setState(() {});

  Future<void> _addFile() async {
    final file = await openFile();
    if (file == null || !mounted) return;
    setState(() => _files.add(file.path));
  }

  Future<void> _send() async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final task = await ref
          .read(codeTasksProvider(widget.projectId).notifier)
          .create(prompt: _prompt.text.trim(), files: List.of(_files));
      if (!mounted) return;
      // Open it, so "send" ends on the thing the user wants to watch.
      ref.read(selectedCodeTaskProvider.notifier).select(task.id);
      Navigator.of(context).pop();
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
    final status = ref
        .watch(projectStatusProvider(widget.projectId))
        .asData
        ?.value;
    final waiting = status == null ? null : fleetNotice(status);

    return CodeDialog(
      title: 'New task',
      confirmLabel: 'Send to the grid',
      busy: _busy,
      onConfirm: _prompt.text.trim().isEmpty ? null : _send,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const SizedBox(height: 6),
          LabeledField(
            label: 'What should the agent do?',
            controller: _prompt,
            hint: 'e.g. add a retry to the upload path, and a test for it',
            minLines: 4,
            maxLines: 12,
            autofocus: true,
          ),
          const SizedBox(height: 16),
          _Attachments(
            files: _files,
            onAdd: _addFile,
            onRemove: (path) => setState(() => _files.remove(path)),
          ),
          if (waiting != null) ...[
            const SizedBox(height: 14),
            CodeNotice(message: waiting),
          ],
          if (_error case final message?) ...[
            const SizedBox(height: 14),
            ErrorBox(message: message),
          ],
        ],
      ),
    );
  }
}

/// Files to send along with the task.
class _Attachments extends StatelessWidget {
  const _Attachments({
    required this.files,
    required this.onAdd,
    required this.onRemove,
  });

  final List<String> files;
  final VoidCallback onAdd;
  final ValueChanged<String> onRemove;

  @override
  Widget build(BuildContext context) {
    AppTheme.watch(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const FieldLabel('Files to send along (optional)'),
        for (final path in files)
          Padding(
            padding: const EdgeInsets.only(bottom: 6),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    path,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 12.5,
                      fontFamily: AppFont.mono,
                      fontFamilyFallback: AppFont.monoFallback,
                      color: AppPalette.textSecondary,
                    ),
                  ),
                ),
                IconButton(
                  tooltip: 'Remove',
                  iconSize: 15,
                  visualDensity: VisualDensity.compact,
                  padding: EdgeInsets.zero,
                  constraints: const BoxConstraints.tightFor(
                    width: 26,
                    height: 26,
                  ),
                  color: AppPalette.textFaint,
                  icon: const Icon(Icons.close_rounded),
                  onPressed: () => onRemove(path),
                ),
              ],
            ),
          ),
        Align(
          alignment: Alignment.centerLeft,
          child: TextButton.icon(
            onPressed: onAdd,
            icon: const Icon(LucideIcons.paperclip300, size: 16),
            label: const Text('Add a file'),
          ),
        ),
      ],
    );
  }
}
