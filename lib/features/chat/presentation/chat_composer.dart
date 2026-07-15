import 'package:flutter/material.dart';

import '../../../shared/theme/app_theme.dart';
import '../../../shared/widgets/liquid_glass.dart';
import '../../playground/logic/playground_request.dart';
import '../../playground/presentation/attachment_bar.dart';

part 'chat_composer_actions.dart';
part 'chat_composer_context.dart';

/// Max images per vision chat message.
const int maxChatImages = 4;

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
    required this.modality,
    required this.needsImage,
    required this.sending,
    required this.canSend,
    required this.error,
    required this.approvalPicker,
    required this.modelPicker,
    required this.onAddAttachment,
    required this.onPickImage,
    required this.onRemoveAttachment,
    required this.onOpenPrompts,
    required this.promptsSaveInput,
    required this.onSend,
    required this.onStop,
  });

  final TextEditingController messageController;
  final List<MediaAttachment> attachments;
  final PlaygroundModality modality;
  final bool needsImage;
  final bool sending;
  final bool canSend;
  final String? error;

  /// The control for what the assistant may do to this computer, or null on a
  /// turn nothing can (a picture is made by the grid, which has no filesystem).
  final Widget? approvalPicker;
  final Widget modelPicker;
  final ValueChanged<MediaAttachment> onAddAttachment;
  final VoidCallback onPickImage;
  final ValueChanged<int> onRemoveAttachment;

  /// Opens the saved-prompt menu, or — when there's already text — saves it as a
  /// new prompt. [promptsSaveInput] says which, so the button's icon and tooltip
  /// match what tapping it will do.
  final VoidCallback onOpenPrompts;
  final bool promptsSaveInput;
  final VoidCallback onSend;

  /// Ends the turn that's running — Send turns into Stop while one is.
  final VoidCallback onStop;

  bool get _isText => modality == PlaygroundModality.text;

  @override
  Widget build(BuildContext context) {
    AppTheme.watch(context); // reads AppGlass/AppSurface tokens — follow theme flips
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        if (error != null) ...[
          Padding(
            padding: const EdgeInsets.fromLTRB(4, 0, 4, 8),
            child: Text(
              error!,
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.error,
              ),
            ),
          ),
        ],
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
                needsImage: needsImage,
                onAdd: onAddAttachment,
                onRemoveAt: onRemoveAttachment,
              ),
              TextField(
                controller: messageController,
                minLines: 1,
                maxLines: 6,
                enabled: !sending,
                textInputAction: TextInputAction.send,
                style: const TextStyle(fontSize: 15),
                onSubmitted: (_) {
                  if (canSend) onSend();
                },
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
              _Actions(
                canAttach:
                    _isText && !sending && attachments.length < maxChatImages,
                sending: sending,
                canSend: canSend,
                approvalPicker: approvalPicker,
                modelPicker: modelPicker,
                onPickImage: onPickImage,
                onOpenPrompts: onOpenPrompts,
                promptsSaveInput: promptsSaveInput,
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
