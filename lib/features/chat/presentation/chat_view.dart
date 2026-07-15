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
import '../../agent/logic/hermes_tool.dart';
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
import 'file_mention_menu.dart';
import 'chat_composer.dart';
import 'chat_starters.dart';
import 'grid_model_picker.dart';

/// How close to the end (px) still counts as "at the bottom" — within this, new
/// messages auto-follow and the jump-to-latest button hides.
const double _atBottomThreshold = 120;

/// How wide the conversation column gets on a big window. Long lines are hard to
/// read; the transcript and the composer share this so they line up.
const double _columnWidth = 760;

const double _composerWidth = 780;

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

  /// Persist the selection once it's a real option (not a name being typed) so a
  /// new chat and the next launch default to it instead of the grid's first
  /// model.
  void _rememberModel() {
    final id = _model.text.trim();
    if (id.isEmpty || !_options.any((o) => o.id == id)) return;
    ref.read(chatPrefsProvider.notifier).setModel(id);
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
    final loadingModels =
        ref.watch(gridOverviewProvider).isLoading &&
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

    // Nothing can answer yet: no model advertised on the grid. Send the user to
    // the screen that fixes it rather than leaving them at a dead input box.
    if (!loadingModels && options.isEmpty) {
      return NoModelYet(
        canManage: widget.network.canManageProvider,
        onGoToEngines: () => ref
            .read(shellSectionProvider.notifier)
            .select(ShellSection.engines),
      );
    }

    final modality = _modalityFor(options);
    // An image/video model, or a turn carrying attachments, bypasses the
    // (text-only) agent — so the in-flight bubble must show the media progress
    // bar, not "the agent is working".
    final agentMode = agentAnswersTurn(
      modality: modality,
      hasAttachments: _attachments.isNotEmpty,
      agentInstalled: ref.watch(hermesInstalledProvider),
    );
    final needsImage = modality == PlaygroundModality.video;
    final canSend =
        !sessions.sending && (!needsImage || _attachments.isNotEmpty);
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
                child: isNewChat
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

/// The scrolling conversation, with a "jump to latest" button while the user has
/// scrolled up into the history.
class _Transcript extends StatelessWidget {
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
  Widget build(BuildContext context) {
    final count = messages.length + (trailing != null ? 1 : 0);
    return Stack(
      children: [
        Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: _columnWidth),
            child: ListView.builder(
              controller: scroll,
              padding: const EdgeInsets.fromLTRB(20, 18, 20, 18),
              itemCount: count,
              itemBuilder: (context, i) => i < messages.length
                  ? ChatBubble(message: messages[i])
                  : trailing ?? const SizedBox.shrink(),
            ),
          ),
        ),
        if (!atBottom)
          Positioned(
            right: 20,
            bottom: 12,
            child: _JumpToLatestButton(onTap: onJumpToLatest),
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
    final scheme = Theme.of(context).colorScheme;
    return Tooltip(
      message: 'Jump to latest',
      child: Material(
        color: scheme.surface,
        elevation: 4,
        shadowColor: const Color(0x1A000000),
        shape: const CircleBorder(),
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

/// The overlay shown while a file is being dragged over the chat, so the user
/// knows dropping will add it to the message rather than doing nothing.
class _DropHint extends StatelessWidget {
  const _DropHint();

  @override
  Widget build(BuildContext context) {
    return Positioned.fill(
      child: IgnorePointer(
        child: ColoredBox(
          color: AppPalette.accentMuted,
          child: Center(
            child: DecoratedBox(
              decoration: BoxDecoration(
                color: AppPalette.windowBg,
                borderRadius: BorderRadius.circular(16),
                boxShadow: AppSurface.composerShadow,
              ),
              child: Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: 22,
                  vertical: 16,
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(
                      Icons.file_download_outlined,
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
