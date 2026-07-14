import 'package:flutter/material.dart';

import '../../../shared/theme/app_theme.dart';
import '../../playground/logic/playground_request.dart';
import '../../playground/presentation/attachment_bar.dart';

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
    required this.modelPicker,
    required this.onAddAttachment,
    required this.onPickImage,
    required this.onRemoveAttachment,
    required this.onSend,
  });

  final TextEditingController messageController;
  final List<MediaAttachment> attachments;
  final PlaygroundModality modality;
  final bool needsImage;
  final bool sending;
  final bool canSend;
  final String? error;
  final Widget modelPicker;
  final ValueChanged<MediaAttachment> onAddAttachment;
  final VoidCallback onPickImage;
  final ValueChanged<int> onRemoveAttachment;
  final VoidCallback onSend;

  bool get _isText => modality == PlaygroundModality.text;

  @override
  Widget build(BuildContext context) {
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
        DecoratedBox(
          decoration: BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.circular(20),
            border: Border.all(color: AppPalette.divider),
            boxShadow: AppSurface.shadow,
          ),
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
                style: const TextStyle(fontSize: 14.5),
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
                  contentPadding: const EdgeInsets.fromLTRB(18, 16, 18, 6),
                ),
              ),
              _Actions(
                canAttach:
                    _isText && !sending && attachments.length < maxChatImages,
                sending: sending,
                canSend: canSend,
                modelPicker: modelPicker,
                onPickImage: onPickImage,
                onSend: onSend,
              ),
            ],
          ),
        ),
      ],
    );
  }

  String _inputHint(PlaygroundModality modality) => switch (modality) {
    PlaygroundModality.image => 'Describe the image to make…',
    PlaygroundModality.video => 'Describe the motion…',
    PlaygroundModality.text => 'Ask anything',
  };
}

/// What's riding along with the message. Media generation gets the full source-
/// image bar (with its own add tile and hint); a vision chat just shows the
/// thumbnails — those are attached with the "+" below.
class _Attachments extends StatelessWidget {
  const _Attachments({
    required this.isText,
    required this.attachments,
    required this.needsImage,
    required this.onAdd,
    required this.onRemoveAt,
  });

  final bool isText;
  final List<MediaAttachment> attachments;
  final bool needsImage;
  final ValueChanged<MediaAttachment> onAdd;
  final ValueChanged<int> onRemoveAt;

  @override
  Widget build(BuildContext context) {
    if (isText && attachments.isEmpty) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 14, 16, 0),
      child: AttachmentBar(
        attachments: attachments,
        maxCount: isText ? maxChatImages : (needsImage ? 1 : 3),
        showAddTile: !isText,
        hint: isText
            ? null
            : needsImage
            ? 'Video needs a starting image to animate.'
            : 'Optional: attach up to 3 images to edit instead of generate.',
        onAdd: onAdd,
        onRemoveAt: onRemoveAt,
      ),
    );
  }
}

/// The composer's foot: attach on the left, then the model that will answer and
/// the Send button on the right.
class _Actions extends StatelessWidget {
  const _Actions({
    required this.canAttach,
    required this.sending,
    required this.canSend,
    required this.modelPicker,
    required this.onPickImage,
    required this.onSend,
  });

  final bool canAttach;
  final bool sending;
  final bool canSend;
  final Widget modelPicker;
  final VoidCallback onPickImage;
  final VoidCallback onSend;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(10, 0, 10, 10),
      child: Row(
        children: [
          IconButton(
            tooltip: canAttach ? 'Attach image' : 'Up to $maxChatImages images',
            iconSize: 19,
            visualDensity: VisualDensity.compact,
            color: AppPalette.textSecondary,
            icon: const Icon(Icons.add_photo_alternate_outlined),
            onPressed: canAttach ? onPickImage : null,
          ),
          const Spacer(),
          Flexible(child: modelPicker),
          const SizedBox(width: 8),
          _SendButton(sending: sending, canSend: canSend, onSend: onSend),
        ],
      ),
    );
  }
}

/// The round Send button — the ink-dark disc of the design, greyed out until the
/// message can actually go (a video, say, needs its starting image first).
class _SendButton extends StatelessWidget {
  const _SendButton({
    required this.sending,
    required this.canSend,
    required this.onSend,
  });

  final bool sending;
  final bool canSend;
  final VoidCallback onSend;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: 36,
      height: 36,
      child: FilledButton(
        onPressed: canSend ? onSend : null,
        style: FilledButton.styleFrom(
          shape: const CircleBorder(),
          padding: EdgeInsets.zero,
          backgroundColor: AppPalette.textPrimary,
          foregroundColor: Colors.white,
          disabledBackgroundColor: AppPalette.cardBgHover,
          disabledForegroundColor: AppPalette.textFaint,
        ),
        child: sending
            ? const SizedBox(
                width: 15,
                height: 15,
                child: CircularProgressIndicator(
                  strokeWidth: 2,
                  color: Colors.white,
                ),
              )
            : const Icon(
                Icons.arrow_upward_rounded,
                size: 18,
                semanticLabel: 'Send',
              ),
      ),
    );
  }
}
