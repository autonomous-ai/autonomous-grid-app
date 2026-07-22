import 'dart:ui' show ImageFilter;

import 'package:desktop_drop/desktop_drop.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../infrastructure/state/chat_prefs_store.dart';
import '../../../infrastructure/state/models/network_credential.dart';
import '../../../shared/layouts/shell_state.dart';
import '../../../shared/theme/app_theme.dart';
import '../../agent/logic/agent_changes.dart';
import '../../agent/logic/agent_permissions.dart';
import '../../agent/logic/agent_routing.dart';
import '../../agent/logic/codex_chat_sender.dart';
import '../../agents/logic/agent_status.dart';
import '../../agent/presentation/agent_changes_bar.dart';
import '../../agent/presentation/agent_permission_card.dart';
import '../../agent/presentation/approval_picker.dart';
import '../../agent/presentation/agent_working_bubble.dart';
import '../../auth/logic/session_controller.dart';
import '../../network/logic/grid_overview_provider.dart';
import '../../network/logic/network_models_provider.dart';
import '../../playground/logic/playground_models.dart';
import '../../playground/logic/playground_request.dart';
import '../../playground/presentation/attachment_bar.dart';
import '../../playground/presentation/chat_bubble.dart';
import '../../playground/presentation/no_model_yet.dart';
import '../../prompts/logic/prompt_slash.dart';
import '../../prompts/presentation/prompt_dialog.dart';
import '../../prompts/presentation/prompt_slash_menu.dart';
import '../logic/active_workdir.dart';
import '../logic/chat_sessions_controller.dart';
import '../logic/conversation.dart';
import '../logic/file_mention.dart';
import 'agent_handover_bar.dart';
import 'file_mention_menu.dart';
import 'chat_composer.dart';
import 'chat_minimap.dart';
import 'chat_starters.dart';
import 'grid_model_picker.dart';
import 'plan_approve_bar.dart';

/// How close to the end (px) still counts as "at the bottom" — within this, new
/// messages auto-follow and the jump-to-latest button hides.
const double _atBottomThreshold = 120;

/// How wide the conversation column gets on a big window. Long lines are hard to
/// read; the transcript and the composer share this so they line up.
///
/// Wider than the 760 it started at: on a big window that left a broad empty
/// margin either side, and the content — tables above all — was cramped into a
/// column far narrower than the room available.
const double _columnWidth = 1000;

const double _composerWidth = 1020;

/// How much taller than the window the conversation has to be before the minimap
/// rail appears. A chat you can almost see all of doesn't need a table of
/// contents — the rail would just be clutter beside it.
const double _railMinContentRatio = 1.5;

