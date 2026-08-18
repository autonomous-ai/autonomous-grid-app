import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../shared/theme/app_theme.dart';
import '../../../shared/widgets/app_spinner.dart';
import '../../../shared/widgets/composer_buttons.dart';
import '../../../shared/widgets/composer_keys.dart';
import '../../../shared/widgets/context_chip.dart';
import '../../../shared/widgets/liquid_glass.dart';
import '../../../shared/widgets/toast.dart';
import '../../playground/logic/chat_file.dart';
import '../../playground/logic/playground_request.dart';
import '../../playground/logic/recording_controller.dart';
import '../../playground/presentation/attachment_bar.dart';
import '../../playground/presentation/file_chip.dart';
import '../logic/composer_snippet.dart';
import '../logic/composer_context.dart';
import '../logic/file_attachments.dart';
import 'snippet_chip.dart';

part 'chat_composer_actions.dart';
part 'chat_composer_context.dart';

/// The composer: one rounded card holding everything a message needs — what's
/// attached, what you're typing, which model answers, and Send.
///
/// Grouping them in a single surface (rather than a field with controls floating
/// around it) is what makes the model a property of *this message* — you can see
/// what will answer before you press Send.
class ComposerSection extends StatelessWidget {
  const ComposerSection({
    super.key,
    required this.messageController,
    required this.attachments,
    required this.files,
    required this.snippets,
    required this.terminals,
    required this.modality,
    required this.needsImage,
    required this.sending,
    required this.canSend,
    required this.busySendTooltip,
    required this.error,
    this.errorAction,
    required this.approvalPicker,
    this.agentPicker,
    required this.modelPicker,
    required this.onAddAttachment,
    required this.onAttachFile,
    required this.onPaste,
    required this.onRemoveAttachment,
    required this.onRemoveFile,
    required this.onRemoveSnippets,
    required this.onRemoveTerminal,
    required this.onOpenCommands,
    required this.onSend,
    required this.focusNode,
    required this.onStop,
  });

  final TextEditingController messageController;
  final List<MediaAttachment> attachments;

  /// The documents on this message — a report, a spreadsheet — shown as chips
  /// above the field so what will be sent is visible before Send.
  final List<ChatFile> files;

  /// The runs of text picked out of files, in one chip beside the documents.
  final List<ChatSnippet> snippets;

  /// The terminals on screen, shown as chips so what the assistant will be able
  /// to read is visible before Send rather than a surprise afterwards.
  final List<AttachedTerminal> terminals;
  final PlaygroundModality modality;
  final bool needsImage;
  final bool sending;
  final bool canSend;

  /// What Send says it will do while a turn is still running — the truth differs
  /// by chat: a message can go **into** the answer being written, or wait for it
  /// (see `canSteerChatProvider`), and a button that promised the wrong one
  /// would be the app misreporting what pressing it does.
  final String busySendTooltip;

  final String? error;

  /// A way out of [error], shown beside it — e.g. handing the chat to another
  /// agent when this one can't answer with the model that's picked. Null when
  /// the message has no one-click fix, which is most of them.
  final Widget? errorAction;

  /// The control for what the assistant may do to this computer, or null on a
  /// turn nothing can (a picture is made by the grid, which has no filesystem).
  final Widget? approvalPicker;

  /// The control for which agent answers text-only turns. It stays visible when
  /// a picture is attached even though that turn goes straight to the grid, so
  /// attaching something never hides or resets the conversation's agent choice.
  final Widget? agentPicker;
  final Widget modelPicker;
  final ValueChanged<MediaAttachment> onAddAttachment;

  /// Opens the file picker — pictures and documents in one list, since "attach"
  /// is one thought for the person doing it.
  final VoidCallback onAttachFile;

  /// Takes over ⌘V / Ctrl+V so a screenshot lands as an attachment. See
  /// [ComposerKeys].
  final VoidCallback onPaste;
  final ValueChanged<int> onRemoveAttachment;
  final ValueChanged<int> onRemoveFile;

