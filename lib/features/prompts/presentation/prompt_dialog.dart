import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../shared/theme/app_theme.dart';
import '../../../shared/widgets/labeled_field.dart';
import '../logic/prompt_library_controller.dart';
import '../logic/saved_prompt.dart';

/// Create a new saved prompt, optionally pre-filled with [initialBody] (used by
/// "Save this message" from the composer). Returns the created prompt, or null
/// when cancelled.
Future<SavedPrompt?> showNewPromptDialog(
  BuildContext context, {
  String initialBody = '',
}) => showDialog<SavedPrompt>(
  context: context,
  builder: (_) => _PromptDialog(initialBody: initialBody),
);

/// Reopen a saved prompt to change its name or text.
Future<void> showEditPromptDialog(BuildContext context, SavedPrompt prompt) =>
    showDialog<void>(
      context: context,
      builder: (_) => _PromptDialog(existing: prompt),
    );

/// The shared create/edit form. [existing] null means create.
class _PromptDialog extends ConsumerStatefulWidget {
  const _PromptDialog({this.existing, this.initialBody = ''});

  final SavedPrompt? existing;
  final String initialBody;

  @override
  ConsumerState<_PromptDialog> createState() => _PromptDialogState();
}

class _PromptDialogState extends ConsumerState<_PromptDialog> {
  final _name = TextEditingController();
  final _body = TextEditingController();

  bool get _isEdit => widget.existing != null;

  @override
  void initState() {
    super.initState();
    final existing = widget.existing;
    _name.text = existing?.name ?? '';
    _body.text = existing?.body ?? widget.initialBody;
  }

  @override
  void dispose() {
    _name.dispose();
    _body.dispose();
    super.dispose();
  }

  bool get _canSave =>
      _name.text.trim().isNotEmpty && _body.text.trim().isNotEmpty;

  void _save() {
    final controller = ref.read(promptLibraryProvider.notifier);
    final existing = widget.existing;
    if (existing == null) {
      final created = controller.add(name: _name.text, body: _body.text);
      Navigator.of(context).pop(created);
      return;
    }
    controller.edit(id: existing.id, name: _name.text, body: _body.text);
    Navigator.of(context).pop();
  }

  void _delete(SavedPrompt existing) {
    ref.read(promptLibraryProvider.notifier).remove(existing.id);
    Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return AlertDialog(
      backgroundColor: AppPalette.windowBg,
      surfaceTintColor: Colors.transparent,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
      titlePadding: const EdgeInsets.fromLTRB(28, 26, 28, 0),
      contentPadding: const EdgeInsets.fromLTRB(28, 14, 28, 4),
      actionsPadding: const EdgeInsets.fromLTRB(28, 10, 22, 22),
      title: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            _isEdit ? 'Edit prompt' : 'New prompt',
            style: theme.textTheme.headlineSmall?.copyWith(
              fontWeight: FontWeight.w600,
            ),
          ),
          const SizedBox(height: 6),
          Text(
            'A message you reuse — type / in the chat box to drop it in.',
            style: theme.textTheme.bodyMedium?.copyWith(
              color: AppPalette.textSecondary,
            ),
          ),
        ],
      ),
      content: SizedBox(
        width: 540,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const SizedBox(height: 10),
              LabeledField(
                label: 'Name',
                controller: _name,
                hint: 'Weekly report',
                autofocus: !_isEdit,
                onChanged: (_) => setState(() {}),
              ),
              const SizedBox(height: 20),
              LabeledField(
                label: 'Message',
                controller: _body,
                hint: 'Write a short status update for this week…',
                autofocus: _isEdit,
                minLines: 5,
                maxLines: 12,
                onChanged: (_) => setState(() {}),
              ),
              const SizedBox(height: 4),
            ],
          ),
        ),
      ),
      actions: [
        if (widget.existing case final existing?)
          TextButton(
            onPressed: () => _delete(existing),
            style: TextButton.styleFrom(
              foregroundColor: theme.colorScheme.error,
            ),
            child: const Text('Delete'),
          ),
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        const SizedBox(width: 4),
        FilledButton(
          onPressed: _canSave ? _save : null,
          style: FilledButton.styleFrom(
            padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 14),
          ),
          child: Text(_isEdit ? 'Save changes' : 'Create prompt'),
        ),
      ],
    );
  }
}
