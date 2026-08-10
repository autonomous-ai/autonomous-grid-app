import 'dart:async';
import 'dart:ui' show ImageFilter;

import 'package:desktop_drop/desktop_drop.dart';
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/composer_text.dart';
import '../../../infrastructure/platform/clipboard_paste.dart';
import '../../../infrastructure/state/models/network_credential.dart';
import '../../../shared/file_drag.dart';
import '../../../shared/layouts/shell_state.dart';
import '../../../shared/theme/app_theme.dart';
import '../../../shared/widgets/app_spinner.dart';
import '../../../shared/widgets/toast.dart';
import '../../../shared/widgets/typing_dots.dart';
import '../../agents/logic/agent_changes.dart';
import '../../agents/logic/agent_permissions.dart';
import '../../agents/logic/agent_routing.dart';
import '../../agents/logic/active_chat_agent.dart';
import '../../agents/logic/agent_catalog.dart';
import '../../agents/logic/agent_model_support.dart';
import '../../agents/logic/agent_status.dart';
import '../../agents/presentation/agent_picker.dart';
import '../../agents/presentation/agent_changes_bar.dart';
import '../../agents/presentation/agent_permission_card.dart';
import '../../agents/presentation/approval_picker.dart';
import '../../agents/presentation/agent_working_bubble.dart';
import '../../agents/presentation/running_services_bar.dart';
import '../../auth/logic/session_controller.dart';
import '../../playground/logic/chat_file.dart';
import '../../playground/logic/playground_models.dart';
import '../../playground/logic/playground_request.dart';
import '../../playground/presentation/chat_bubble.dart';
import '../../playground/presentation/no_model_yet.dart';
import '../../prompts/logic/prompt_slash.dart';
import '../../prompts/presentation/prompt_dialog.dart';
import '../../prompts/presentation/prompt_slash_menu.dart';
import '../../skills/presentation/save_skill_bar.dart';
import '../../terminal/logic/terminal_sessions_controller.dart';
import '../logic/active_workdir.dart';
import '../logic/chat_approval.dart';
import '../logic/chat_scope.dart';
import '../logic/chat_sessions_controller.dart';
import '../logic/composer_context.dart';
import '../logic/composer_file_request.dart';
import '../logic/composer_prefill.dart';
import '../logic/composer_snippet.dart';
import '../logic/conversation.dart';
import '../logic/file_attachments.dart';
import '../logic/file_mention.dart';
import 'goal_bar.dart';
import 'queued_follow_ups.dart';
import 'agent_handover_bar.dart';
import 'file_mention_menu.dart';
import 'chat_composer.dart';
import 'chat_header.dart';
import 'chat_minimap.dart';
import 'chat_starters.dart';
import 'grid_model_picker.dart';
import 'out_of_steps_bar.dart';
import 'plan_approve_bar.dart';

/// How close to the end (px) still counts as "at the bottom" — within this, new
/// messages auto-follow and the jump-to-latest button hides.
const double _atBottomThreshold = 120;

/// How many frames [_ChatViewState._snapToBottom] gets to converge on the real
/// end of a transcript it can only estimate. Six is a tenth of a second, and each
/// one narrows the estimate a lot; the cap is there so a chat that keeps growing
/// while we chase it ends the chase rather than the frame budget.
const int _snapFrames = 6;

