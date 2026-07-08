import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../infrastructure/state/models/network_credential.dart';
import '../../../shared/layouts/shell_state.dart';
import '../../../shared/theme/app_theme.dart';
import '../../network/logic/grid_overview_provider.dart';
import '../../network/logic/network_models_provider.dart';
import '../../playground/logic/playground_models.dart';
import '../../playground/logic/playground_request.dart';
import '../../playground/presentation/attachment_bar.dart';
import '../../playground/presentation/chat_bubble.dart';
import '../../playground/presentation/chat_input_bar.dart';
import '../../playground/presentation/model_picker.dart';
import '../../playground/presentation/no_model_yet.dart';
import '../logic/chat_sessions_controller.dart';
import '../logic/conversation.dart';

/// The open conversation: a model picker on top, the scrolling transcript, and
/// the composer at the foot. Reuses the Playground's shared chat widgets and the
/// modality routing (text / image / video), but reads and writes the persistent
/// [chatSessionsProvider] instead of a throwaway transcript.
class ChatView extends ConsumerStatefulWidget {
  const ChatView({super.key, required this.network});

  final NetworkCredential network;

  @override
  ConsumerState<ChatView> createState() => _ChatViewState();
}

class _ChatViewState extends ConsumerState<ChatView> {
  final _model = TextEditingController();
  final _message = TextEditingController();
  final _scroll = ScrollController();
  final List<MediaAttachment> _attachments = [];

  /// The conversation the model field was last synced to (its id, or null for a
  /// new compose), so switching chats restores that chat's model without
  /// clobbering a model the user is mid-typing in the current one.
  String? _syncedId;
  bool _synced = false;

  @override
  void initState() {
    super.initState();
    // The picker is a plain TextEditingController; selecting a model won't
    // rebuild on its own. Refresh so the modality-driven UI (attach bar, send
    // gating, hints) tracks the selection.
    _model.addListener(_onModelChanged);
  }

  void _onModelChanged() {
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    _model.removeListener(_onModelChanged);
    _model.dispose();
    _message.dispose();
    _scroll.dispose();
    super.dispose();
  }

  /// Keep the model field in step with the open conversation: on a switch,
  /// restore that chat's saved model (or the first advertised one); within the
  /// same chat, default to the first option until the user picks their own.
  void _syncModelField(
    Conversation? active,
    List<PlaygroundModelOption> options,
  ) {
    final key = active?.id;
    if (!_synced || key != _syncedId) {
      _synced = true;
      _syncedId = key;
      final stored = active?.model ?? '';
      _setModelText(stored.isNotEmpty
          ? stored
          : (options.isEmpty ? '' : options.first.id));
      return;
    }
    if (_model.text.isEmpty && options.isNotEmpty) {
      _setModelText(options.first.id);
    }
  }

