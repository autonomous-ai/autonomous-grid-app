import 'package:flutter/material.dart';

import '../../playground/logic/playground_request.dart';
import '../../playground/presentation/attachment_bar.dart';
import '../../playground/presentation/chat_input_bar.dart';

/// Max images per vision chat message.
const int maxChatImages = 4;

/// The composer foot: an optional error line, the attachment thumbnails, and
/// the message input. Text chat attaches images via the inline "+" for vision
/// models; media generation uses the full source-image bar.
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
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 4, 20, 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (error != null) ...[
            Text(
              error!,
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.error,
              ),
            ),
            const SizedBox(height: 8),
          ],
          // Media generation: source-image bar with its own add tile + hint.
          if (!_isText) ...[
            AttachmentBar(
              attachments: attachments,
              maxCount: needsImage ? 1 : 3,
              hint: needsImage
                  ? 'Video needs a starting image to animate.'
                  : 'Optional: attach up to 3 images to edit instead of generate.',
              onAdd: onAddAttachment,
              onRemoveAt: onRemoveAttachment,
            ),
            const SizedBox(height: 12),
          ],
          // Vision chat: thumbnails of what's attached; add via the inline "+".
          if (_isText && attachments.isNotEmpty) ...[
            AttachmentBar(
              attachments: attachments,
              maxCount: maxChatImages,
              showAddTile: false,
              onAdd: onAddAttachment,
              onRemoveAt: onRemoveAttachment,
            ),
            const SizedBox(height: 12),
          ],
          // Subtle model selector sitting just above the input.
          Align(alignment: Alignment.centerLeft, child: modelPicker),
          const SizedBox(height: 2),
          ChatInputBar(
            controller: messageController,
            sending: sending,
            canSend: canSend,
            hint: _inputHint(modality),
            onSend: onSend,
            prefix: _isText
                ? AttachButton(
                    enabled: !sending && attachments.length < maxChatImages,
                    onTap: onPickImage,
                  )
                : null,
          ),
        ],
      ),
    );
  }

  String _inputHint(PlaygroundModality modality) => switch (modality) {
        PlaygroundModality.image => 'Describe the image…',
        PlaygroundModality.video => 'Describe the motion…',
        PlaygroundModality.text => 'Send a message…',
      };
}

/// The inline "+" that attaches an image to a vision chat message. Disabled
/// while sending or once the per-message image cap is reached.
class AttachButton extends StatelessWidget {
  const AttachButton({
    super.key,
    required this.enabled,
    required this.onTap,
  });

  final bool enabled;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return IconButton(
      tooltip: enabled
          ? 'Attach image'
          : 'Up to $maxChatImages images',
      padding: EdgeInsets.zero,
      constraints: const BoxConstraints.tightFor(width: 40, height: 40),
      iconSize: 20,
      color: Theme.of(context).colorScheme.onSurfaceVariant,
      icon: const Icon(Icons.add_photo_alternate_outlined),
      onPressed: enabled ? onTap : null,
    );
  }
}