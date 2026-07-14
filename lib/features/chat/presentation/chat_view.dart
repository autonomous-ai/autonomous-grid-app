import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../infrastructure/state/chat_prefs_store.dart';
import '../../../infrastructure/state/models/network_credential.dart';
import '../../../shared/layouts/shell_state.dart';
import '../../../shared/layouts/widgets/settings_dialog.dart';
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
import '../../playground/presentation/no_model_yet.dart';
import '../logic/chat_sessions_controller.dart';
import '../logic/conversation.dart';
import 'chat_composer.dart';
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
    final backend = ref.watch(agentBackendProvider);

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
    // An image/video model bypasses the (text-only) agent, so the in-flight
    // bubble must show the media progress bar, not "Agent is working".
    final agentMode = backend.forModality(modality).isOn;
    final needsImage = modality == PlaygroundModality.video;
    final canSend =
        !sessions.sending && (!needsImage || _attachments.isNotEmpty);
    final messages = sessions.active?.messages ?? const <ChatMessage>[];
    final trailing = _trailingBubble(sessions.phase, agentMode);

    return Stack(
      children: [
        Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (!hasModel)
              Expanded(
                child: NoModelYet(
                  canManage: widget.network.canManageProvider,
                  onGoToEngines: () =>
                      showSettingsDialog(ref, SettingsTab.engines),
                ),
              )
            else
              Expanded(
                child: _ChatBody(
                  // A brand-new chat centres the composer, ChatGPT-style; the
                  // first message slides it down to the foot.
                  isNewChat: messages.isEmpty && !sessions.sending,
                  greeting: _greeting(modality),
                  // The composer floats over the transcript; [bottomInset] is the
                  // room to reserve for it (measured, so a tall composer never
                  // hides the newest message). The top scrim clears the agent
                  // pill above.
                  transcriptBuilder: (bottomInset) => Stack(
                    fit: StackFit.expand,
                    children: [
                      ListView.builder(
                        controller: _scroll,
                        padding: EdgeInsets.fromLTRB(20, 62, 20, bottomInset),
                        itemCount:
                            messages.length + (trailing != null ? 1 : 0),
                        itemBuilder: (context, i) => i < messages.length
                            ? ChatBubble(message: messages[i])
                            : trailing ?? const SizedBox.shrink(),
                      ),
                      if (!_atBottom)
                        Positioned(
                          right: 16,
                          bottom: bottomInset - 16,
                          child: _JumpToLatestButton(
                            onTap: () => _scrollToBottom(animated: true),
                          ),
                        ),
                    ],
                  ),
                  composer: ComposerSection(
                    messageController: _message,
                    attachments: _attachments,
                    modality: modality,
                    needsImage: needsImage,
                    sending: sessions.sending,
                    canSend: canSend,
                    error: sessions.error,
                    modelPicker: GridModelPicker(
                      currentModelId: _model.text,
                      onSelect: _pickGridModel,
                    ),
                    onAddAttachment: (a) => setState(() => _attachments.add(a)),
                    onPickImage: _pickImage,
                    onRemoveAttachment: (i) =>
                        setState(() => _attachments.removeAt(i)),
                    onSend: () => _send(modality),
                  ),
                ),
              ),
          ],
        ),
        // A short fade at the very top so messages dissolve into the background
        // as they scroll under the floating controls, instead of colliding.
        const Positioned(top: 0, left: 0, right: 0, child: _TopScrim()),
        // The Agent toggle floats over the top-right corner instead of a full
        // header row.
        const Positioned(
          top: 10,
          right: 14,
          child: _FloatingPill(child: AgentBackendPicker()),
        ),
        // A model-less grid has no composer to host the model picker, so float
        // it too — the user can still switch to a grid that serves a model.
        if (!hasModel)
          Positioned(
            top: 10,
            left: 14,
            child: _FloatingPill(
              child: GridModelPicker(
                currentModelId: _model.text,
                onSelect: _pickGridModel,
              ),
            ),
          ),
      ],
    );
  }

  /// The bubble appended after the transcript for the in-flight turn: the media
  /// progress bar while a generation streams, the agent's answer growing live as
  /// it streams in, or a spinner while an agent works before its first token.
  Widget? _trailingBubble(SendPhase phase, bool agentMode) => switch (phase) {
    SendGenerating g => GeneratingBubble(phase: g),
    SendStreaming(:final text) when text.isNotEmpty =>
      ChatBubble(message: ChatMessage(role: ChatRole.assistant, text: text)),
    SendStreaming() => const AgentWorkingBubble(),
    SendBusy() when agentMode => const AgentWorkingBubble(),
    _ => null,
  };

  /// The headline shown above the centred composer on a fresh chat.
  String _greeting(PlaygroundModality modality) => switch (modality) {
    PlaygroundModality.image => 'Describe an image to generate',
    PlaygroundModality.video => 'Attach an image, then describe the motion',
    PlaygroundModality.text => 'What can I help with?',
  };
}

