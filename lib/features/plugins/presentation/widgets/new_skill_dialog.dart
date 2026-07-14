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
Future<void> showNewSkillDialog(BuildContext context) =>
    showDialog<void>(context: context, builder: (_) => const _SkillDialog());

/// Reopens a skill the user wrote to change its wording or steps — the same
/// form, pre-filled from what's on disk.
///
/// Offered only for their own skills (see [AgentSkill.isMine]): the only ones an
/// edit can round-trip without the next Hermes update undoing it.
Future<void> showEditSkillDialog(BuildContext context, AgentSkill skill) =>
    showDialog<void>(
      context: context,
      builder: (_) => _SkillDialog(existing: skill),
    );

/// The shared create/edit form. [existing] null means create; otherwise it's an
/// edit of that skill, pre-filled and saved back over the same folder.
class _SkillDialog extends ConsumerStatefulWidget {
  const _SkillDialog({this.existing});

  final AgentSkill? existing;

  @override
  ConsumerState<_SkillDialog> createState() => _SkillDialogState();
}

class _SkillDialogState extends ConsumerState<_SkillDialog> {
  final _name = TextEditingController();
  final _description = TextEditingController();
  final _instructions = TextEditingController();
  bool _saving = false;
  bool _loading = false;

  bool get _isEdit => widget.existing != null;

  @override
  void initState() {
    super.initState();
    final existing = widget.existing;
    if (existing == null) return;
    _name.text = existing.name;
    _description.text = existing.description;
    _loading = true;
    _prefillInstructions(existing);
  }

  Future<void> _prefillInstructions(AgentSkill skill) async {
    try {
      final text = await ref
          .read(skillAuthorProvider)
          .readInstructions(skill.path);
      if (!mounted) return;
      _instructions.text = text;
    } on Object {
      // Leave it blank — the user can still rewrite the steps from scratch.
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  @override
  void dispose() {
    _name.dispose();
    _description.dispose();
    _instructions.dispose();
    super.dispose();
  }

  bool get _canSave =>
      !_saving &&
      !_loading &&
      skillSlug(_name.text).isNotEmpty &&
      _description.text.trim().isNotEmpty &&
      _instructions.text.trim().isNotEmpty;

  Future<void> _save() {
    final existing = widget.existing;
    return existing == null ? _create() : _update(existing);
  }

  Future<void> _create() {
    final author = ref.read(skillAuthorProvider);
    final name = _name.text.trim();
    if (author.exists(name)) {
      _say('You already have a skill called "$name".');
      return Future<void>.value();
    }
    return _write(
      () => author.create(
        name: name,
        description: _description.text.trim(),
        instructions: _instructions.text,
      ),
      '"$name" is ready — the assistant can use it.',
    );
  }

  Future<void> _update(AgentSkill existing) {
    final author = ref.read(skillAuthorProvider);
    final name = _name.text.trim();
    final previousSlug = existing.path.split('/').last;
    final renamed = skillSlug(name) != previousSlug;
    if (renamed && author.exists(name)) {
      _say('You already have a skill called "$name".');
      return Future<void>.value();
    }
    return _write(
      () => author.edit(
        previousSlug: previousSlug,
        name: name,
        description: _description.text.trim(),
        instructions: _instructions.text,
      ),
      '"$name" saved.',
    );
  }

  Future<void> _write(Future<void> Function() action, String done) async {
    setState(() => _saving = true);
    try {
      await action();
    } on Object catch (error) {
      if (!mounted) return;
      setState(() => _saving = false);
      _say("Couldn't save the skill: $error");
      return;
    }
    ref.invalidate(agentSkillsProvider);
    if (!mounted) return;
    Navigator.of(context).pop();
    _say(done);
  }

  void _say(String message) => ScaffoldMessenger.of(
    context,
  ).showSnackBar(SnackBar(content: Text(message)));

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(_isEdit ? 'Edit skill' : 'New skill'),
      content: SizedBox(
        width: 520,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              TextField(
                controller: _name,
                autofocus: !_isEdit,
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
                enabled: !_loading,
                minLines: 5,
                maxLines: 10,
                onChanged: (_) => setState(() {}),
                decoration: InputDecoration(
                  labelText: 'What should it do?',
                  hintText: _loading
                      ? 'Loading the current steps…'
                      : 'Step by step, as you would explain it to a new '
                            'colleague.',
                ),
              ),
              const SizedBox(height: 14),
              Text(
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
          child: Text(_saveLabel),
        ),
      ],
    );
  }

  String get _saveLabel {
    if (_saving) return 'Saving…';
    return _isEdit ? 'Save changes' : 'Create skill';
  }
}
