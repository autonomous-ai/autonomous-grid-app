import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../infrastructure/state/chat_prefs_store.dart';
import '../../../infrastructure/state/models/network_credential.dart';
import '../../../shared/layouts/shell_state.dart';
import '../../../shared/theme/app_theme.dart';
import '../../auth/logic/session_controller.dart';
import '../../codex_agent/logic/agent_backend.dart';
import '../../codex_agent/presentation/agent_backend_picker.dart';
import '../../codex_agent/presentation/agent_working_bubble.dart';
import '../../network/logic/grid_overview_provider.dart';
import '../../network/logic/network_models_provider.dart';
import '../../playground/logic/playground_models.dart';
import '../../playground/logic/playground_request.dart';
import '../../playground/presentation/attachment_bar.dart';
import '../../playground/presentation/chat_bubble.dart';
import '../../playground/presentation/chat_input_bar.dart';
import '../../playground/presentation/no_model_yet.dart';
import '../logic/chat_sessions_controller.dart';
import '../logic/conversation.dart';
import 'grid_model_picker.dart';

/// How many images may ride along on a single vision chat message.
const int _maxChatImages = 4;

/// How close to the end (px) still counts as "at the bottom" — within this, new
/// messages auto-follow and the jump-to-latest button hides.
const double _atBottomThreshold = 120;

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

  /// The current grid's model options, cached so the change listener can tell a
  /// real selection from a half-typed name before persisting it.
  List<PlaygroundModelOption> _options = const [];

  /// Whether the transcript is scrolled to (near) the bottom. Drives the
  /// jump-to-latest button and whether new messages auto-follow.
  bool _atBottom = true;

  /// A model the user picked from another grid, held across the grid switch it
  /// triggers so [_syncModelField] applies it instead of the new grid's default.
  String? _pendingPick;

  @override
  void initState() {
    super.initState();
    // The picker is a plain TextEditingController; selecting a model won't
    // rebuild on its own. Refresh so the modality-driven UI (attach bar, send
    // gating, hints) tracks the selection.
    _model.addListener(_onModelChanged);
    _scroll.addListener(_onScroll);
    // Reopening the tab rebuilds this view; land on the latest turn rather than
    // stranding the user at the top of the transcript.
    WidgetsBinding.instance.addPostFrameCallback((_) => _scrollToBottom());
  }

  void _onScroll() {
    if (!_scroll.hasClients) return;
    final pos = _scroll.position;
    final atBottom = pos.pixels >= pos.maxScrollExtent - _atBottomThreshold;
    if (atBottom != _atBottom && mounted) {
      setState(() => _atBottom = atBottom);
    }
  }

  void _onModelChanged() {
    if (!mounted) return;
    setState(() {});
    _rememberModel();
  }

  /// Persist the selection once it's a real option (not a name being typed) so a
  /// new chat and the next launch default to it instead of the grid's first
  /// model.
  void _rememberModel() {
    final id = _model.text.trim();
    if (id.isEmpty || !_options.any((o) => o.id == id)) return;
    ref.read(chatPrefsProvider.notifier).setModel(id);
  }

  @override
  void dispose() {
    _model.removeListener(_onModelChanged);
    _scroll.removeListener(_onScroll);
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
    _options = options;
    final key = '${active?.id}|$gridId';
    // A picker-driven grid switch just landed: honor the model the user chose
    // rather than resetting to this grid's default, then treat it as synced.
    final pending = _pendingPick;
    if (pending != null) {
      _pendingPick = null;
      _synced = true;
      _syncedKey = key;
      _setModelText(pending);
      return;
    }
    if (!_synced || key != _syncedKey) {
      _synced = true;
      _syncedKey = key;
      final stored = active?.model ?? '';
      final hasStored = options.any((o) => o.id == stored);
      _setModelText(hasStored ? stored : _defaultModel(options));
      return;
    }
    if (_model.text.isEmpty && options.isNotEmpty) {
      _setModelText(_defaultModel(options));
    }
  }

  /// The model to fall back to when the conversation has none: the one the user
  /// last used (if this grid still offers it), else the grid's first option.
  String _defaultModel(List<PlaygroundModelOption> options) {
    final saved = ref.read(chatPrefsProvider).model;
    if (saved != null && options.any((o) => o.id == saved)) return saved;
    return options.isEmpty ? '' : options.first.id;
  }

  void _setModelText(String value) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && _model.text != value) _model.text = value;
    });
  }

  /// Apply a pick from the unified grid+model picker: switch to [grid] when it
  /// differs (stashing the model so the re-sync keeps it), else just set the
  /// model on the current grid.
  void _pickGridModel(NetworkCredential grid, PlaygroundModelOption option) {
    final currentId = ref.read(selectedNetworkProvider)?.networkId;
    if (currentId == grid.networkId) {
      _setModelText(option.id);
      return;
    }
    _pendingPick = option.id;
    ref.read(selectedNetworkProvider.notifier).select(grid);
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
    ref
        .read(chatSessionsProvider.notifier)
        .send(
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

  void _scrollToBottom({bool animated = false}) {
    if (!_scroll.hasClients) return;
    final target = _scroll.position.maxScrollExtent;
    if (!animated) {
      _scroll.jumpTo(target);
      return;
    }
    _scroll.animateTo(
      target,
      duration: const Duration(milliseconds: 220),
      curve: Curves.easeOut,
    );
  }

  @override
  Widget build(BuildContext context) {
    final sessions = ref.watch(chatSessionsProvider);
    final options = ref.watch(playgroundModelsProvider);
    final loadingModels =
        ref.watch(gridOverviewProvider).isLoading &&
        ref.watch(networkModelsProvider).isLoading;
    final agentMode = ref.watch(agentBackendProvider).isOn;

    _syncModelField(sessions.active, options, widget.network.networkId);

    // Follow new turns while the user is already at the bottom, and always snap
    // down after switching conversations so a reopened chat shows its latest
    // message — but don't yank a user who scrolled up to read history.
    ref.listen(chatSessionsProvider, (prev, next) {
      final switched = prev?.activeId != next.activeId;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (switched || _atBottom) _scrollToBottom();
      });
    });

    // Nothing can answer yet: no model advertised on the grid. Keep the header
    // (grid + model pickers) so the user can switch to a grid that has a model,
    // rather than being stranded on a dead screen with only "Go to Engines".
    final hasModel = loadingModels || options.isNotEmpty;
    final modality = _modalityFor(options);
    final needsImage = modality == PlaygroundModality.video;
    final canSend =
        !sessions.sending && (!needsImage || _attachments.isNotEmpty);
    final messages = sessions.active?.messages ?? const <ChatMessage>[];
    final trailing = _trailingBubble(sessions.phase, agentMode);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _ChatHeader(modelController: _model, onSelect: _pickGridModel),
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
                : Stack(
                    fit: StackFit.expand,
                    children: [
                      ListView.builder(
                        controller: _scroll,
                        padding: const EdgeInsets.fromLTRB(20, 16, 20, 8),
                        itemCount: messages.length + (trailing != null ? 1 : 0),
                        itemBuilder: (context, i) => i < messages.length
                            ? ChatBubble(message: messages[i])
                            : trailing ?? const SizedBox.shrink(),
                      ),
                      if (!_atBottom)
                        Positioned(
                          right: 16,
                          bottom: 12,
                          child: _JumpToLatestButton(
                            onTap: () => _scrollToBottom(animated: true),
                          ),
                        ),
                    ],
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

  /// The bubble appended after the transcript for the in-flight turn: the media
  /// progress bar while a generation streams, or a spinner while an Agent
  /// (codex) run works — never the media bar for an agent turn, which produces
  /// text, not media.
  Widget? _trailingBubble(SendPhase phase, bool agentMode) => switch (phase) {
    SendGenerating g => GeneratingBubble(phase: g),
    SendBusy() when agentMode => const AgentWorkingBubble(),
    _ => null,
  };

  String _emptyHint(PlaygroundModality modality) => switch (modality) {
    PlaygroundModality.image => 'Describe an image to generate.',
    PlaygroundModality.video => 'Attach an image, then describe the motion.',
    PlaygroundModality.text => 'Send a message to start chatting.',
  };
}

/// The slim header above the transcript: one unified grid+model picker beside
/// the Agent backend picker, so you never have to leave Chat to change grid,
/// model, or agent. Left-aligned and width-capped so it stays a comfortable
/// size on a wide window.
class _ChatHeader extends StatelessWidget {
  const _ChatHeader({required this.modelController, required this.onSelect});

  final TextEditingController modelController;
  final GridModelSelected onSelect;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 14, 20, 12),
      child: Row(
        children: [
          Flexible(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 420),
              child: GridModelPicker(
                currentModelId: modelController.text,
                onSelect: onSelect,
              ),
            ),
          ),
          const SizedBox(width: 12),
          const AgentBackendPicker(),
        ],
      ),
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

/// A small floating "jump to latest" control, shown over the transcript only
/// while the user has scrolled up. Tapping animates back to the newest message
/// so they never have to drag to the bottom by hand.
class _JumpToLatestButton extends StatelessWidget {
  const _JumpToLatestButton({required this.onTap});

  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Tooltip(
      message: 'Jump to latest',
      child: Material(
        color: scheme.surfaceContainerHighest,
        elevation: 3,
        shape: CircleBorder(side: BorderSide(color: scheme.outlineVariant)),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.all(8),
            child: Icon(
              Icons.keyboard_arrow_down_rounded,
              size: 24,
              color: scheme.onSurface,
              semanticLabel: 'Jump to latest',
            ),
          ),
        ),
      ),
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
          const Icon(
            Icons.forum_outlined,
            size: 40,
            color: AppPalette.textFaint,
          ),
          const SizedBox(height: 14),
          Text(
            hint,
            style: theme.textTheme.bodyMedium?.copyWith(
              color: AppPalette.textSecondary,
            ),
          ),
        ],
      ),
    );
  }
}
