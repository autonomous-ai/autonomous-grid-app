import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../shared/theme/app_theme.dart';
import '../../logic/agent_skill.dart';
import '../../logic/skill_author.dart';
import '../../logic/skill_generator.dart';

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
  bool _drafting = false;

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
      !_drafting &&
      skillSlug(_name.text).isNotEmpty &&
      _description.text.trim().isNotEmpty &&
      _instructions.text.trim().isNotEmpty;

  /// Fill the form from a rough idea in the Name field, using whatever model can
  /// already answer. The user edits the draft before saving — it's a head start,
  /// not a commit.
  Future<void> _draftWithAi() async {
    final idea = _name.text.trim();
    if (idea.isEmpty) {
      _say('Type a rough idea in Name first — even a few words.');
      return;
    }

    setState(() => _drafting = true);
    try {
      final draft = await ref.read(skillGeneratorProvider).generate(idea);
      if (!mounted) return;
      _name.text = draft.name;
      _description.text = draft.description;
      _instructions.text = draft.instructions;
    } on SkillGenerationException catch (error) {
      if (mounted) _say(error.message);
    } finally {
      if (mounted) setState(() => _drafting = false);
    }
  }

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
            _isEdit ? 'Edit skill' : 'New skill',
            style: theme.textTheme.headlineSmall?.copyWith(
              fontWeight: FontWeight.w600,
            ),
          ),
          const SizedBox(height: 6),
          Text(
            _isEdit
                ? 'Change what it does, or when the assistant reaches for it.'
                : 'Teach the assistant one job, in your own words.',
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
              _Field(
                label: 'Name',
                controller: _name,
                hint: 'Weekly report',
                enabled: !_drafting,
                autofocus: !_isEdit,
                onChanged: (_) => setState(() {}),
              ),
              if (!_isEdit) ...[
                const SizedBox(height: 10),
                _AiDraftButton(busy: _drafting, onPressed: _draftWithAi),
              ],
              const SizedBox(height: 20),
              _Field(
                label: 'When should the assistant use it?',
                controller: _description,
                hint:
                    'Use whenever I ask for a status report or a weekly '
                    'summary.',
                enabled: !_drafting,
                onChanged: (_) => setState(() {}),
              ),
              const SizedBox(height: 20),
              _Field(
                label: 'What should it do?',
                controller: _instructions,
                hint: _loading
                    ? 'Loading the current steps…'
                    : 'Step by step, as you would explain it to a new '
                          'colleague.',
                enabled: !_loading && !_drafting,
                minLines: 6,
                maxLines: 12,
                onChanged: (_) => setState(() {}),
              ),
              const SizedBox(height: 20),
              const _SavedNote(),
              const SizedBox(height: 4),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: (_saving || _drafting)
              ? null
              : () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        const SizedBox(width: 4),
        FilledButton(
          onPressed: _canSave ? _save : null,
          style: FilledButton.styleFrom(
            padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 14),
          ),
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

/// A labelled input: the label sits above its field, and the field is a soft,
/// borderless capsule — roomier and calmer than a floating-label box, so three
/// of them stacked don't read as a wall.
class _Field extends StatelessWidget {
  const _Field({
    required this.label,
    required this.controller,
    required this.hint,
    this.enabled = true,
    this.autofocus = false,
    this.minLines = 1,
    this.maxLines = 1,
    this.onChanged,
  });

  final String label;
  final TextEditingController controller;
  final String hint;
  final bool enabled;
  final bool autofocus;
  final int minLines;
  final int maxLines;
  final ValueChanged<String>? onChanged;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.only(left: 2, bottom: 8),
          child: Text(
            label,
            style: TextStyle(
              fontSize: 12.5,
              fontWeight: FontWeight.w600,
              color: AppPalette.textSecondary,
            ),
          ),
        ),
        TextField(
          controller: controller,
          enabled: enabled,
          autofocus: autofocus,
          minLines: minLines,
          maxLines: maxLines,
          onChanged: onChanged,
          style: const TextStyle(fontSize: 14, height: 1.4),
          decoration: _fieldDecoration(hint),
        ),
      ],
    );
  }
}

/// The soft, borderless field surface — filled with the card tint, a rounded
/// capsule, and one accent hairline only while focused.
InputDecoration _fieldDecoration(String hint) {
  OutlineInputBorder border(Color color, [double width = 1]) =>
      OutlineInputBorder(
        borderRadius: BorderRadius.circular(12),
        borderSide: width == 0
            ? BorderSide.none
            : BorderSide(color: color, width: width),
      );
  return InputDecoration(
    hintText: hint,
    filled: true,
    fillColor: AppPalette.cardBg,
    hintStyle: TextStyle(
      fontSize: 14,
      height: 1.4,
      color: AppPalette.textFaint,
    ),
    contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 13),
    border: border(Colors.transparent, 0),
    enabledBorder: border(Colors.transparent, 0),
    disabledBorder: border(Colors.transparent, 0),
    focusedBorder: border(AppPalette.accent, 1.5),
  );
}

/// The reassurance line under the form — set off with a small lock so it reads
/// as a quiet aside, not another field.
class _SavedNote extends StatelessWidget {
  const _SavedNote();

  @override
  Widget build(BuildContext context) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Icon(Icons.lock_outline_rounded, size: 15, color: AppPalette.textFaint),
        const SizedBox(width: 8),
        Expanded(
          child: Text(
            'Saved with your own skills, so a Hermes update never overwrites '
            'it.',
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

/// Drafts the whole form from the name using AI — a head start for someone who
/// knows what they want but not how to phrase it as a skill.
class _AiDraftButton extends StatelessWidget {
  const _AiDraftButton({required this.busy, required this.onPressed});

  final bool busy;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    return Align(
      alignment: Alignment.centerLeft,
      child: Tooltip(
        message: 'Fill in the rest from the name using AI',
        child: TextButton.icon(
          onPressed: busy ? null : onPressed,
          icon: busy
              ? const SizedBox(
                  width: 14,
                  height: 14,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : const Icon(Icons.auto_awesome_rounded, size: 16),
          label: Text(busy ? 'Drafting…' : 'Draft with AI'),
        ),
      ),
    );
  }
}
