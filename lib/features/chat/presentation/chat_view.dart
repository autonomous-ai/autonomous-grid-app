import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../infrastructure/state/models/network_credential.dart';
import '../../../shared/layouts/shell_state.dart';
import '../../../shared/theme/app_theme.dart';
import '../../auth/logic/session_controller.dart';
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

/// How many images may ride along on a single vision chat message.
const int _maxChatImages = 4;

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

  /// The `conversationId|gridId` the model field was last synced to, so
  /// switching chats restores that chat's model and switching grids drops to the
  /// new grid's first model — without clobbering a model being mid-typed.
  String? _syncedKey;
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

  /// Keep the model field in step with the open conversation and selected grid:
  /// on a switch, restore that chat's saved model when the current grid still
  /// offers it, otherwise drop to the grid's first model; within the same
  /// chat+grid, default to the first option until the user picks their own.
  void _syncModelField(
    Conversation? active,
    List<PlaygroundModelOption> options,
    String gridId,
  ) {
    final key = '${active?.id}|$gridId';
    if (!_synced || key != _syncedKey) {
      _synced = true;
      _syncedKey = key;
      final stored = active?.model ?? '';
      final hasStored = options.any((o) => o.id == stored);
      _setModelText(
        hasStored ? stored : (options.isEmpty ? '' : options.first.id),
      );
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

  /// Pick an image to attach to the next message (vision input). Capped at
  /// [_maxChatImages]; a cancelled picker is a no-op.
  Future<void> _pickImage() async {
    if (_attachments.length >= _maxChatImages) return;
    final attachment = await pickImageAttachment();
    if (attachment != null && mounted) {
      setState(() => _attachments.add(attachment));
    }
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

    _syncModelField(sessions.active, options, widget.network.networkId);

    // Keep the transcript pinned to the latest message.
    ref.listen(chatSessionsProvider, (_, _) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _scrollToBottom());
    });

    // Nothing can answer yet: no model advertised on the grid. Keep the header
    // (grid + model pickers) so the user can switch to a grid that has a model,
    // rather than being stranded on a dead screen with only "Go to Engines".
    final hasModel = loadingModels || options.isNotEmpty;
    final modality = _modalityFor(options);
    final needsImage = modality == PlaygroundModality.video;
    final canSend = !sessions.sending && (!needsImage || _attachments.isNotEmpty);
    final messages = sessions.active?.messages ?? const <ChatMessage>[];

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _ChatHeader(
          modelController: _model,
          options: options,
          networkName: widget.network.name,
        ),
        const Divider(height: 1),
        if (!hasModel)
          Expanded(
            child: NoModelYet(
              canManage: widget.network.canManageProvider,
              onGoToEngines: () => ref
                  .read(navSectionProvider.notifier)
                  .select(NavSection.provider),
            ),
          )
        else ...[
          Expanded(
            child: messages.isEmpty
                ? _EmptyChat(hint: _emptyHint(modality))
                : ListView.builder(
                    controller: _scroll,
                    padding: const EdgeInsets.fromLTRB(20, 16, 20, 8),
                    itemCount: messages.length +
                        (sessions.phase is SendGenerating ? 1 : 0),
                    itemBuilder: (context, i) => i < messages.length
                        ? ChatBubble(message: messages[i])
                        : GeneratingBubble(
                            phase: sessions.phase as SendGenerating),
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
            onPickImage: _pickImage,
            onRemoveAttachment: (i) => setState(() => _attachments.removeAt(i)),
            onSend: () => _send(modality),
          ),
        ],
      ],
    );
  }

  String _emptyHint(PlaygroundModality modality) => switch (modality) {
        PlaygroundModality.image => 'Describe an image to generate.',
        PlaygroundModality.video => 'Attach an image, then describe the motion.',
        PlaygroundModality.text => 'Send a message to start chatting.',
      };
}

/// The slim header above the transcript: a grid switcher (only when the account
/// has more than one grid) beside the model picker, so you never have to leave
/// Chat to change either. Left-aligned and width-capped so the two pickers stay
/// a comfortable size on a wide window.
class _ChatHeader extends ConsumerWidget {
  const _ChatHeader({
    required this.modelController,
    required this.options,
    required this.networkName,
  });

  final TextEditingController modelController;
  final List<PlaygroundModelOption> options;
  final String networkName;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final grids = ref.watch(sessionProvider).networks;
    final selectedId = ref.watch(selectedNetworkProvider)?.networkId;
    final showGrid = grids.length >= 2;

    final modelPicker = ModelPicker(
      controller: modelController,
      options: options,
      networkName: networkName,
    );

    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 14, 20, 12),
      child: Align(
        alignment: Alignment.centerLeft,
        child: ConstrainedBox(
          constraints: BoxConstraints(maxWidth: showGrid ? 740 : 360),
          child: showGrid
              ? Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Expanded(
                      child: _GridDropdown(
                        grids: grids,
                        selectedId: selectedId,
                        onSelect: (grid) => ref
                            .read(selectedNetworkProvider.notifier)
                            .select(grid),
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(child: modelPicker),
                  ],
                )
              : modelPicker,
        ),
      ),
    );
  }
}

/// A non-editable dropdown that switches the active grid in place. Keyed on the
/// selection so an external change (e.g. from the Grids tab) re-syncs its label.
class _GridDropdown extends StatelessWidget {
  const _GridDropdown({
    required this.grids,
    required this.selectedId,
    required this.onSelect,
  });

  final List<NetworkCredential> grids;
  final String? selectedId;
  final ValueChanged<NetworkCredential> onSelect;

  @override
  Widget build(BuildContext context) {
    return DropdownMenu<String>(
      key: ValueKey(selectedId),
      initialSelection: selectedId,
      requestFocusOnTap: false,
      enableFilter: false,
      expandedInsets: EdgeInsets.zero,
      label: const Text('Grid'),
      leadingIcon: const Icon(Icons.bolt, size: 18),
      helperText: '${grids.length} grids',
      dropdownMenuEntries: [
        for (final grid in grids)
          DropdownMenuEntry(value: grid.networkId, label: grid.name),
      ],
      onSelected: (id) {
        if (id == null) return;
        for (final grid in grids) {
          if (grid.networkId == id) {
            onSelect(grid);
            return;
          }
        }
      },
    );
  }
}

/// The composer foot: an optional error line, the attachment thumbnails, and
/// the message input. Text chat attaches images via the inline "+" for vision
/// models; media generation uses the full source-image bar.
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
              style: theme.textTheme.bodySmall
                  ?.copyWith(color: theme.colorScheme.error),
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
              maxCount: _maxChatImages,
              showAddTile: false,
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
            prefix: _isText
                ? _AttachButton(
                    enabled: !sending && attachments.length < _maxChatImages,
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
class _AttachButton extends StatelessWidget {
  const _AttachButton({required this.enabled, required this.onTap});

  final bool enabled;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return IconButton(
      tooltip: enabled ? 'Attach image' : 'Up to $_maxChatImages images',
      padding: EdgeInsets.zero,
      constraints: const BoxConstraints.tightFor(width: 40, height: 40),
      iconSize: 20,
      color: AppPalette.textSecondary,
      icon: const Icon(Icons.add_photo_alternate_outlined),
      onPressed: enabled ? onTap : null,
    );
  }
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