/// How wide the conversation column gets on a big window. Long lines are hard to
/// read; the transcript and the composer share this so they line up.
///
/// Wider than the 760 it started at: on a big window that left a broad empty
/// margin either side, and the content — tables above all — was cramped into a
/// column far narrower than the room available.
///
/// This stays the *outer* bound, the one wide content is allowed to fill. Prose
/// is held to the narrower `proseWidth` (in `chat_bubble.dart`) inside it, so
/// widening this again for tables doesn't drag body copy back out to 110+
/// characters a line.
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

  /// The documents riding on the next message — read at attach time, so what
  /// goes out is what the file said when the user pointed at it.
  final List<ChatFile> _files = [];

  /// Runs of text the user picked out of a file and sent this way. They are
  /// folded into the message on the way out ([messageWithSnippets]), so the
  /// transcript shows what was actually asked.
  final List<ChatSnippet> _snippets = [];

  /// The `conversationId|projectId|gridId` the model field was last synced to,
  /// so switching chats restores that chat's model and switching grids drops to
  /// the new grid's first model — without clobbering a model being mid-typed.
  ///
  /// The project is part of the key because two *unsaved* chats are both a null
  /// conversation id: starting a new chat in another project would otherwise
  /// look like the same chat and keep the model of the project just left.
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

  /// True while [_setModelText] is *restoring* the field rather than carrying a
  /// pick the user made, so the change listener doesn't persist it.
  ///
  /// Without this, opening a chat looked exactly like choosing its model: every
  /// switch re-saved that conversation and rewrote the app's default model —
  /// two synchronous JSON writes on the UI thread, plus the rebuild each one
  /// sets off, for a selection nobody made.
  bool _restoring = false;

  @override
  void initState() {
    super.initState();
    // The picker is a plain TextEditingController; selecting a model won't
    // rebuild on its own. Refresh so the modality-driven UI (attach bar, send
    // gating, hints) tracks the selection.
    _model.addListener(_onModelChanged);
    // The slash menu and the prompts button both track what's typed, so rebuild
    // as the message changes.
    _scroll.addListener(_onScroll);
    // Reopening the section rebuilds this view; land on the latest turn rather
    // than stranding the user at the top of the transcript.
    WidgetsBinding.instance.addPostFrameCallback((_) => _snapToBottom());
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
    if (_restoring) return;
    _rememberModel();
  }

  /// Persist the selection once it's a real option (not a name being typed):
  /// onto the open chat, so leaving and returning restores *its* model rather
  /// than a default; and onto the chat's scope — its project, or the app's
  /// standing choice outside one — so the next chat started there defaults to it
  /// too.
  ///
  /// Only ever reached for a model the user picked — restoring a chat's own
  /// model on switch is not a choice, and treating it as one wrote both files on
  /// every switch (and quietly rewrote a chat whose model had gone offline).
  void _rememberModel() {
    final id = _model.text.trim();
    if (id.isEmpty || !_options.any((o) => o.id == id)) return;
    ref.read(chatScopePrefsProvider).setModel(id);
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
    String? projectId,
  ) {
    _options = options;
    final key = '${active?.id}|$projectId|$gridId';
    // A picker-driven grid switch just landed: honor the model the user chose
    // rather than resetting to this grid's default, then treat it as synced.
    final pending = _pendingPick;
    if (pending != null) {
      _pendingPick = null;
      _synced = true;
      _syncedKey = key;
      _setModelText(pending, fromUser: true);
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
      // The chat's own model, unless the agent answering now can't use it — a
      // chat last used on Claude Code reopening under Codex would otherwise come
      // back holding a pair that only fails.
      final hasStored =
          options.any((o) => o.id == stored) && _agentCanUse(stored);
      _setModelText(hasStored ? stored : _defaultModel(options));
      return;
    }
    if (options.isEmpty) return;
    if (_model.text.isEmpty) {
      _setModelText(_defaultModel(options));
      return;
    }
    // The agent can change while this grid's models are still in flight — an
    // install finishing, a grid handing the chat to another agent — and the
    // listener that repairs the pair then has no list to repair it against. Do
    // it again as soon as there is one, so the composer never settles on a pair
    // the grid would refuse.
    _retargetModel(ref.read(chatModelAgentProvider));
  }

  /// The model to fall back to when the conversation has none: the one this
  /// chat's scope last used — its project's, or the app's outside one — if this
  /// grid still offers it and the agent can answer with it, else the first
  /// option that pairs with the agent answering.
  String _defaultModel(List<PlaygroundModelOption> options) {
    // A grid that serves nothing this agent can use falls back to the whole
    // list: the composer still names what the grid has, and the picker's greyed
    // rows carry the reason — landing on an empty pill would say the grid was
    // empty, which is a different problem with a different fix.
    final usable = [
      for (final option in options)
        if (_agentCanUse(option.id)) option,
    ];
    final pool = usable.isEmpty ? options : usable;
    final saved = ref.read(chatScopeModelProvider);
    if (saved != null && pool.any((o) => o.id == saved)) return saved;
    return pool.isEmpty ? '' : pool.first.id;
  }

  /// Whether the agent that would answer can do so with [id] — true when no
  /// agent stands between the chat and the grid (see [chatModelAgentProvider]).
  bool _agentCanUse(String id) {
    final agent = ref.read(chatModelAgentProvider);
    return agent == null || agentSupportsModel(agent, id);
  }

  /// Move off a model [agent] can't answer with, onto the first one this grid
  /// serves that it can.
  ///
  /// The pairing is decided here rather than at Send because the composer shows
  /// both halves at once: leaving "Codex" beside `claude:opus` on screen makes
  /// the grid's refusal look like a bug in the model. Nothing usable here leaves
  /// the selection alone — the picker's rows say who is refusing, and swapping to
  /// a model that fails for another reason only moves the wall.
  void _retargetModel(AgentTool? agent) {
    if (agent == null) return;
    final current = _model.text.trim();
    if (current.isEmpty || agentSupportsModel(agent, current)) return;
    for (final option in _options) {
      if (!agentSupportsModel(agent, option.id)) continue;
      _setModelText(option.id, fromUser: true);
      return;
    }
  }

  /// Write [value] into the model field. [fromUser] marks a pick they actually
  /// made, which is persisted; a restore (a chat switch, a grid swap) leaves it
  /// false so [_rememberModel] stays out of it — see [_restoring].
  void _setModelText(String value, {bool fromUser = false}) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || _model.text == value) return;
      _restoring = !fromUser;
      _model.text = value;
      _restoring = false;
    });
  }

  /// Apply a pick from the unified grid+model picker: switch to [grid] when it
  /// differs (stashing the model so the re-sync keeps it), else just set the
  /// model on the current grid.
  void _pickGridModel(NetworkCredential grid, PlaygroundModelOption option) {
    final currentId = ref.read(selectedNetworkProvider)?.networkId;
    if (currentId == grid.networkId) {
      _setModelText(option.id, fromUser: true);
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
          // Selections ride *inside* the message rather than beside it: the turn
          // that gets persisted is then the turn that was asked, quotes and all,
          // instead of a bubble reading as a question about nothing.
          message: messageWithSnippets(message, _snippets),
          modality: modality,
          attachments: List.of(_attachments),
          files: List.of(_files),
          contexts: _captureTerminals(modality),
        );
    _message.clear();
    // The ✕ on a terminal chip belonged to the message just sent. The next one
    // starts with whatever is on screen offered again — which is the whole point
    // of the chips being derived rather than a list to curate.
    ref.read(dismissedTerminalsProvider.notifier).clear();
    if (_attachments.isNotEmpty || _files.isNotEmpty || _snippets.isNotEmpty) {
      setState(() {
        _attachments.clear();
        _files.clear();
        _snippets.clear();
      });
    }
  }

  /// Reads the terminals on screen, at the moment Send is pressed rather than
  /// when their chips appeared: the minute between opening a terminal and asking
  /// about it is usually the minute the thing being asked about happened.
  ///
  /// Nothing on a picture or video turn — those are made by the grid, which has
  /// no filesystem and nothing to say about a build log.
  List<ChatContext> _captureTerminals(PlaygroundModality modality) {
    if (modality != PlaygroundModality.text) return const [];
    return captureTerminalContexts(
      attached: ref.read(attachedTerminalsProvider),
      sessions: ref.read(terminalSessionsProvider),
    );
  }

  /// Attach whatever the user picks — pictures and documents in one list, since
  /// the button says "attach a file" and not "attach a picture". A cancelled
  /// picker is a no-op.
  Future<void> _attachFile() async {
    final paths = await pickAttachmentPaths();
    if (paths.isNotEmpty) await _attachPaths(paths);
  }

  /// ⌘V / Ctrl+V in the composer, on everything the clipboard might hold.
  ///
  /// A screenshot is the reason this exists: taking one and pressing paste is
  /// how people show an assistant what they're looking at, and until now the
  /// keystroke did nothing at all — Flutter's own clipboard reads text and
  /// nothing else. Copied files land the same way a drop does, and plain text is
  /// inserted where the cursor is, exactly as the field would have.
  Future<void> _paste() async {
    final paste = await readClipboardPaste();
    if (!mounted) return;
    switch (paste) {
      case PastedImage(:final bytes, :final filename):
        if (_attachments.length >= maxChatImages) {
          _sayOverflow([filename]);
          return;
        }
        setState(
          () => _attachments.add(
            MediaAttachment(filename: filename, bytes: bytes),
          ),
        );
      case PastedFiles(:final paths):
        await _attachPaths(paths);
      case PastedText(:final text):
        _insertIntoMessage(text);
      case PastedNothing():
        break;
    }
  }

  /// Handle a drag-and-drop onto the chat — the same sorting as the picker and
  /// the clipboard, since a file is a file however it arrived.
  ///
  /// Anything dragged out of a browser rather than off the desk arrives as a
  /// promise with no path on disk; those are read straight from the drop, so an
  /// image dragged from a web page still attaches instead of vanishing.
  Future<void> _addDroppedFiles(List<DropItem> items) async {
    final onDisk = [
      for (final item in items)
        if (item.path.trim().isNotEmpty) item.path,
    ];
    if (onDisk.isNotEmpty) await _attachPaths(onDisk);

    for (final item in items) {
      if (item.path.trim().isNotEmpty) continue;
      if (!isImageFilename(item.name)) continue;
      if (_attachments.length >= maxChatImages) continue;
      final bytes = await item.readAsBytes();
      if (!mounted) return;
      setState(
        () => _attachments.add(
          MediaAttachment(filename: item.name, bytes: bytes),
        ),
      );
    }
  }

  /// Sort [paths] into what the message can carry: pictures as thumbnails,
  /// documents as chips with their text read out, and anything the app can't
  /// open (a folder, a file it was refused) mentioned by path so the assistant
  /// still hears about it.
  Future<void> _attachPaths(Iterable<String> paths) async {
    final added = await readAttachments(
      paths,
      imageBudget: maxChatImages - _attachments.length,
      fileBudget: maxChatFiles - _files.length,
    );
    if (!mounted) return;
    if (added.images.isNotEmpty || added.files.isNotEmpty) {
      setState(() {
        _attachments.addAll(added.images);
        _files.addAll(added.files);
      });
    }
    if (added.paths.isNotEmpty) {
      _insertIntoMessage(pathsForMessage(added.paths));
    }
    _sayOverflow(added.overflow);
  }

  /// Put [paths] on the message because somebody asked for them by name.
  ///
  /// Documents only, and deliberately not [_attachPaths]: that path turns a
  /// picture into an image attachment, and a turn carrying an image goes to the
  /// grid API instead of the agent — "Add to chat" on a `.png` must not quietly
  /// change who answers. It also writes whatever it couldn't attach into the
  /// draft as text, which is not what a menu item promised to do.
  Future<void> _attachRequested(List<String> paths) async {
    final read = <ChatFile>[];
    final noRoom = <String>[];
    var room = maxChatFiles - _files.length;

    for (final path in paths) {
      if (_files.any((file) => file.path == path)) continue;
      if (read.any((file) => file.path == path)) continue;
      if (room <= 0) {
        noRoom.add(fileNameOf(path));
        continue;
      }
      final file = await readChatFile(path);
      if (file == null) continue;
      read.add(file);
      room--;
    }
    if (!mounted) return;

    if (read.isNotEmpty) setState(() => _files.addAll(read));
    if (noRoom.isNotEmpty) _sayOverflow(noRoom);
  }

  /// Take the selections a panel handed over.
  void _takeSnippets(List<ChatSnippet> offered) {
    final noRoom = <String>[];
    final taken = <ChatSnippet>[];
    for (final snippet in offered) {
      // The same run of text picked twice is one selection. Easy to do by
      // accident — right-click, miss the menu, right-click again.
      if (_snippets.contains(snippet) || taken.contains(snippet)) continue;
      if (_snippets.length + taken.length >= maxChatSnippets) {
        noRoom.add(snippet.name);
        continue;
      }
      taken.add(snippet);
    }

    if (taken.isNotEmpty) setState(() => _snippets.addAll(taken));
    if (noRoom.isEmpty) return;
    ToastScope.show(
      context,
      ToastSpec(
        message:
            '“${noRoom.first}” wasn’t added — a message holds up to '
            '$maxChatSnippets selections.',
        severity: ToastSeverity.warning,
      ),
    );
  }

  /// Say what didn't fit. Silence here is what made an attach that quietly did
  /// nothing look like a bug in the app.
  void _sayOverflow(List<String> overflow) {
    final message = attachmentOverflowMessage(overflow);
    if (message == null) return;
    ToastScope.show(
      context,
      ToastSpec(message: message, severity: ToastSeverity.warning),
    );
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

  /// Drop text into the message where the cursor is (or at the end): pasted
  /// text, and the paths of files dragged in from Finder that couldn't be
  /// attached. Paths are absolute, so a file outside the chat's folder rests on
  /// the agent's own file access.
  void _insertIntoMessage(String insert) {
    // `start`/`end`, not base/extent: a selection dragged right-to-left has its
    // base *after* its extent, and pasting over it must still replace it.
    final selection = _message.selection;
    final result = insertIntoField(
      _message.text,
      start: selection.start,
      end: selection.end,
      insert: insert,
    );
    _message.text = result.text;
    _message.selection = TextSelection.collapsed(offset: result.cursor);
  }

  void _scrollToBottom({bool animated = false}) {
    if (!_scroll.hasClients) return;
    final target = _scroll.position.maxScrollExtent;
    if (!animated) {
      // Already there: a jump would still fire the whole notification cascade
      // (both scroll listeners, a re-measure of the rail), and this runs after
      // every streamed token.
      if (_scroll.position.pixels != target) _scroll.jumpTo(target);
      return;
    }
    _scroll
        .animateTo(
          target,
          duration: const Duration(milliseconds: 220),
          curve: Curves.easeOut,
        )
        // This target is an estimate too, and the jump-to-latest button is only
        // up when the user is far enough away for it to be a poor one — so close
        // whatever gap is left once the ride is over, rather than landing them in
        // the middle of the history they asked to leave.
        .then((_) => _snapToBottom());
  }

  /// Land on the newest turn when arriving cold — opening the section, switching
  /// conversation — and hold there until the list stops revising how tall it is.
  ///
  /// A lazy `ListView` doesn't know the height of turns it hasn't built, so
  /// `maxScrollExtent` measured from the *top* of a long transcript is an
  /// estimate: the average height of what's laid out, times the turns left. One
  /// jump lands wherever that guess pointed, and when the revised extent comes
  /// back larger nothing corrects it — a chat whose answers run long opened
  /// parked in its own middle, wearing a "jump to latest" button the user hadn't
  /// scrolled away from. Each jump builds the turns around its target and
  /// sharpens the estimate, so re-assert until the target stops moving, capped at
  /// [_snapFrames] so a transcript still streaming can't be chased forever.
  ///
  /// [_scrollToBottom] stays the one to call while following a live reply: down
  /// there the turns below are built, the extent is exact, and one jump is right.
  void _snapToBottom([int frames = _snapFrames]) {
    if (!mounted || !_scroll.hasClients) return;
    final target = _scroll.position.maxScrollExtent;
    if (_scroll.position.pixels != target) _scroll.jumpTo(target);
    if (frames <= 0) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_scroll.hasClients) return;
      final pos = _scroll.position;
      // Moved off our target: either the user grabbed the list — following them
      // is the point, not fighting them — or the extent shrank and the position
      // was clamped to the real bottom, which is where we were headed anyway.
      if (pos.pixels != target) return;
      // The estimate held: this is the bottom.
      if (pos.maxScrollExtent <= target) return;
      _snapToBottom(frames - 1);
    });
  }

  @override
  Widget build(BuildContext context) {
    // Watched field by field, not as one object. The state changes on **every
    // streamed token** (the phase carries the growing answer), and a whole-state
    // watch rebuilt this entire tree — composer, pickers, menus and all — 122
    // times for a 120-token reply where these selects fire twice. What genuinely
    // moves per token is the in-flight bubble, and it watches for itself (see
    // [_TrailingBubble]).
    final active = ref.watch(chatSessionsProvider.select((s) => s.active));
    final activeId = ref.watch(chatSessionsProvider.select((s) => s.activeId));
    final sending = ref.watch(chatSessionsProvider.select((s) => s.sending));
    final error = ref.watch(chatSessionsProvider.select((s) => s.error));
    final openProject = ref.watch(openChatProjectProvider);
    final options = ref.watch(playgroundModelsProvider);
    // Still resolving means waiting on the *first* answer from either source —
    // see [playgroundModelsResolvingProvider] for why a later poll must not
    // count.
    final loadingModels = ref.watch(playgroundModelsResolvingProvider);

    // A panel beside the chat — Review, today — asking for a message to be
    // typed here. It goes in the box exactly as a starter would, so the user
    // can edit it and pick who answers before anything is sent.
    ref.listen(composerPrefillProvider, (_, text) {
      if (text == null) return;
      _useStarter(text);
      ref.read(composerPrefillProvider.notifier).taken();
    });

    // And a panel saying what it is *looking at* — a Files tab, today. That
    // rides on the message as an ordinary attachment chip, so asking about the
    // file on screen doesn't mean attaching it a second time by hand.
    // A panel asking for a file — "Add to chat" out of a right-click menu.
    ref.listen(composerFileRequestProvider, (_, paths) {
      if (paths.isEmpty) return;
      ref.read(composerFileRequestProvider.notifier).taken();
      unawaited(_attachRequested(paths));
    });

    // A run of text picked out of a file.
    ref.listen(composerSnippetProvider, (_, offered) {
      if (offered.isEmpty) return;
      ref.read(composerSnippetProvider.notifier).taken();
      _takeSnippets(offered);
    });

    _syncModelField(active, options, widget.network.networkId, openProject?.id);

    // The undo bar speaks for the chat on screen, so tell it which one that is.
    // The snapshots themselves are kept per conversation and outlive the switch:
    // an agent finishing after the user moved on files its edits under the chat
    // that asked for them, and they're waiting there on the way back. Deferred
    // because writing a provider during build would throw, and only when the
    // answer moved — this build runs on every keystroke and streamed token.
    if (ref.read(agentChangesScopeProvider) != activeId) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!context.mounted) return;
        ref.read(agentChangesScopeProvider.notifier).show(activeId);
      });
    }

    // Switching the assistant moves the model with it when the two can't work
    // together, so "who answers" and "with what" are never a pair the grid would
    // refuse. Listened for rather than derived: the model is the user's to keep
    // whenever it still works, and only a change of agent can invalidate it.
    ref.listen(chatModelAgentProvider, (_, agent) => _retargetModel(agent));

    // Follow new turns while the user is already at the bottom, and always snap
    // down after switching conversations so a reopened chat shows its latest
    // message — but don't yank a user who scrolled up to read history.
    ref.listen(chatSessionsProvider, (prev, next) {
      final switched = prev?.activeId != next.activeId;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        // A switch arrives at the top of a transcript nothing has measured yet,
        // so its end has to be converged on; following a live reply is already
        // at the end, where one jump is exact.
        if (switched) {
          _snapToBottom();
          return;
        }
        if (_atBottom) _scrollToBottom();
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
    final messages = active?.messages ?? const <ChatMessage>[];
    // The "agent is working" feed and the permission card read one shared,
    // app-wide state, but only the chat whose agent turn is actually running
    // owns it — an agent chat still queued behind another must show its own
    // waiting cue, not borrow the running chat's steps (or its permission).
    final thisChatIsRunning = ref.watch(
      chatSessionsProvider.select(
        (s) => s.activeId != null && s.activeId == s.runningAgentId,
      ),
    );
    // *Whether* there is an in-flight bubble, not what it says: this answers
    // once when the turn starts and once when it ends, while the bubble's own
    // contents change with every token.
    final hasTrailing = ref.watch(
      chatSessionsProvider.select((s) => _bubbleShows(s.phase, agentMode)),
    );
    final isNewChat = messages.isEmpty && !sending;

    // The header naming this conversation lives in the top bar, so it shares
    // one row with the grid pill instead of sitting in a strip of its own.
    // Both conditions that gate it are only knowable here — the starters
    // screen and the no-model nudge are stand-ins for a conversation that
    // isn't there yet, and a header over either would name nothing — so
    // publish the answer rather than have the shell re-derive it. Deferred:
    // writing a provider during build would throw — and deferred only when the
    // answer actually moved, since this build runs on every keystroke and every
    // streamed token, and a callback per frame to rewrite an unchanged value is
    // work the frame doesn't owe.
    final wantsHeader = !noModel && !isNewChat;
    if (ref.read(chatHeaderVisibleProvider) != wantsHeader) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!context.mounted) return;
        ref.read(chatHeaderVisibleProvider.notifier).set(wantsHeader);
      });
    }

    // The agent has stopped and is asking before it touches this computer. Only
    // the chat whose turn is running owns that request — on any other chat the
    // card would be asking about work the user can't see.
    final permission = thisChatIsRunning
        ? ref.watch(agentPermissionProvider)
        : null;
    // Read here, not down in the composer's builder: that builder runs when the
    // text controller notifies, which is outside this widget's own build, and
    // `ref.watch` may only be called during it.
    final workdir = ref.watch(activeChatWorkdirProvider);
    final approval = ref.watch(chatApprovalModeProvider);
    // Two ways a file arrives by hand, one landing. [DropTarget] is the one the
    // system hands us — a file dragged in from Finder, which Flutter never sees
    // as a drag at all. [DragTarget] is a file dragged out of the Files panel,
    // which never leaves the app and so is invisible to the system.
    //
    // The whole pane takes them, not just the composer: it is where the Finder
    // drop already lands, and one window teaching two rules for one gesture is
    // worse than a target that is bigger than it strictly needs to be.
    return DragTarget<FileDrag>(
      onAcceptWithDetails: (details) =>
          // The same call the panel's "Add to chat" ends in, so a dropped file
          // is de-duplicated against what is already attached and counted
          // against the same budget.
          unawaited(_attachRequested([details.data.path])),
      builder: (_, candidates, _) => DropTarget(
        onDragEntered: (_) => setState(() => _dragging = true),
        onDragExited: (_) => setState(() => _dragging = false),
        onDragDone: (details) {
          setState(() => _dragging = false);
          unawaited(_addDroppedFiles(details.files));
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
                          // Name the project a new chat is being composed in, so
                          // its empty state reads "…in <project>?" rather than the
                          // same blank greeting a loose chat shows.
                          projectName: openProject?.name,
                          onPick: _useStarter,
                        )
                      : _Transcript(
                          scroll: _scroll,
                          messages: messages,
                          trailing: hasTrailing
                              ? _TrailingBubble(agentMode: agentMode)
                              : null,
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
                      // Everything that answers to what is being typed lives under
                      // here, so a keystroke rebuilds the composer and not the
                      // transcript above it. The controller is the listenable —
                      // it notifies on text *and* caret moves, which is what the
                      // `@`-mention menu reads.
                      child: ListenableBuilder(
                        listenable: _message,
                        builder: (context, _) {
                          // "There is something to send", not "the chat is free":
                          // a turn already in flight no longer blocks Send, it
                          // queues what is typed behind it. The text check lives
                          // here rather than in `_send` so the button and the Stop
                          // beside it agree with what pressing them would do.
                          final canSend =
                              !noModel &&
                              _message.text.trim().isNotEmpty &&
                              (!needsImage || _attachments.isNotEmpty);
                          // A leading "/" (with no space yet) opens the
                          // saved-prompt menu; an "@" token opens the file menu.
                          // Only one shows at a time, prompts first.
                          final slash = sending
                              ? null
                              : slashQuery(_message.text);
                          final cursor = _message.selection.baseOffset;
                          final mention =
                              (sending || slash != null || cursor < 0)
                              ? null
                              : activeMention(_message.text, cursor);
                          return Column(
                            mainAxisSize: MainAxisSize.min,
                            crossAxisAlignment: CrossAxisAlignment.stretch,
                            children: [
                              const AgentHandoverBar(),
                              const PlanApproveBar(),
                              // Above the changes bar: "it stopped early" is the
                              // more urgent of the two, and the files it did
                              // change are still there to review afterwards.
                              const OutOfStepsBar(),
                              const AgentChangesBar(),
                              const GoalBar(),
                              const RunningServicesBar(),
                              const SaveSkillBar(),
                              const QueuedFollowUps(),
                              if (slash != null)
                                PromptSlashMenu(
                                  query: slash,
                                  onPick: _insertPrompt,
                                )
                              else if (mention != null)
                                FileMentionMenu(
                                  workdir: workdir,
                                  query: mention.query,
                                  onPick: _insertMention,
                                ),
                              ComposerSection(
                                messageController: _message,
                                attachments: _attachments,
                                files: _files,
                                snippets: _snippets,
                                // Only on a turn a model can read them on: a
                                // picture request goes to the grid, and a terminal
                                // offered there would be a chip that promises
                                // something the turn can't carry.
                                terminals: modality == PlaygroundModality.text
                                    ? ref.watch(attachedTerminalsProvider)
                                    : const [],
                                modality: modality,
                                needsImage: needsImage,
                                sending: sending,
                                canSend: canSend,
                                error: error,
                                // Any turn the agent couldn't finish gets the way out
                                // offered beside it. Keying this to one known message
                                // meant the failure people actually hit (a 503 from
                                // the grid) arrived with no button at all — and the
                                // message is the wrong thing to hang it on anyway:
                                // what makes the swap worth offering is that an agent
                                // failed, not which sentence it failed with.
                                errorAction: agentMode
                                    ? const SwitchAgentButton()
                                    : null,
                                // Only the agent can touch this computer — a picture is made
                                // by the grid, so there'd be nothing to approve.
                                approvalPicker: agentMode
                                    ? ApprovalPicker(
                                        value: approval,
                                        onChanged: ref
                                            .read(chatSessionsProvider.notifier)
                                            .setApproval,
                                      )
                                    : null,
                                // Which agent answers, beside the model it runs — only
                                // when an agent is the one answering this turn.
                                agentPicker: agentMode
                                    ? const AgentPicker()
                                    : null,
                                modelPicker: GridModelPicker(
                                  currentModelId: _model.text,
                                  onSelect: _pickGridModel,
                                ),
                                onAddAttachment: (a) =>
                                    setState(() => _attachments.add(a)),
                                onAttachFile: () => unawaited(_attachFile()),
                                onPaste: () => unawaited(_paste()),
                                onRemoveAttachment: (i) =>
                                    setState(() => _attachments.removeAt(i)),
                                onRemoveFile: (i) =>
                                    setState(() => _files.removeAt(i)),
                                onRemoveSnippets: () =>
                                    setState(_snippets.clear),
                                onRemoveTerminal: (tabId) => ref
                                    .read(dismissedTerminalsProvider.notifier)
                                    .dismiss(tabId),
                                onOpenPrompts: _promptsButton,
                                promptsSaveInput: _message.text
                                    .trim()
                                    .isNotEmpty,
                                onSend: () => _send(modality),
                                onStop: () => ref
                                    .read(chatSessionsProvider.notifier)
                                    .stop(),
                              ),
                            ],
                          );
                        },
                      ),
                    ),
                  ),
                ),
              ],
            ),
            // One hint for both, so the answer to "will this land?" looks the
            // same whichever drag the file came in on. `candidates` is the
            // in-app one: the target rebuilds as a file enters and leaves it, so
            // it needs no state of its own the way the system drop does.
            if (_dragging || candidates.isNotEmpty) const _DropHint(),
          ],
        ),
      ),
    );
  }

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