/// The open conversation: the transcript (or, on a fresh chat, a greeting and a
/// few things to try), with the composer at the foot. The composer owns the model
/// choice, so what will answer is visible right where you type.
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

  /// The `conversationId|gridId` the model field was last synced to, so switching
  /// chats restores that chat's model and switching grids drops to the new grid's
  /// first model — without clobbering a model being mid-typed.
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

  /// Whether a file is being dragged over the chat, so it can show a drop hint.
  bool _dragging = false;

  @override
  void initState() {
    super.initState();
    // The picker is a plain TextEditingController; selecting a model won't
    // rebuild on its own. Refresh so the modality-driven UI (attach bar, send
    // gating, hints) tracks the selection.
    _model.addListener(_onModelChanged);
    // The slash menu and the prompts button both track what's typed, so rebuild
    // as the message changes.
    _message.addListener(_onMessageChanged);
    _scroll.addListener(_onScroll);
    // Reopening the section rebuilds this view; land on the latest turn rather
    // than stranding the user at the top of the transcript.
    WidgetsBinding.instance.addPostFrameCallback((_) => _scrollToBottom());
  }

  @override
  void dispose() {
    _model.removeListener(_onModelChanged);
    _message.removeListener(_onMessageChanged);
    _scroll.removeListener(_onScroll);
    _model.dispose();
    _message.dispose();
    _scroll.dispose();
    super.dispose();
  }

  void _onMessageChanged() {
    if (mounted) setState(() {});
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

  /// Persist the selection once it's a real option (not a name being typed):
  /// onto the open chat, so leaving and returning restores *its* model rather
  /// than a default; and into the shared prefs, so a new chat and the next
  /// launch default to it too.
  void _rememberModel() {
    final id = _model.text.trim();
    if (id.isEmpty || !_options.any((o) => o.id == id)) return;
    ref.read(chatPrefsProvider.notifier).setModel(id);
    ref.read(chatSessionsProvider.notifier).setActiveModel(id);
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
      // Wait for the grid's real model list before resolving. Navigating back to
      // the chat rebuilds this view and refetches the models, so they arrive
      // empty for a frame; syncing against that empty list would mark the chat
      // "synced" and then fall through to the default, dropping its own model.
      if (options.isEmpty) return;
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

  /// The modality of the currently-selected option. Unknown / hand-typed ids fall
  /// back to text (a plain chat model).
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
  /// [maxChatImages]; a cancelled picker is a no-op.
  Future<void> _pickImage() async {
    if (_attachments.length >= maxChatImages) return;
    final attachment = await pickImageAttachment();
    if (attachment != null && mounted) {
      setState(() => _attachments.add(attachment));
    }
  }

  /// Drop a starter's prompt into the composer, ready to edit or send.
  void _useStarter(String prompt) {
    _message.text = prompt;
    _message.selection = TextSelection.collapsed(offset: prompt.length);
  }

  /// The composer's prompts button: with an empty box, open the `/` menu; with a
  /// draft already typed, offer to save it as a reusable prompt.
  void _promptsButton() {
    final draft = _message.text.trim();
    if (draft.isNotEmpty) {
      showNewPromptDialog(context, initialBody: draft);
      return;
    }
    _message.text = '/';
    _message.selection = const TextSelection.collapsed(offset: 1);
  }

  /// Replace the slash command being typed with the picked prompt's body.
  void _insertPrompt(String body) {
    _message.text = body;
    _message.selection = TextSelection.collapsed(offset: body.length);
  }

  /// Replace the `@`-mention being typed with the picked file's [name]. The
  /// agent runs with this folder open, so its name alone is enough to read it.
  void _insertMention(String name) {
    final cursor = _message.selection.baseOffset;
    if (cursor < 0) return;
    final mention = activeMention(_message.text, cursor);
    if (mention == null) return;
    final result = applyMention(_message.text, cursor, mention, name);
    _message.text = result.text;
    _message.selection = TextSelection.collapsed(offset: result.cursor);
  }

  /// Drop file paths into the message where the cursor is (or at the end) — how
  /// files dragged in from Finder reach the agent. Reads absolute paths, so a
  /// file outside the chat's folder rests on the agent's own file access.
  void _insertPaths(List<String> paths) {
    final tokens = [
      for (final path in paths)
        if (path.trim().isNotEmpty) path.trim(),
    ];
    if (tokens.isEmpty) return;
    final cursor = _message.selection.baseOffset;
    final at = cursor < 0 ? _message.text.length : cursor;
    final insert = '${tokens.join(' ')} ';
    _message.text = _message.text.replaceRange(at, at, insert);
    _message.selection = TextSelection.collapsed(offset: at + insert.length);
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
    // Still loading while *either* source is in flight: the options are built
    // from both (`/models` plus the node capabilities), so one arriving first
    // leaves the list legitimately empty. Gating on both-at-once (&&) let that
    // half-loaded moment read as "no engine", flashing NoModelYet on the way in
    // — the providers are autoDispose, so every return to Chat refetches and
    // reopens that window.
    final loadingModels =
        ref.watch(gridOverviewProvider).isLoading ||
        ref.watch(networkModelsProvider).isLoading;

    _syncModelField(sessions.active, options, widget.network.networkId);

    // Follow new turns while the user is already at the bottom, and always snap
    // down after switching conversations so a reopened chat shows its latest
    // message — but don't yank a user who scrolled up to read history.
    ref.listen(chatSessionsProvider, (prev, next) {
      final switched = prev?.activeId != next.activeId;
      // The undo snapshots belong to the chat that made them; a different chat
      // starts with a clean slate rather than another chat's pending changes.
      if (switched) {
        WidgetsBinding.instance.addPostFrameCallback(
          (_) => ref.read(agentChangesProvider.notifier).clear(),
        );
      }
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (switched || _atBottom) _scrollToBottom();
      });
    });

    // Nothing on *this* grid can answer yet. Shown in place of the transcript,
    // not in place of the screen: the composer's model pill lists every grid's
    // models, so another grid that does have one online is one click away at the
    // foot of this very page. Returning early here replaced the composer too and
    // hid that exit, leaving "ask the grid owner" as the only way out of a room
    // whose door was already open.
    final noModel = !loadingModels && options.isEmpty;

    final modality = _modalityFor(options);
    // An image/video model, or a turn carrying attachments, bypasses the
    // (text-only) agent — so the in-flight bubble must show the media progress
    // bar, not "the agent is working".
    final agentMode = agentAnswersTurn(
      modality: modality,
      hasAttachments: _attachments.isNotEmpty,
      agentInstalled: ref.watch(anyAgentInstalledProvider),
    );
    final needsImage = modality == PlaygroundModality.video;
    // Nothing to send to while this grid has no model: the composer stays for
    // its model pill (the way out), but Send would have nowhere to go.
    final canSend =
        !noModel &&
        !sessions.sending &&
        (!needsImage || _attachments.isNotEmpty);
    final messages = sessions.active?.messages ?? const <ChatMessage>[];
    final trailing = _trailingBubble(sessions.phase, agentMode);
    final isNewChat = messages.isEmpty && !sessions.sending;
    // The agent has stopped and is asking before it touches this computer.
    final permission = ref.watch(agentPermissionProvider);
    // A leading "/" (with no space yet) opens the saved-prompt menu; an "@"
    // token opens the file menu. Only one shows at a time, prompts first.
    final slash = sessions.sending ? null : slashQuery(_message.text);
    final cursor = _message.selection.baseOffset;
    final mention = (sessions.sending || slash != null || cursor < 0)
        ? null
        : activeMention(_message.text, cursor);

    return DropTarget(
      onDragEntered: (_) => setState(() => _dragging = true),
      onDragExited: (_) => setState(() => _dragging = false),
      onDragDone: (details) {
        setState(() => _dragging = false);
        _insertPaths([for (final file in details.files) file.path]);
      },
      child: Stack(
        children: [
          Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Expanded(
                child: noModel
                    ? NoModelYet(
                        canManage: widget.network.canManageProvider,
                        onGoToEngines: () => ref
                            .read(shellSectionProvider.notifier)
                            .select(ShellSection.engines),
                      )
                    : isNewChat
                    ? ChatStarters(
                        greeting: _greeting(modality),
                        onPick: _useStarter,
                      )
                    : _Transcript(
                        scroll: _scroll,
                        messages: messages,
                        trailing: trailing,
                        atBottom: _atBottom,
                        onJumpToLatest: () => _scrollToBottom(animated: true),
                      ),
              ),
              if (permission != null)
                Center(
                  child: ConstrainedBox(
                    constraints: BoxConstraints(
                      maxWidth: _composerWidth,
                      maxHeight: _permissionCardHeight(context),
                    ),
                    child: Padding(
                      padding: const EdgeInsets.fromLTRB(20, 0, 20, 0),
                      child: AgentPermissionCard(request: permission),
                    ),
                  ),
                ),
              Center(
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: _composerWidth),
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(20, 10, 20, 20),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        const AgentHandoverBar(),
                        const PlanApproveBar(),
                        const AgentChangesBar(),
                        if (slash != null)
                          PromptSlashMenu(query: slash, onPick: _insertPrompt)
                        else if (mention != null)
                          FileMentionMenu(
                            workdir: ref.watch(activeChatWorkdirProvider),
                            query: mention.query,
                            onPick: _insertMention,
                          ),
                        ComposerSection(
                          messageController: _message,
                          attachments: _attachments,
                          modality: modality,
                          needsImage: needsImage,
                          sending: sessions.sending,
                          canSend: canSend,
                          error: sessions.error,
                          // Only this one failure has a one-click fix: the agent
                          // reached the grid but the picked model won't answer
                          // it. Offer the swap right where the message lands.
                          errorAction: sessions.error == kCodexDialectFailure
                              ? const SwitchAgentButton()
                              : null,
                          // Only the agent can touch this computer — a picture is made
                          // by the grid, so there'd be nothing to approve.
                          approvalPicker: agentMode
                              ? const ApprovalPicker()
                              : null,
                          modelPicker: GridModelPicker(
                            currentModelId: _model.text,
                            onSelect: _pickGridModel,
                          ),
                          onAddAttachment: (a) =>
                              setState(() => _attachments.add(a)),
                          onPickImage: _pickImage,
                          onRemoveAttachment: (i) =>
                              setState(() => _attachments.removeAt(i)),
                          onOpenPrompts: _promptsButton,
                          promptsSaveInput: _message.text.trim().isNotEmpty,
                          onSend: () => _send(modality),
                          onStop: () =>
                              ref.read(chatSessionsProvider.notifier).stop(),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ],
          ),
          if (_dragging) const _DropHint(),
        ],
      ),
    );
  }

  /// The bubble appended after the transcript for the in-flight turn: the media
  /// progress bar while a generation streams, the answer growing live as it
  /// streams in, or a spinner while the agent works before its first token.
  Widget? _trailingBubble(SendPhase phase, bool agentMode) => switch (phase) {
    SendGenerating g => GeneratingBubble(phase: g),
    SendStreaming(:final text) when text.isNotEmpty => ChatBubble(
      message: ChatMessage(role: ChatRole.assistant, text: text),
    ),
    SendStreaming() => const AgentWorkingBubble(),
    SendBusy() when agentMode => const AgentWorkingBubble(),
    _ => null,
  };

  double _permissionCardHeight(BuildContext context) {
    final height = MediaQuery.sizeOf(context).height * 0.42;
    return height.clamp(240.0, 380.0);
  }

  /// The headline shown above a fresh chat's starters.
  String _greeting(PlaygroundModality modality) => switch (modality) {
    PlaygroundModality.image => 'What should we create?',
    PlaygroundModality.video => 'Attach an image, then describe the motion',
    PlaygroundModality.text => 'What should we create?',
  };
}