  void _setModelText(String value) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && _model.text != value) _model.text = value;
    });
  }

  /// The modality of the currently-selected option. Unknown / hand-typed ids
  /// fall back to text (a plain chat model).
  PlaygroundModality _modalityFor(List<PlaygroundModelOption> options) {
    final id = _model.text.trim();
    final match = options.where((o) => o.id == id);
    return match.isEmpty ? PlaygroundModality.text : match.first.modality;
  }

  void _send(PlaygroundModality modality) {
    final message = _message.text.trim();
    if (message.isEmpty) return;
    ref.read(chatSessionsProvider.notifier).send(
          network: widget.network,
          model: _model.text.trim(),
          message: message,
          modality: modality,
          attachments: List.of(_attachments),
        );
    _message.clear();
    if (_attachments.isNotEmpty) setState(_attachments.clear);
  }

  void _scrollToBottom() {
    if (!_scroll.hasClients) return;
    _scroll.jumpTo(_scroll.position.maxScrollExtent);
  }

  @override
  Widget build(BuildContext context) {
    final sessions = ref.watch(chatSessionsProvider);
    final options = ref.watch(playgroundModelsProvider);
    final loadingModels = ref.watch(gridOverviewProvider).isLoading &&
        ref.watch(networkModelsProvider).isLoading;

    _syncModelField(sessions.active, options);

    // Keep the transcript pinned to the latest message.
    ref.listen(chatSessionsProvider, (_, __) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _scrollToBottom());
    });

    // Nothing can answer yet: no model advertised on the grid. Guide the user to
    // start one instead of showing a dead input box.
    if (!loadingModels && options.isEmpty) {
      return NoModelYet(
        canManage: widget.network.canManageProvider,
        onGoToEngines: () =>
            ref.read(navSectionProvider.notifier).select(NavSection.provider),
      );
    }

    final modality = _modalityFor(options);
    final needsImage = modality == PlaygroundModality.video;
    final canSend = !sessions.sending && (!needsImage || _attachments.isNotEmpty);
    final messages = sessions.active?.messages ?? const <ChatMessage>[];

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _ModelBar(
          controller: _model,
          options: options,
          networkName: widget.network.name,
        ),
        const Divider(height: 1),
        Expanded(
          child: messages.isEmpty
              ? _EmptyChat(hint: _emptyHint(modality))
              : ListView.builder(
                  controller: _scroll,
                  padding: const EdgeInsets.fromLTRB(20, 16, 20, 8),
                  itemCount:
                      messages.length + (sessions.phase is SendGenerating ? 1 : 0),
                  itemBuilder: (context, i) => i < messages.length
                      ? ChatBubble(message: messages[i])
                      : GeneratingBubble(phase: sessions.phase as SendGenerating),
                ),
        ),
        _Composer(
          messageController: _message,
          attachments: _attachments,
          modality: modality,
          needsImage: needsImage,
          sending: sessions.sending,
          canSend: canSend,
          error: sessions.error,
          onAddAttachment: (a) => setState(() => _attachments.add(a)),
          onRemoveAttachment: (i) => setState(() => _attachments.removeAt(i)),
          onSend: () => _send(modality),
        ),
      ],
    );
  }

  String _emptyHint(PlaygroundModality modality) => switch (modality) {
        PlaygroundModality.image => 'Describe an image to generate.',
        PlaygroundModality.video => 'Attach an image, then describe the motion.',
        PlaygroundModality.text => 'Send a message to start chatting.',
      };
}

/// The model picker, capped to a comfortable width and left-aligned in a slim
/// header above the transcript.
class _ModelBar extends StatelessWidget {
  const _ModelBar({
    required this.controller,
    required this.options,
    required this.networkName,
  });

  final TextEditingController controller;
  final List<PlaygroundModelOption> options;
  final String networkName;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 14, 20, 12),
      child: Align(
        alignment: Alignment.centerLeft,
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 360),
          child: ModelPicker(
            controller: controller,
            options: options,
            networkName: networkName,
          ),
        ),
      ),
    );
  }
}

/// The composer foot: an optional error line, the attachment bar for media
/// modes, and the message input.
class _Composer extends StatelessWidget {
  const _Composer({
    required this.messageController,
    required this.attachments,
    required this.modality,
    required this.needsImage,
    required this.sending,
    required this.canSend,
    required this.error,
    required this.onAddAttachment,
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
  final ValueChanged<MediaAttachment> onAddAttachment;
  final ValueChanged<int> onRemoveAttachment;
  final VoidCallback onSend;

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
              style: theme.textTheme.bodySmall
                  ?.copyWith(color: theme.colorScheme.error),
            ),
            const SizedBox(height: 8),
          ],
          if (modality != PlaygroundModality.text) ...[
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
          ChatInputBar(
            controller: messageController,
            sending: sending,
            canSend: canSend,
            hint: _inputHint(modality),
            onSend: onSend,
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

/// The transcript placeholder before the first message — a quiet, centered
/// prompt rather than an empty void.
class _EmptyChat extends StatelessWidget {
  const _EmptyChat({required this.hint});
  final String hint;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(Icons.forum_outlined, size: 40, color: AppPalette.textFaint),
          const SizedBox(height: 14),
          Text(
            hint,
            style: theme.textTheme.bodyMedium
                ?.copyWith(color: AppPalette.textSecondary),
          ),
        ],
      ),
    );
  }
}

