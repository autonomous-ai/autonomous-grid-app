import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../shared/theme/app_theme.dart';
import '../../logic/agent_skill.dart';
import '../../logic/skill_author.dart';

/// Writes a new skill: a name, one line saying *when* to use it, and the
/// instructions themselves.
///
/// That middle field is the one that matters — Hermes reads it to decide whether
/// a skill is relevant to what you just asked, so the dialog says so rather than
/// leaving the user to guess why their skill never fires.
Future<void> showNewSkillDialog(BuildContext context) => showDialog<void>(
  context: context,
  builder: (_) => const _NewSkillDialog(),
);

class _NewSkillDialog extends ConsumerStatefulWidget {
  const _NewSkillDialog();

  @override
  ConsumerState<_NewSkillDialog> createState() => _NewSkillDialogState();
}

class _NewSkillDialogState extends ConsumerState<_NewSkillDialog> {
  final _name = TextEditingController();
  final _description = TextEditingController();
  final _instructions = TextEditingController();
  bool _saving = false;

  @override
  void dispose() {
    _name.dispose();
    _description.dispose();
    _instructions.dispose();
    super.dispose();
  }

  bool get _canSave =>
      !_saving &&
      skillSlug(_name.text).isNotEmpty &&
      _description.text.trim().isNotEmpty &&
      _instructions.text.trim().isNotEmpty;

  Future<void> _save() async {
    final author = ref.read(skillAuthorProvider);
    final name = _name.text.trim();
    if (author.exists(name)) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('You already have a skill called "$name".')),
      );
      return;
    }

    setState(() => _saving = true);
    try {
      await author.create(
        name: name,
        description: _description.text.trim(),
        instructions: _instructions.text,
      );
    } on Object catch (error) {
      if (!mounted) return;
      setState(() => _saving = false);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text("Couldn't save the skill: $error")),
      );
      return;
    }

    ref.invalidate(agentSkillsProvider);
    if (!mounted) return;
    Navigator.of(context).pop();
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('"$name" is ready — the assistant can use it.')),
    );
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('New skill'),
      content: SizedBox(
        width: 520,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              TextField(
                controller: _name,
                autofocus: true,
                onChanged: (_) => setState(() {}),
                decoration: const InputDecoration(
                  labelText: 'Name',
                  hintText: 'Weekly report',
                ),
              ),
              const SizedBox(height: 14),
              TextField(
                controller: _description,
                onChanged: (_) => setState(() {}),
                decoration: const InputDecoration(
                  labelText: 'When should the assistant use it?',
                  hintText:
                      'Use whenever I ask for a status report or a weekly '
                      'summary.',
                ),
              ),
              const SizedBox(height: 14),
              TextField(
                controller: _instructions,
                minLines: 5,
                maxLines: 10,
                onChanged: (_) => setState(() {}),
                decoration: const InputDecoration(
                  labelText: 'What should it do?',
                  hintText:
                      'Step by step, as you would explain it to a new '
                      'colleague.',
                ),
              ),
              const SizedBox(height: 14),
              const Text(
                'Saved with your own skills, so a Hermes update never '
                'overwrites it.',
                style: TextStyle(
                  fontSize: 12.5,
                  color: AppPalette.textSecondary,
                ),
              ),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: _saving ? null : () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: _canSave ? _save : null,
          child: Text(_saving ? 'Saving…' : 'Create skill'),
        ),
      ],
    );
  }
}