/// The scrolling conversation: the minimap rail down the left, the turns in a
/// centred column, and a "jump to latest" button while the user has scrolled up
/// into the history.
///
/// The ListView spans the *full* pane and each turn is centred within it, rather
/// than the list itself being boxed to [_columnWidth]. A scrollbar hangs off its
/// list's right edge — boxing the list put that edge in the middle of the window,
/// leaving the bar floating in open space instead of riding the window edge.
class _Transcript extends StatefulWidget {
  const _Transcript({
    required this.scroll,
    required this.messages,
    required this.trailing,
    required this.atBottom,
    required this.onJumpToLatest,
  });

  final ScrollController scroll;
  final List<ChatMessage> messages;
  final Widget? trailing;
  final bool atBottom;
  final VoidCallback onJumpToLatest;

  @override
  State<_Transcript> createState() => _TranscriptState();
}

class _TranscriptState extends State<_Transcript> {
  /// One key per message index, so the minimap can scroll a turn into view by
  /// its own rendered position — the turns are wildly uneven in height (a
  /// one-line question against a long reply), so there's no arithmetic that maps
  /// an index to an offset.
  final _itemKeys = <int, GlobalKey>{};

  /// The message index the rail marks as "where you are", or null before the
  /// first frame has measured anything.
  int? _currentIndex;

