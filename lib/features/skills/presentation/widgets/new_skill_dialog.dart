import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../shared/theme/app_theme.dart';
import '../../../../shared/widgets/app_spinner.dart';
import '../../../../shared/widgets/labeled_field.dart';
import '../../../../shared/widgets/toast.dart';
import '../../../agents/logic/agent_skill.dart';
import '../../logic/skills_controller.dart';
import '../../logic/skill_author.dart';
import '../../logic/skill_generator.dart';
import 'skill_target_picker.dart';

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
          .read(skillWriterProvider)
          ?.readInstructions(skill.path);
      if (!mounted || text == null) return;
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

  /// True while the AI draft is being fetched — only reachable when
  /// [_showAiDraft] is on.
  bool _drafting = false;

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
    final name = _name.text.trim();
    if (ref.read(skillWriterProvider)?.exists(name) ?? false) {
      _say('You already have a skill called "$name".');
      return Future<void>.value();
    }
    return _write(
      () => ref
          .read(skillsProvider.notifier)
          .create(
            name: name,
            description: _description.text.trim(),
            instructions: _instructions.text,
          ),
      '"$name" is ready — the assistant can use it.',
    );
  }

  Future<void> _update(AgentSkill existing) {
    final name = _name.text.trim();
    final renamed = skillSlug(name) != existing.path.split('/').last;
    if (renamed && (ref.read(skillWriterProvider)?.exists(name) ?? false)) {
      _say('You already have a skill called "$name".');
      return Future<void>.value();
    }
    return _write(
      () => ref
          .read(skillsProvider.notifier)
          .edit(
            previousPath: existing.path,
            name: name,
            description: _description.text.trim(),
            instructions: _instructions.text,
          ),
      '"$name" saved.',
    );
  }

  Future<void> _write(Future<String?> Function() action, String done) async {
    setState(() => _saving = true);
    final failure = await action();
    if (!mounted) return;
    if (failure != null) {
      setState(() => _saving = false);
      _say(failure);
      return;
    }
    Navigator.of(context).pop();
    _say(done, severity: ToastSeverity.success);
  }

  /// Every caller but the save-succeeded one is reporting a failure, so error is
  /// the default and success is opted into.
  void _say(String message, {ToastSeverity severity = ToastSeverity.error}) =>
      ToastScope.show(context, ToastSpec(message: message, severity: severity));

  @override
  Widget build(BuildContext context) {
    // Dialog/overlay content: watch brightness so tokens re-color on theme flip.
    AppTheme.watch(context);
    final theme = Theme.of(context);
    return AlertDialog(
      backgroundColor: AppGlass.surfaceFill,
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
              LabeledField(
                fill: AppTheme.isDark ? AppCard.inset : AppPalette.cardBg,
                label: 'Name',
                controller: _name,
                hint: 'Weekly report',
                enabled: !_drafting,
                autofocus: !_isEdit,
                onChanged: (_) => setState(() {}),
              ),
              if (_showAiDraft) ...[
                const SizedBox(height: 10),
                _AiDraftButton(busy: _drafting, onPressed: _draftWithAi),
              ],
              const SizedBox(height: 20),
              LabeledField(
                fill: AppTheme.isDark ? AppCard.inset : AppPalette.cardBg,
                label: 'When should the assistant use it?',
                controller: _description,
                hint:
                    'Use whenever I ask for a status report or a weekly '
                    'summary.',
                enabled: !_drafting,
                onChanged: (_) => setState(() {}),
              ),
              const SizedBox(height: 20),
              LabeledField(
                fill: AppTheme.isDark ? AppCard.inset : AppPalette.cardBg,
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
              // Only on the way in. Editing rewrites the store copy and does
              // not re-copy it to an agent, so asking here would promise
              // something the Save button doesn't do.
              if (!_isEdit) ...[
                const SkillTargetPicker(),
                const SizedBox(height: 20),
              ],
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

/// The reassurance line under the form — set off with a small lock so it reads
/// as a quiet aside, not another field.
class _SavedNote extends StatelessWidget {
  const _SavedNote();

  @override
  Widget build(BuildContext context) {
    // Dialog/overlay content: watch brightness so tokens re-color on theme flip.
    AppTheme.watch(context);
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

/// Whether the dialog offers to draft the form with AI.
///
/// Off, and the button below is kept rather than deleted: the feature works and
/// is only being held back, so turning it back on is this one line instead of
/// re-writing the generator, the error handling and the busy states.
final bool _showAiDraft = false;

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
              ? const AppSpinner()
              : const Icon(
                  Icons.auto_awesome_rounded,
                  size: AppControl.iconSize,
                ),
          label: Text(busy ? 'Drafting…' : 'Draft with AI'),
        ),
      ),
    );
  }
}