/// Whether the in-flight turn draws a bubble after the transcript at all.
///
/// Split from [_TrailingBubble] because the two answers move at completely
/// different rates: *whether* there is a bubble changes once when the turn
/// starts and once when it ends, while *what it says* changes with every
/// streamed token. Keeping them apart is what stops the screen around the
/// transcript rebuilding 122 times for a 120-token reply.
bool _bubbleShows(SendPhase phase, bool agentMode) => switch (phase) {
  SendGenerating() || SendStreaming() => true,
  SendBusy() => agentMode,
  _ => false,
};

/// The bubble appended after the transcript for the in-flight turn: the media
/// progress bar while a generation streams, the answer growing live as it
/// streams in, or a spinner while the agent works before its first token.
///
/// Watches the phase itself so the growing text rebuilds this bubble and
/// nothing else. [running] is whether this chat holds the agent's live turn:
/// only then does the working bubble (which reads the shared activity feed)
/// belong to it — an agent chat still queued behind another shows a plain
/// waiting cue instead.
class _TrailingBubble extends ConsumerWidget {
  const _TrailingBubble({required this.agentMode});

  /// Whether an agent is answering this turn — a media turn bypasses it, so the
  /// bubble shows progress rather than "the agent is working".
  final bool agentMode;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final phase = ref.watch(chatSessionsProvider.select((s) => s.phase));
    final running = ref.watch(
      chatSessionsProvider.select(
        (s) => s.activeId != null && s.activeId == s.runningAgentId,
      ),
    );
    return switch (phase) {
      SendGenerating g => GeneratingBubble(phase: g),
      SendStreaming(:final text) when text.isNotEmpty => _StreamingReply(
        text: text,
        showActivity: agentMode,
      ),
      SendStreaming() => const AgentWorkingBubble(),
      SendBusy() when agentMode && running => const AgentWorkingBubble(),
      SendBusy() when agentMode => const _QueuedBubble(),
      _ => const SizedBox.shrink(),
    };
  }
}