/// The chat body, ChatGPT-style: a fresh chat shows the composer centred under a
/// greeting; the first message slides the composer down to the foot and reveals
/// the transcript above it. This widget choreographs the two layouts and the
/// transition, and measures the (floating) composer so the transcript always
/// leaves room for it — a multi-line draft or attached image never hides the
/// newest message. [transcriptBuilder] is given that reserved bottom inset.
class _ChatBody extends StatefulWidget {
  const _ChatBody({
    required this.isNewChat,
    required this.greeting,
    required this.transcriptBuilder,
    required this.composer,
  });

  final bool isNewChat;
  final String greeting;
  final Widget Function(double bottomInset) transcriptBuilder;
  final Widget composer;

  @override
  State<_ChatBody> createState() => _ChatBodyState();
}

class _ChatBodyState extends State<_ChatBody> {
  // A sensible first guess (model picker + one input line) until the real
  // composer reports its height on the first frame.
  double _composerHeight = 120;

  @override
  Widget build(BuildContext context) {
    final bottomInset = _composerHeight + 24;
    return Stack(
      children: [
        // The transcript fills the area, behind the composer. It's empty on a
        // fresh chat, so fade + ignore it until the conversation starts.
        Positioned.fill(
          child: IgnorePointer(
            ignoring: widget.isNewChat,
            child: AnimatedOpacity(
              opacity: widget.isNewChat ? 0 : 1,
              duration: const Duration(milliseconds: 200),
              child: widget.transcriptBuilder(bottomInset),
            ),
          ),
        ),
        // The composer: centred with a greeting on a fresh chat, pinned to the
        // foot once it starts. The alignment animation is the "input slides down
        // after the first message".
        AnimatedAlign(
          duration: const Duration(milliseconds: 420),
          curve: Curves.easeOutCubic,
          alignment:
              widget.isNewChat ? Alignment.center : Alignment.bottomCenter,
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 760),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                // The greeting exists only on a fresh chat; it collapses away as
                // the composer moves down.
                AnimatedSize(
                  duration: const Duration(milliseconds: 300),
                  curve: Curves.easeOut,
                  child: widget.isNewChat
                      ? Padding(
                          padding: const EdgeInsets.only(bottom: 20),
                          child: Text(
                            widget.greeting,
                            textAlign: TextAlign.center,
                            style: Theme.of(context).textTheme.headlineSmall,
                          ),
                        )
                      : const SizedBox(width: double.infinity),
                ),
                _MeasureSize(
                  onChange: (size) {
                    if ((size.height - _composerHeight).abs() > 0.5) {
                      setState(() => _composerHeight = size.height);
                    }
                  },
                  child: widget.composer,
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }
}

/// Reports its child's size after layout — used to reserve exactly the room the
/// floating composer needs so the transcript never slides under it.
class _MeasureSize extends SingleChildRenderObjectWidget {
  const _MeasureSize({required this.onChange, required super.child});

  final ValueChanged<Size> onChange;

  @override
  RenderObject createRenderObject(BuildContext context) =>
      _MeasureSizeRender(onChange);

  @override
  void updateRenderObject(BuildContext context, _MeasureSizeRender obj) =>
      obj.onChange = onChange;
}

class _MeasureSizeRender extends RenderProxyBox {
  _MeasureSizeRender(this.onChange);

  ValueChanged<Size> onChange;
  Size? _last;

  @override
  void performLayout() {
    super.performLayout();
    final next = child?.size ?? Size.zero;
    if (next != _last) {
      _last = next;
      // Notify after the frame — never call back into setState during layout.
      WidgetsBinding.instance.addPostFrameCallback((_) => onChange(next));
    }
  }
}

/// A short gradient at the top of the transcript that fades messages into the
/// window background as they scroll up, so they don't collide with the floating
/// controls. Non-interactive so it never eats taps.
class _TopScrim extends StatelessWidget {
  const _TopScrim();

  @override
  Widget build(BuildContext context) {
    final bg = Theme.of(context).scaffoldBackgroundColor;
    return IgnorePointer(
      child: Container(
        height: 56,
        decoration: BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: [bg, bg.withAlpha(0)],
          ),
        ),
      ),
    );
  }
}

/// An opaque, rounded surface for a control that floats over the transcript, so
/// it stays legible above scrolling messages.
class _FloatingPill extends StatelessWidget {
  const _FloatingPill({required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Theme.of(context).colorScheme.surface,
      elevation: 3,
      shape: const StadiumBorder(),
      clipBehavior: Clip.antiAlias,
      child: child,
    );
  }
}

/// A round "jump to latest" button shown while the user has scrolled up.
/// Tapping animates back to the newest message so they never have to drag to the
/// bottom by hand.
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