  /// Whether the transcript is long enough to be worth a rail.
  bool _railVisible = false;

  GlobalKey _keyFor(int index) => _itemKeys.putIfAbsent(index, GlobalKey.new);

  @override
  void initState() {
    super.initState();
    widget.scroll.addListener(_onScroll);
    // The list hasn't been laid out yet, so nothing is measurable until after the
    // first frame — resolve both the rail's visibility and the current turn then.
    WidgetsBinding.instance.addPostFrameCallback((_) => _onScroll());
  }

  @override
  void didUpdateWidget(_Transcript old) {
    super.didUpdateWidget(old);
    if (old.scroll != widget.scroll) {
      old.scroll.removeListener(_onScroll);
      widget.scroll.addListener(_onScroll);
    }
    // A new turn changes the content's height, which can cross the rail's
    // threshold — and lands a new message to mark. Re-measure once it's laid out.
    if (old.messages.length != widget.messages.length) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _onScroll());
    }
  }

  @override
  void dispose() {
    widget.scroll.removeListener(_onScroll);
    super.dispose();
  }

  /// Track what the rail should show: whether it's worth showing at all, and
  /// which turn the user is currently reading.
  void _onScroll() {
    if (!mounted || !widget.scroll.hasClients) return;
    final pos = widget.scroll.position;
    // The rail earns its place only on a transcript worth navigating: total
    // content at least [_railMinContentRatio] of the viewport. maxScrollExtent is
    // the *overflow*, so the content is that plus the viewport itself.
    final visible =
        pos.hasContentDimensions &&
        pos.maxScrollExtent + pos.viewportDimension >=
            pos.viewportDimension * _railMinContentRatio;
    // At the very bottom the reading line can't be reached by the last turns —
    // the list has run out of scroll, so a short final message sits below it
    // forever and the mark would stall an item or two early. Scrolled to the end
    // *is* being at the last turn, so say so directly.
    final atEnd =
        pos.hasContentDimensions &&
        pos.pixels >= pos.maxScrollExtent - _atBottomThreshold;
    // A null reading means nothing measurable has passed the line *this frame* —
    // mid-fling, say, with the turns around the line not yet built. Keep the last
    // answer rather than dropping the mark back to the top of the rail.
    final current = atEnd
        ? widget.messages.length - 1
        : (_currentMessage() ?? _currentIndex);
    if (visible != _railVisible || current != _currentIndex) {
      setState(() {
        _railVisible = visible;
        _currentIndex = current;
      });
    }
  }

  /// The message the user is reading: the last one whose top has passed the
  /// viewport's reading line. Turns are far taller than the rail's ticks, so
  /// "which one is on screen" has to be measured from the laid-out items rather
  /// than interpolated from the scroll offset.
  ///
  /// Only *built* items can be measured: the list is lazy, so the turns scrolled
  /// far off either end have no render object. That's why the answer is the
  /// highest match rather than the first miss — an unbuilt item above the
  /// viewport is above the line whether or not it can say so, and an early exit
  /// on one would pin the answer to the top of the transcript forever.
  int? _currentMessage() {
    final box = context.findRenderObject() as RenderBox?;
    if (box == null || !box.hasSize) return null;
    // A hair below the top edge: what you're reading is what sits at the top of
    // the viewport, not what's level with its middle.
    final line = box.size.height * 0.2;
    int? found;
    for (var i = 0; i < widget.messages.length; i++) {
      final itemContext = _itemKeys[i]?.currentContext;
      if (itemContext == null) continue;
      final item = itemContext.findRenderObject() as RenderBox?;
      if (item == null || !item.hasSize || !item.attached) continue;
      final top = item.localToGlobal(Offset.zero, ancestor: box).dy;
      if (top <= line) found = i;
    }
    // Everything built sits below the line: the user is above the first measured
    // turn, so nothing is being read yet.
    return found;
  }

  /// Bring message [index] to the top of the viewport. Built turns scroll via
  /// their key; one that's been recycled out of the lazy list has no context, so
  /// it falls back to an estimate from its position in the transcript.
  void _jumpTo(int index) {
    final context = _itemKeys[index]?.currentContext;
    if (context != null) {
      Scrollable.ensureVisible(
        context,
        duration: const Duration(milliseconds: 260),
        curve: Curves.easeOutCubic,
        // Land the turn just below the pane's top edge rather than dead-centre:
        // a question is a heading for what follows, so what the user wants to
        // read is underneath it.
        alignment: 0.05,
      );
      return;
    }
    if (!widget.scroll.hasClients || widget.messages.length <= 1) return;
    final pos = widget.scroll.position;
    final t = index / (widget.messages.length - 1);
    widget.scroll.animateTo(
      (pos.maxScrollExtent * t).clamp(0.0, pos.maxScrollExtent),
      duration: const Duration(milliseconds: 260),
      curve: Curves.easeOutCubic,
    );
  }

  @override
  Widget build(BuildContext context) {
    final count = widget.messages.length + (widget.trailing != null ? 1 : 0);
    return Stack(
      children: [
        ListView.builder(
          controller: widget.scroll,
          // No horizontal padding: the list spans the pane so its scrollbar sits
          // on the window edge. The column below insets its own content.
          padding: const EdgeInsets.symmetric(vertical: 18),
          itemCount: count,
          itemBuilder: (context, i) => Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: _columnWidth),
              child: Padding(
                // The rail's width on the left, mirrored on the right, so the
                // column stays optically centred instead of nudged off-axis.
                padding: const EdgeInsets.symmetric(
                  horizontal: chatMinimapWidth,
                ),
                child: i < widget.messages.length
                    ? KeyedSubtree(
                        key: _keyFor(i),
                        child: ChatBubble(message: widget.messages[i]),
                      )
                    : widget.trailing ?? const SizedBox.shrink(),
              ),
            ),
          ),
        ),
        // The rail hugs the pane's left edge, clear of the centred column. It
        // shows only once the conversation is long enough to be worth navigating.
        if (_railVisible)
          Positioned(
            left: 0,
            top: 0,
            bottom: 0,
            child: ChatMinimap(
              marks: minimapMarks(widget.messages),
              currentIndex: _currentIndex,
              onJumpTo: _jumpTo,
            ),
          ),
        if (!widget.atBottom)
          Positioned(
            right: 20,
            bottom: 12,
            child: _JumpToLatestButton(onTap: widget.onJumpToLatest),
          ),
      ],
    );
  }
}