/// The reply as it streams in: the partial text, exactly as [ChatBubble] draws
/// the finished turn.
///
/// A plain model reply carries the [TypingDots] cue under it so a pause between
/// bursts reads as "still going", not "stopped". An agent turn shows the live
/// step feed instead — which already carries its own spinner (a running step,
/// or the "Thinking…" line) — so the dots would just say the same thing twice
/// and are dropped.
///
/// Reuses [ChatBubble] rather than re-laying-out the text, so a half-streamed
/// reply and the same reply once committed are pixel-identical — no reflow at
/// the moment the cue drops away. The cue sits at the content's left edge (the
/// assistant column starts there), a touch below.
class _StreamingReply extends StatelessWidget {
  const _StreamingReply({required this.text, this.showActivity = false});

  final String text;

  /// Whether to show the live step feed under the text. On for an agent turn,
  /// so the commands it keeps running after its first sentence stay visible
  /// instead of disappearing behind the dots; off for a plain model reply, which
  /// has no steps to show.
  final bool showActivity;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        ChatBubble(
          message: ChatMessage(role: ChatRole.assistant, text: text),
        ),
        // Agent turn: the feed's own spinner is the "still going" cue, so no
        // dots. Plain reply: no feed, so the dots carry it.
        if (showActivity)
          const AgentActivityFeed()
        else
          const Padding(
            padding: EdgeInsets.only(left: 2, bottom: 10),
            child: TypingDots(),
          ),
      ],
    );
  }
}

