import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../shared/widgets/composer_notice_bar.dart';
import '../../../shared/widgets/toast.dart';
import '../../chat/logic/chat_sessions_controller.dart';
import '../logic/skill_author.dart';
import '../logic/skill_proposal.dart';

/// Offers to keep the skill the assistant just drafted.
///
/// The bar rather than an automatic write: the assistant proposing a skill is
/// not the same as the user wanting one, and a folder appearing in Skills
/// because a reply happened to contain a block would be the app deciding for
/// them. One button, and the draft is right above it to read first.
class SaveSkillBar extends ConsumerWidget {
  const SaveSkillBar({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // The last message's text, and the parse done here — selecting on the
    // parsed object would hand Riverpod a fresh instance every time and rebuild
    // this bar on every streamed token, since a value class with no `==` never
    // compares equal.
    //
    // Only the last message: an old proposal further up the transcript was
    // either saved or passed over, and either way it is not what is on offer.
    final last = ref.watch(
      chatSessionsProvider.select(
        (s) => switch (s.active?.messages.lastOrNull) {
          final m? when m.role == ChatRole.assistant => m.text,
          _ => null,
        },
      ),
    );
    final proposal = last == null ? null : SkillProposal.parse(last);
    if (proposal == null) return const SizedBox.shrink();

    return ComposerNoticeBar(
      icon: Icons.auto_awesome_outlined,
      label: 'Keep "${proposal.name}" as a skill?',
      actions: [_SaveButton(proposal: proposal)],
    );
  }
}

class _SaveButton extends ConsumerStatefulWidget {
  const _SaveButton({required this.proposal});

  final SkillProposal proposal;

  @override
  ConsumerState<_SaveButton> createState() => _SaveButtonState();
}

class _SaveButtonState extends ConsumerState<_SaveButton> {
  bool _saving = false;

  Future<void> _save() async {
    final author = ref.read(skillAuthorProvider);
    final proposal = widget.proposal;
    // A name already in the store would leave the agent holding two skills with
    // one name, so this stops rather than overwriting someone's work.
    if (author.exists(proposal.name)) {
      ToastScope.show(
        context,
        ToastSpec(
          message:
              'You already have a skill called "${proposal.name}". Ask for it '
              'under another name, or edit the one you have.',
          severity: ToastSeverity.error,
        ),
      );
      return;
    }

    setState(() => _saving = true);
    try {
      await author.create(
        name: proposal.name,
        description: proposal.description,
        instructions: proposal.instructions,
      );
    } on Object {
      if (!mounted) return;
      setState(() => _saving = false);
      ToastScope.show(
        context,
        const ToastSpec(
          message: "Couldn't save the skill.",
          severity: ToastSeverity.error,
        ),
      );
      return;
    }
    if (!mounted) return;
    setState(() => _saving = false);
    ToastScope.show(
      context,
      ToastSpec(message: 'Saved "${proposal.name}" to your skills'),
    );
  }

  @override
  Widget build(BuildContext context) => FilledButton(
    onPressed: _saving ? null : _save,
    child: Text(_saving ? 'Saving…' : 'Save as skill'),
  );
}