/// A round "jump to latest" button shown while the user has scrolled up. Tapping
/// animates back to the newest message so they never have to drag to the bottom
/// by hand.
class _JumpToLatestButton extends StatelessWidget {
  const _JumpToLatestButton({required this.onTap});

  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    // Reads AppPalette/AppGlass tokens — follow theme flips. Without this the
    // button keeps whichever theme's colours it was first built under: it's a
    // const child of the transcript, so nothing else rebuilds it on a flip.
    AppTheme.watch(context);
    return Tooltip(
      message: 'Jump to latest',
      // The lift comes from the app's own shadow token, not Material's
      // elevation: a hard-coded black shadow reads as grime on a dark pane.
      child: DecoratedBox(
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          boxShadow: AppGlass.cardShadow,
        ),
        child: Material(
          // The app's own surface tokens rather than the Material scheme's: this
          // floats over the transcript, so it has to match the composer and the
          // menus it sits beside, on either theme.
          color: AppGlass.surfaceFill,
          shape: CircleBorder(side: BorderSide(color: AppGlass.lift)),
          clipBehavior: Clip.antiAlias,
          child: InkWell(
            onTap: onTap,
            child: Padding(
              padding: const EdgeInsets.all(8),
              child: Icon(
                Icons.keyboard_arrow_down_rounded,
                size: 24,
                color: AppPalette.textPrimary,
                semanticLabel: 'Jump to latest',
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// The overlay shown while a file is being dragged over the chat, so the user
/// knows dropping will add it to the message rather than doing nothing.
class _DropHint extends StatelessWidget {
  const _DropHint();

  @override
  Widget build(BuildContext context) {
    // Follow the theme so this re-colours the instant the user flips Light/Dark.
    AppTheme.watch(context);
    return Positioned.fill(
      child: IgnorePointer(
        // A soft blur over the chat with just a whisper of the action colour —
        // liquid glass, per the style baseline, not a flat blue wall.
        child: BackdropFilter(
          filter: ImageFilter.blur(sigmaX: 14, sigmaY: 14),
          child: DecoratedBox(
            decoration: BoxDecoration(
              color: AppPalette.accent.withValues(alpha: 0.06),
            ),
            child: Center(
              child: Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 22,
                  vertical: 16,
                ),
                decoration: BoxDecoration(
                  color: AppPalette.windowBg,
                  borderRadius: BorderRadius.circular(16),
                  border: Border.all(
                    color: AppPalette.accent.withValues(alpha: 0.28),
                    width: 1.5,
                  ),
                  boxShadow: AppSurface.composerShadow,
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(
                      Icons.file_download_outlined,
                      size: 20,
                      color: AppPalette.accent,
                    ),
                    const SizedBox(width: 10),
                    Text(
                      'Drop to add the file to your message',
                      style: TextStyle(
                        fontSize: 14,
                        fontWeight: FontWeight.w600,
                        color: AppPalette.textPrimary,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