/// Shown on an agent chat whose turn is queued behind another that's still
/// running — the local agent answers one at a time.
///
/// Deliberately NOT [AgentWorkingBubble]: that bubble reads the shared activity
/// feed, which belongs to the chat actually running, so it would show this chat
/// another chat's steps. This says, honestly, that the assistant is finishing
/// something else first — a spinner and one line, no borrowed feed.
class _QueuedBubble extends StatelessWidget {
  const _QueuedBubble();

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Align(
      alignment: Alignment.centerLeft,
      child: Container(
        margin: const EdgeInsets.symmetric(vertical: 4),
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
        decoration: BoxDecoration(
          color: theme.colorScheme.surfaceContainerHighest,
          borderRadius: BorderRadius.circular(12),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            const AppSpinner(),
            const SizedBox(width: 10),
            Text(
              'Finishing another chat first…',
              style: theme.textTheme.bodyMedium,
            ),
          ],
        ),
      ),
    );
  }
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
  /// One key per message, so the minimap can scroll a turn into view by its own
  /// rendered position — the turns are wildly uneven in height (a one-line
  /// question against a long reply), so there's no arithmetic that maps an index
  /// to an offset.
  ///
  /// Keyed by the message rather than by its index: an index-keyed global key
  /// would be handed to a *different* turn the moment the user switches chats,
  /// which is exactly when both the old and new widget are briefly in flight.
  ///
  /// Identity, not equality: two turns holding the same text are still two
  /// turns, and sharing one global key between them would put a duplicate in
  /// the tree.
  final _itemKeys = Map<ChatMessage, GlobalKey>.identity();

  /// The built row for each turn, so a rebuild of the view above — a keystroke
  /// in the composer, a streamed token, a chat switch — doesn't re-derive every
  /// visible turn. Rebuilding one means re-splitting its text into segments and
  /// tables and rebuilding its markdown stylesheet; returning the identical
  /// widget instead lets Flutter skip the subtree outright.
  ///
  /// Identity-keyed for the same reason as [_itemKeys] — a row carries one.
  final _rows = Map<ChatMessage, Widget>.identity();

  /// The rail's ticks, derived once per transcript rather than per build.
  ///
  /// [minimapMarks] walks every turn and cuts a preview from each, so it scales
  /// with the *whole* conversation's text — and this build runs on every
  /// keystroke in the composer. Null until the first build that needs it.
  List<MinimapMark>? _marks;

  /// The message index the rail marks as "where you are", or null before the
  /// first frame has measured anything.
  int? _currentIndex;

  /// Whether the transcript is long enough to be worth a rail.
  bool _railVisible = false;

  GlobalKey _keyFor(ChatMessage message) =>
      _itemKeys.putIfAbsent(message, GlobalKey.new);

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
    if (old.messages != widget.messages) _onTranscriptChanged();
    // A new turn changes the content's height, which can cross the rail's
    // threshold — and lands a new message to mark. Re-measure once it's laid out.
    if (old.messages.length != widget.messages.length) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _onScroll());
    }
  }

  /// Drop what was derived from the old transcript: the rows and keys of turns
  /// that are no longer in it — a chat switch replaces the lot — and the rail's
  /// ticks. Appending a turn keeps every earlier one's row and key, since the
  /// messages themselves are carried over.
  void _onTranscriptChanged() {
    final kept = Set<ChatMessage>.identity()..addAll(widget.messages);
    _rows.removeWhere((message, _) => !kept.contains(message));
    _itemKeys.removeWhere((message, _) => !kept.contains(message));
    _marks = null;
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
    //
    // Only worth measuring while the rail is up: the mark is the one thing that
    // reads it, and walking every built turn on each scroll tick of a chat with
    // no rail bought nothing.
    final current = !visible
        ? _currentIndex
        : atEnd
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
      final itemContext = _itemKeys[widget.messages[i]]?.currentContext;
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

  /// The transcript row for [message] — built once and handed back unchanged on
  /// every later rebuild, so Flutter skips the whole subtree instead of
  /// re-deriving markdown the user is already looking at.
  Widget _turn(ChatMessage message) => _rows[message] ??= _TurnColumn(
    key: _keyFor(message),
    child: ChatBubble(message: message),
  );

  /// Bring message [index] to the top of the viewport. Built turns scroll via
  /// their key; one that's been recycled out of the lazy list has no context, so
  /// it falls back to an estimate from its position in the transcript.
  void _jumpTo(int index) {
    // The rail is painted from the previous build's marks, so a tap that lands
    // just after the transcript shrank (a chat switch) can name a turn that's
    // gone — and the lookup below indexes the list to find its key.
    if (index < 0 || index >= widget.messages.length) return;
    final context = _itemKeys[widget.messages[index]]?.currentContext;
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

  /// Take any open tooltip down the moment the transcript starts moving.
  ///
  /// A tooltip has no idea the thing it points at is scrolling away — it stays
  /// pinned where it opened, over rows it no longer describes. And one left open
  /// across a scroll is how the app froze on 2026-08-06: Flutter hit-tests the
  /// tooltip's overlay before that overlay has been laid out, which throws inside
  /// the mouse tracker's own update and then re-throws on every frame after.
  ///
  /// Returns false — the notification is still the scrollbar's business too.
  bool _dismissTooltips(ScrollStartNotification _) {
    // A scroll can begin *during* layout (new content dimensions handing the
    // position to a ballistic activity), and dismissing rebuilds the tooltip's
    // state — which that phase forbids. Wait out the frame when we're in one.
    if (SchedulerBinding.instance.schedulerPhase ==
        SchedulerPhase.persistentCallbacks) {
      WidgetsBinding.instance.addPostFrameCallback(
        (_) => Tooltip.dismissAllToolTips(),
      );
      return false;
    }
    Tooltip.dismissAllToolTips();
    return false;
  }

  @override
  Widget build(BuildContext context) {
    final count = widget.messages.length + (widget.trailing != null ? 1 : 0);
    return Stack(
      children: [
        NotificationListener<ScrollStartNotification>(
          onNotification: _dismissTooltips,
          child: ListView.builder(
            controller: widget.scroll,
            // No horizontal padding: the list spans the pane so its scrollbar
            // sits on the window edge. The column below insets its own content.
            padding: const EdgeInsets.symmetric(vertical: 18),
            itemCount: count,
            itemBuilder: (context, i) => i < widget.messages.length
                ? _turn(widget.messages[i])
                // Not cached: the in-flight bubble is what changes on every
                // streamed token, which is the whole reason the turns above it
                // must not.
                : _TurnColumn(
                    child: widget.trailing ?? const SizedBox.shrink(),
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
              marks: _marks ??= minimapMarks(widget.messages),
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

/// One row of the transcript: a turn (or the in-flight bubble) held to the
/// conversation column and optically centred in the pane.
///
/// The list spans the whole pane so its scrollbar rides the window edge, so the
/// measure has to be applied per row rather than by boxing the list.
class _TurnColumn extends StatelessWidget {
  const _TurnColumn({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) => Center(
    child: ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: _columnWidth),
      child: Padding(
        // The rail's width on the left, mirrored on the right, so the column
        // stays optically centred instead of nudged off-axis.
        padding: const EdgeInsets.symmetric(horizontal: chatMinimapWidth),
        child: child,
      ),
    ),
  );
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
                        fontWeight: AppFont.medium,
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