  /// Takes every selection off at once — see [SnippetChip] for why they arrive
  /// and leave as one.
  final VoidCallback onRemoveSnippets;

  /// Takes a terminal off this message, by the id of the tab it lives in — not
  /// an index: the chips are derived from what the panels are showing, and a
  /// position in that list is only true until a panel changes tab.
  final ValueChanged<String> onRemoveTerminal;

  /// Opens the `/` command menu.
  final VoidCallback onOpenCommands;

  /// The message field's focus, owned by the view so it can put the cursor
  /// back in the box — after picking a command out of the `/` menu, which
  /// leaves a line half-typed and the user with nowhere to finish it.
  final FocusNode focusNode;

  final VoidCallback onSend;

  /// Ends the turn that's running — Send turns into Stop while one is.
  final VoidCallback onStop;

  bool get _isText => modality == PlaygroundModality.text;

  @override
  Widget build(BuildContext context) {
    AppTheme.watch(
      context,
    ); // reads AppGlass/AppSurface tokens — follow theme flips
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        if (error != null)
          Padding(
            padding: const EdgeInsets.fromLTRB(4, 0, 4, 8),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(
                  child: Text(
                    error!,
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.error,
                    ),
                  ),
                ),
                if (errorAction != null) ...[
                  const SizedBox(width: 8),
                  errorAction!,
                ],
              ],
            ),
          ),
        LiquidGlass(
          borderRadius: BorderRadius.circular(18),
          fill: AppGlass.surfaceFill,
          shadow: AppSurface.composerShadow,
          showBorder: true,
          borderColor: AppGlass.lift,
          borderWidth: 1.5,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              _Attachments(
                isText: _isText,
                attachments: attachments,
                files: files,
                snippets: snippets,
                terminals: terminals,
                needsImage: needsImage,
                onAdd: onAddAttachment,
                onRemoveAt: onRemoveAttachment,
                onRemoveFileAt: onRemoveFile,
                onRemoveSnippets: onRemoveSnippets,
                onRemoveTerminal: onRemoveTerminal,
              ),
              ComposerKeys(
                canSend: canSend,
                onSend: onSend,
                onPaste: onPaste,
                focusNode: focusNode,
                builder: (context, focusNode) => TextField(
                  controller: messageController,
                  focusNode: focusNode,
                  minLines: 1,
                  maxLines: 6,
                  // Deliberately *not* disabled while a turn runs: what the
                  // user types now goes into the answer being written (or, when
                  // it can't, queues behind it). Locking the box was what made a
                  // follow-up thought something to hold in your head for the
                  // minutes an agent turn can take.
                  enabled: true,
                  keyboardType: TextInputType.multiline,
                  textInputAction: TextInputAction.newline,
                  style: const TextStyle(fontSize: 15),
                  decoration: InputDecoration(
                    hintText: _inputHint(modality),
                    filled: false,
                    border: InputBorder.none,
                    enabledBorder: InputBorder.none,
                    focusedBorder: InputBorder.none,
                    disabledBorder: InputBorder.none,
                    contentPadding: const EdgeInsets.fromLTRB(18, 17, 18, 20),
                  ),
                ),
              ),
              _Actions(
                busySendTooltip: busySendTooltip,
                // Room for either kind: the one button attaches both, so it
                // stays live until the message is full of pictures *and* files.
                canAttach:
                    _isText &&
                    (attachments.length < maxChatImages ||
                        files.length < maxChatFiles),
                sending: sending,
                canSend: canSend,
                approvalPicker: approvalPicker,
                agentPicker: agentPicker,
                modelPicker: modelPicker,
                onAttachFile: onAttachFile,
                onOpenCommands: onOpenCommands,
                messageController: messageController,
                onSend: onSend,
                onStop: onStop,
              ),
            ],
          ),
        ),
      ],
    );
  }

  String _inputHint(PlaygroundModality modality) => switch (modality) {
    PlaygroundModality.image => 'Describe the image to create',
    PlaygroundModality.video => 'Describe the motion',
    PlaygroundModality.text => 'Ask anything',
  };
}
