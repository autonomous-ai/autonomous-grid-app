import 'dart:async';
import 'dart:ui' show ImageFilter;

import 'package:desktop_drop/desktop_drop.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/composer_text.dart';
import '../../../infrastructure/platform/clipboard_paste.dart';
import '../../../infrastructure/state/models/network_credential.dart';
import '../../../shared/chat_drop.dart';
import '../../../shared/layouts/shell_state.dart';
import '../../../shared/theme/app_theme.dart';
import '../../../shared/widgets/toast.dart';
import '../../../shared/widgets/typing_dots.dart';
import '../../agents/logic/agent_chat_scope.dart';
import '../../agents/logic/agent_permissions.dart';
import '../../agents/logic/agent_routing.dart';
import '../../agents/logic/active_chat_agent.dart';
import '../../agents/logic/agent_catalog.dart';
import '../../agents/logic/agent_model_support.dart';
import '../../agents/logic/agent_providers.dart';
import '../../agents/logic/agent_status.dart';
import '../../agents/presentation/agent_picker.dart';
import '../../agents/presentation/agent_permission_card.dart';
import '../../agents/presentation/approval_picker.dart';
import '../../agents/presentation/agent_working_bubble.dart';
import '../../auth/logic/session_controller.dart';
import '../../playground/logic/chat_file.dart';
import '../../playground/logic/playground_models.dart';
import '../../playground/logic/playground_request.dart';
import '../../playground/presentation/chat_bubble.dart';
import '../../playground/presentation/chat_minimap.dart';
import '../../playground/presentation/message_content.dart';
import '../../playground/presentation/no_model_yet.dart';
import '../../playground/presentation/transcript_view.dart';
import '../logic/commands/chat_command.dart';
import 'command_slash_menu.dart';
import 'composer_status.dart';
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
import 'queued_follow_ups.dart';
import '../../../shared/widgets/composer_buttons.dart';
import '../../agents/logic/agent_steering.dart';
import 'agent_handover_bar.dart';
import 'agent_questions_card.dart';
import 'file_mention_menu.dart';
import 'chat_composer.dart';
import 'chat_header.dart';
import 'chat_starters.dart';
import 'grid_model_picker.dart';
import 'chat_event_rows.dart';
import 'out_of_steps_bar.dart';
import 'plan_approve_bar.dart';

/// How many frames [_ChatViewState._snapToBottom] gets to converge on the real
/// end of a transcript it can only estimate. Six is a tenth of a second, and each
/// one narrows the estimate a lot; the cap is there so a chat that keeps growing
/// while we chase it ends the chase rather than the frame budget.
const int _snapFrames = 6;

const double _composerWidth = 1020;

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

  /// The message field's focus, held here so picking a command out of the `/`
  /// menu can hand the caret straight back to the box it half-filled.
  final _composerFocus = FocusNode();
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
    // The slash menu tracks what's typed, so rebuild as the message changes.
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
    _composerFocus.dispose();
    _scroll.dispose();
    super.dispose();
  }

  void _onScroll() {
    if (!_scroll.hasClients) return;
    final pos = _scroll.position;
    final atBottom = pos.pixels >= pos.maxScrollExtent - kAtBottomThreshold;
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
      // A brand-new plain chat keeps the model you were just using rather than
      // snapping back to the grid's default. "New chat" beside a DeepSeek chat
      // should open on DeepSeek, not on the auto-router — and persisting it (as
      // the standing choice, since there's no project) makes the *next* new
      // chat land there too, which is the whole of "default to what I last
      // picked". Scoped to a project-less chat so a project keeps its own
      // remembered model; an existing chat (active != null) still restores its.
      if (active == null && projectId == null) {
        final current = _model.text.trim();
        if (current.isNotEmpty &&
            options.any((o) => o.id == current) &&
            _agentCanUse(current)) {
          // Deferred: this runs inside build(), and _rememberModel writes a
          // provider. The field already shows `current`, so there's nothing to
          // set — only to remember.
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (mounted) _rememberModel();
          });
          return;
        }
      }
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

  /// The option matching the model field, or null when the id isn't in the
  /// list (the list hasn't landed, or the user typed an id by hand). Read for
  /// vision capability — a model the list doesn't know can't be trusted to
  /// read images.
  PlaygroundModelOption? _selectedOption(List<PlaygroundModelOption> options) {
    final id = _model.text.trim();
    if (id.isEmpty) return null;
    for (final option in options) {
      if (option.id == id) return option;
    }
    return null;
  }

  void _send(PlaygroundModality modality) {
    final message = _message.text.trim();
    if (message.isEmpty) return;
    // A command the app owns is performed, not sent: `/clear` reaching an
    // assistant as text is issue #13, and every agent would answer it with a
    // paragraph about clearing.
    final command = parseChatCommand(message);
    if (command != null) {
      _runCommand(command);
      return;
    }
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
    // The terminals belonged to the message just sent. The next one starts
    // empty, like every other part of a draft: a terminal is put on a message
    // deliberately, so the app must not go on quoting it into every message
    // after.
    ref.read(attachedTerminalsProvider.notifier).clear();
    _clearDraft();
  }

  /// Everything hanging off the composer beside the text, by name — what a
  /// notice about it has to be able to point at.
  List<String> get _draftNames => [
    for (final attachment in _attachments) attachment.filename,
    for (final file in _files) file.name,
    for (final snippet in _snippets) snippet.name,
  ];

  /// Take the pictures, files and quoted selections off the composer. They
  /// belonged to the line that just left it; kept, they ride onto the next
  /// message the user never meant to put them on.
  void _clearDraft() {
    if (_attachments.isEmpty && _files.isEmpty && _snippets.isEmpty) return;
    setState(() {
      _attachments.clear();
      _files.clear();
      _snippets.clear();
    });
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

  /// What picking [command] out of the `/` menu does: a command that needs
  /// words is written into the composer for the user to finish, and one that
  /// doesn't simply runs.
  ///
  /// Picking `/goal` used to run it bare, which is how you *ask for its
  /// status* — so clicking "Keep working until something is true" answered
  /// "No goal set." and did nothing else.
  void _pickCommand(ChatCommand command) {
    if (!command.takesArgument) {
      unawaited(_runCommand((command: command, argument: '')));
      return;
    }
    final line = '${command.slash} ';
    _message.text = line;
    _message.selection = TextSelection.collapsed(offset: line.length);
    // Clicking the row took the focus out of the field, so half a line would
    // be sitting there with the caret nowhere near it.
    _composerFocus.requestFocus();
  }

  /// Run [call] and empty the composer — the command *was* the message, its
  /// attachments included.
  ///
  /// Some commands take a moment (a summary is a model call), so what they have
  /// to say arrives as a toast rather than as a return value nobody sees.
  ///
  /// The picked model rides along: `/goal` and `/loop` typed into a blank
  /// composer start the chat themselves, and it answers with what the picker is
  /// showing — the same model an ordinary message would have gone out on.
  Future<void> _runCommand(ChatCommandCall call) async {
    _message.clear();
    // The attachments were part of that line too, and a command carries words
    // only ([ChatCommand.draftDropReason]) — so they come off with it, and are
    // named on the way out rather than left sitting under a composer the user
    // has already emptied.
    if (call.command.draftDropReason != null) {
      final dropped = droppedDraftMessage(call.command, _draftNames);
      _clearDraft();
      if (dropped != null) {
        ToastScope.show(
          context,
          ToastSpec(message: dropped, severity: ToastSeverity.warning),
        );
      }
    }
    final outcome = await ref
        .read(chatSessionsProvider.notifier)
        .runCommand(call, model: _model.text.trim());
    if (outcome == null || !mounted) return;
    ToastScope.show(
      context,
      ToastSpec(
        message: outcome.message,
        severity: outcome.failed ? ToastSeverity.error : ToastSeverity.success,
      ),
    );
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

  /// Follow a streamed redraw that grew the transcript **outside** a state
  /// change, so the newest words don't end up below the fold.
  ///
  /// The listener at the top of [build] is what normally keeps a live reply in
  /// view, and it works because it measures *after* the frame the new text was
  /// laid out in. A throttled redraw ([_StreamingReply]) breaks that pairing: it
  /// lands on its own timer, tens of milliseconds after the state change whose
  /// follow-up scroll has already measured the old height. Nothing else covers
  /// it — a grown `maxScrollExtent` alone does not notify a `ScrollController`,
  /// so `_onScroll` never runs and `_atBottom` is never even re-read. Left
  /// unpaired, a paragraph drawn just before the agent went off to run a command
  /// sat off-screen for the length of that command, with no jump-to-latest cue
  /// (`_atBottom` being stale-true is exactly what hides the button).
  void _followRedraw() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_atBottom) return;
      _scrollToBottom();
    });
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
    // Whether a message typed right now reaches the agent mid-answer or waits
    // for the next turn — the two are different promises, and Send says which.
    final steerable = ref.watch(canSteerChatProvider(activeId));
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
    if (ref.read(agentChatScopeProvider) != activeId) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!context.mounted) return;
        ref.read(agentChatScopeProvider.notifier).show(activeId);
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
    final agentInstalled = ref.watch(anyAgentInstalledProvider);
    final agentMode = agentAnswersTurn(
      modality: modality,
      hasAttachments: _attachments.isNotEmpty,
      agentInstalled: agentInstalled,
    );
    final needsImage = modality == PlaygroundModality.video;
    // An image pasted into a chat whose model can't read images. Locked until
    // the user switches to a vision-capable text model (or drops the image): a
    // text model without vision would reject the send, so the app asks for the
    // switch before the relay does.
    final selectedModel = _selectedOption(options);
    final visionLocked =
        !noModel &&
        modality == PlaygroundModality.text &&
        _attachments.isNotEmpty &&
        (selectedModel == null || !selectedModel.vision);
    // Nothing to send to while this grid has no model: the composer stays for
    // its model pill (the way out), but Send would have nowhere to go.
    final messages = active?.messages ?? const <ChatMessage>[];
    final compaction = active?.compaction;
    // A goal or a loop that has finished is drawn where it finished, the same
    // way a compaction is. While either is still running it says so on the
    // status line under the composer instead ([ComposerStatus]).
    final goal = active?.goal;
    final loop = active?.loop;
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

    // The agent has stopped and is asking before it touches this computer. Read
    // for the open chat by name: several turns can be waiting on the user at
    // once, and each chat shows the question its own agent asked.
    final permission = ref.watch(agentPermissionProvider(activeId));
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
    return DragTarget<ChatDrop>(
      onAcceptWithDetails: (details) => switch (details.data) {
        // The same call the panel's "Add to chat" ends in, so a dropped file
        // is de-duplicated against what is already attached and counted
        // against the same budget.
        FileDrop(:final path) => unawaited(_attachRequested([path])),
        TerminalDrop(:final tabId, :final label) =>
          ref
              .read(attachedTerminalsProvider.notifier)
              .attach(tabId: tabId, label: label),
      },
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
                      : TranscriptView(
                          scroll: _scroll,
                          rows: [
                            for (var i = 0; i < messages.length; i++) ...[
                              TranscriptRow(
                                // A committed message is immutable and carried
                                // across rebuilds by the controller, so its own
                                // identity is both a stable scroll key and a
                                // content key — it never changes in place.
                                scrollId: messages[i],
                                cacheId: messages[i],
                                builder: (_) =>
                                    ChatBubble(message: messages[i]),
                              ),
                              // The turn that handed a goal over, marked once
                              // under the user's own message.
                              if (goal != null && goal.startedAfter == i + 1)
                                TranscriptRow(
                                  // Keyed on the turn, not on the goal: a goal
                                  // object is replaced on every update, and an
                                  // id that changed with it would move the
                                  // scroll anchor under the reader each round.
                                  scrollId: 'goal-sent-${messages[i]}',
                                  cacheId: 'goal-sent-${messages[i]}',
                                  builder: (_) => const GoalSentBadge(),
                                ),
                              // Where the context was folded up. Drawn in the
                              // transcript rather than announced once and
                              // forgotten: the messages above it are still
                              // readable, and this is the line that says the
                              // assistant is no longer reading them.
                              if (compaction != null &&
                                  compaction.through == i + 1)
                                TranscriptRow(
                                  scrollId: compaction,
                                  cacheId: compaction,
                                  builder: (_) =>
                                      CompactedRow(compaction: compaction),
                                ),
                              // How the goal ended, and how the repeating
                              // prompt did — at the turn it happened on.
                              if (goal != null && goal.endedAfter == i + 1)
                                TranscriptRow(
                                  scrollId: goal,
                                  cacheId: goal,
                                  builder: (_) => GoalEndedRow(goal: goal),
                                ),
                              if (loop != null && loop.endedAfter == i + 1)
                                TranscriptRow(
                                  scrollId: loop,
                                  cacheId: loop,
                                  builder: (_) => LoopEndedRow(loop: loop),
                                ),
                            ],
                          ],
                          marksOf: () => minimapMarks(messages),
                          trailing: hasTrailing
                              ? _TrailingBubble(
                                  agentMode: agentMode,
                                  onRedrawn: _followRedraw,
                                )
                              : null,
                          atBottom: _atBottom,
                          onJumpToLatest: () => _scrollToBottom(animated: true),
                        ),
                ),
                if (permission != null && activeId != null)
                  Center(
                    child: ConstrainedBox(
                      constraints: BoxConstraints(
                        maxWidth: _composerWidth,
                        maxHeight: _permissionCardHeight(context),
                      ),
                      child: Padding(
                        padding: const EdgeInsets.fromLTRB(20, 0, 20, 0),
                        child: AgentPermissionCard(
                          chatId: activeId,
                          request: permission,
                        ),
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
                              (!needsImage || _attachments.isNotEmpty) &&
                              !visionLocked;
                          // A leading "/" (with no space yet) opens the command
                          // menu; an "@" token opens the file menu. Only one
                          // shows at a time, commands first.
                          final slash = sending
                              ? null
                              : slashQuery(_message.text);
                          final cursor = _message.selection.baseOffset;
                          final mention =
                              (sending || slash != null || cursor < 0)
                              ? null
                              : activeMention(_message.text, cursor);
                          // The command the line will run on Send — badged in
                          // the composer once its argument is being typed, where
                          // the `/` menu (above) has already closed. Null while
                          // that menu is up, so the two never show at once.
                          final command = sending
                              ? null
                              : activeComposerCommand(_message.text);
                          return Column(
                            mainAxisSize: MainAxisSize.min,
                            crossAxisAlignment: CrossAxisAlignment.stretch,
                            children: [
                              const AgentHandoverBar(),
                              // Above the plan bar: a question the assistant
                              // asked is the one notice here that is *about*
                              // what to type next, so it sits closest to where
                              // the answer would otherwise be typed.
                              const AgentQuestionsCard(),
                              const PlanApproveBar(),
                              const OutOfStepsBar(),
                              // `AgentChangesBar` used to sit here. Hidden on
                              // 2026-08-10: git and the Review tab already show
                              // what the assistant changed, and a third notice
                              // over the composer said it a third time. The
                              // recording behind it stays on — Review's "Last
                              // turn" scope reads it (`lastTurnAgentPaths`) —
                              // so bringing the bar back is putting this one
                              // line back.
                              const SaveSkillBar(),
                              const QueuedFollowUps(),
                              // Above the composer, under everything that is
                              // waiting on a decision: a goal is taking the
                              // turns the user would otherwise be typing, so it
                              // belongs in their line of sight rather than as a
                              // footnote beneath the box. It stays one strip for
                              // everything running, which is the part of the
                              // under-the-composer version worth keeping.
                              const ComposerStatus(),
                              if (slash != null)
                                CommandSlashMenu(
                                  query: slash,
                                  onPick: _pickCommand,
                                )
                              else if (mention != null)
                                FileMentionMenu(
                                  workdir: workdir,
                                  query: mention.query,
                                  onPick: _insertMention,
                                ),
                              ComposerSection(
                                messageController: _message,
                                activeCommand: command,
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
                                busySendTooltip: steerable
                                    ? kSendIntoAnswerTooltip
                                    : kSendAfterAnswerTooltip,
                                error: error,
                                // Retry reuses the committed turn, including
                                // its picture, after the user picks a model
                                // that can answer it. Agent failures keep their
                                // one-click handover beside that universal exit.
                                errorAction: error == null
                                    ? null
                                    : Wrap(
                                        spacing: 4,
                                        runSpacing: 4,
                                        children: [
                                          TextButton(
                                            onPressed: () => unawaited(
                                              ref
                                                  .read(
                                                    chatSessionsProvider
                                                        .notifier,
                                                  )
                                                  .retry(
                                                    network: widget.network,
                                                    model: _model.text.trim(),
                                                    modality: modality,
                                                  ),
                                            ),
                                            child: const Text('Retry'),
                                          ),
                                          if (agentMode)
                                            const SwitchAgentButton(),
                                        ],
                                      ),
                                // Only the agent can touch this computer — a
                                // picture is made by the grid, so there'd be
                                // nothing to approve.
                                approvalPicker: agentMode
                                    ? ApprovalPicker(
                                        value: approval,
                                        onChanged: ref
                                            .read(chatSessionsProvider.notifier)
                                            .setApproval,
                                      )
                                    : null,
                                // An attached picture bypasses the agent for
                                // this turn, but must not hide or reset the
                                // conversation's agent choice while composing.
                                agentPicker:
                                    modality == PlaygroundModality.text &&
                                        agentInstalled
                                    ? const AgentPicker()
                                    : null,
                                modelPicker: GridModelPicker(
                                  currentModelId: _model.text,
                                  onSelect: _pickGridModel,
                                  visionBlocked: visionLocked,
                                  selectedModel: selectedModel,
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
                                    .read(attachedTerminalsProvider.notifier)
                                    .remove(tabId),
                                focusNode: _composerFocus,
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
/// nothing else. Whether this chat's own agent turn is running decides between
/// the working feed and a plain waiting cue — a chat queued behind another in
/// its project has a feed, but nothing in it yet.
class _TrailingBubble extends ConsumerWidget {
  const _TrailingBubble({required this.agentMode, this.onRedrawn});

  /// Whether an agent is answering this turn — a media turn bypasses it, so the
  /// bubble shows progress rather than "the agent is working".
  final bool agentMode;

  /// Called when the streaming reply redraws off its own timer rather than off a
  /// state change — the transcript grew with nothing to follow it. See
  /// `_ChatViewState._followRedraw`.
  final VoidCallback? onRedrawn;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final phase = ref.watch(chatSessionsProvider.select((s) => s.phase));
    final chatId = ref.watch(chatSessionsProvider.select((s) => s.activeId));
    if (chatId == null) return const SizedBox.shrink();
    return switch (phase) {
      SendGenerating g => GeneratingBubble(phase: g),
      SendStreaming(:final text) when text.isNotEmpty => _StreamingReply(
        chatId: chatId,
        text: text,
        showActivity: agentMode,
        onRedrawn: onRedrawn,
      ),
      SendStreaming() => AgentWorkingBubble(chatId: chatId),
      // Committed but not streaming yet: the turn is being set up — under Auto
      // that is a live call asking the grid which assistant should answer. The
      // feed's "Thinking…" line is what that is, and it is the same cue the turn
      // keeps showing once the agent takes over, so nothing flickers when it
      // does.
      SendBusy() when agentMode => AgentWorkingBubble(chatId: chatId),
      _ => const SizedBox.shrink(),
    };
  }
}

/// The reply as it streams in: the partial text, exactly as [ChatBubble] draws
/// the finished turn.
///
/// A plain model reply carries the [TypingDots] cue under it so a pause between
/// bursts reads as "still going", not "stopped". An agent turn is drawn as the
/// turn it is — the passages it has already written, the steps it ran between
/// them, and the passage still arriving at the end (see [AgentActivityFeed]) —
/// which already carries its own spinner, so the dots would say the same thing
/// twice and are dropped.
///
/// Reuses [ChatBubble] rather than re-laying-out the text, so a half-streamed
/// reply and the same reply once committed are drawn identically — the cue
/// dropping away is the only change at that moment, give or take the last
/// [_redrawInterval] of text the throttle below had still to draw. The cue sits
/// at the content's left edge (the assistant column starts there), a touch below.
///
/// **Redraws at most once per [_redrawInterval], not once per token**, and that
/// is the difference between a long answer that streams and one that stutters.
/// Drawing markdown is not cheap: every rebuild re-splits the text, rebuilds the
/// stylesheet, and re-parses the whole reply into an AST and a widget tree. Paid
/// per token on a growing string it is quadratic — measured at 434µs a token on
/// a short reply and 1.7ms on a 9k one, against 3.5ms to parse that same reply
/// once at the end.
///
/// The throttle is here, in the widget, and deliberately **not** in the
/// controller. `stop()` and a failed turn both recover the half-written answer by
/// reading `SendStreaming.text` back out of the state — hold deltas there and a
/// user who stops mid-sentence loses the words they stopped *because* they had
/// read (`chat_sessions_controller_test.dart` asserts exactly that, on disk as
/// well as in state), and the turn's first-token timing goes with it. So state
/// still sees every token; only the drawing is rationed.
class _StreamingReply extends ConsumerStatefulWidget {
  const _StreamingReply({
    required this.chatId,
    required this.text,
    this.showActivity = false,
    this.onRedrawn,
  });

  /// The conversation being answered — the feed under the text is that chat's.
  final String chatId;

  final String text;

  /// Whether this turn is an agent's, and so drawn as a live timeline. Off for a
  /// plain model reply, which has no steps to place its words among.
  final bool showActivity;

  /// Called after a redraw that the throttle deferred — the one case where the
  /// transcript grows with no state change to follow it. See
  /// `_ChatViewState._followRedraw`.
  final VoidCallback? onRedrawn;

  @override
  ConsumerState<_StreamingReply> createState() => _StreamingReplyState();
}

/// How long the drawn text is allowed to lag the streamed text.
///
/// 50ms is 20 redraws a second — past the rate at which text arriving reads as
/// continuous, and well inside the ~100ms that would start to feel like a pause.
///
/// It is a ceiling on how much work a fast stream can ask for, **not** a delay
/// added to a slow one, and that takes a leading edge to be true: a token that
/// arrives when nothing has been drawn for this long is drawn straight away, in
/// the frame its own state change triggered. Only a token arriving inside the
/// interval waits, and then only for the remainder of it. A purely trailing
/// throttle would have been simpler and wrong — under 20 tokens a second every
/// token arrives with nothing pending, so *every* redraw would have been held
/// back the full 50ms, making the slowest models feel the laggiest.
const Duration _redrawInterval = Duration(milliseconds: 50);

class _StreamingReplyState extends ConsumerState<_StreamingReply> {
  /// The text currently drawn, which trails [_StreamingReply.text] by at most
  /// [_redrawInterval]. The first chunk is drawn as it arrives — a turn only
  /// reaches this widget once it has text, so there is nothing to ration yet.
  late String _shown = widget.text;

  /// How much of the answer the turn's timeline had already placed when the
  /// answer widget was built. The open passage is what is left over
  /// ([unsaidTail]), so a step landing — which closes a passage and moves this
  /// on — has to rebuild it.
  String? _placed;

  /// The ink that answer was built with. Held for the same reason [_placed] is:
  /// the cached widget is handed back untouched on a rebuild, so a theme flipped
  /// while the agent is between sentences would otherwise leave the passage on
  /// screen in the old theme's colour until the next token arrived.
  Color? _ink;

  /// Pending redraw, or null when the drawn text is already current.
  Timer? _redraw;

  /// Time since the last redraw, for the leading edge — monotonic, so it can't
  /// be thrown by the clock changing under a long agent turn.
  final _sinceDrawn = Stopwatch()..start();

  /// The built answer, held so a rebuild that doesn't change [_shown] hands the
  /// **same widget instance** back.
  ///
  /// Throttling `_shown` alone would not have been enough: `MessageContent` is a
  /// `StatelessWidget`, so the parent rebuilding on every token rebuilds it too,
  /// and it re-splits the text and rebuilds the markdown stylesheet before
  /// `MarkdownBody` gets to notice its `data` is unchanged. An identical child
  /// widget makes the framework skip the subtree outright — the same trick
  /// `TranscriptView` uses to keep committed turns still (its row cache).
  Widget? _bubble;

  @override
  void didUpdateWidget(_StreamingReply old) {
    super.didUpdateWidget(old);
    // The cached widget is a `ChatBubble` on one branch and a `MessageContent`
    // on the other, so a turn that changes hands mid-flight — the user attaches
    // an image while an agent is answering, and the next build is a relay
    // turn — must not be handed the other branch's widget.
    if (widget.showActivity != old.showActivity) _bubble = null;
    // A different conversation is not a continuation of this one. Switching
    // between two chats that are both streaming reuses this element, so a
    // pending redraw here would paint the other chat's words into this one.
    // Nothing is set through setState: the framework rebuilds us right after
    // this returns.
    if (widget.chatId != old.chatId) {
      _redraw?.cancel();
      _redraw = null;
      _draw();
      return;
    }
    if (widget.text == _shown || _redraw != null) return;
    // Leading edge: nothing drawn for a whole interval, so draw in this frame —
    // the one the state change is already building, which is also the frame the
    // follow-scroll measures. No setState, and none needed: the framework
    // rebuilds us as soon as this returns.
    if (_sinceDrawn.elapsed >= _redrawInterval) {
      _draw();
      return;
    }
    // Inside the interval: wait out the remainder. Later tokens arriving
    // meanwhile only update `widget.text` and the timer draws the newest of
    // them, so a burst costs one redraw rather than one per token. The timer is
    // always armed while text is outstanding, so the last token of a reply is
    // never left undrawn.
    _redraw = Timer(_redrawInterval - _sinceDrawn.elapsed, () {
      _redraw = null;
      if (!mounted) return;
      setState(_draw);
      // This redraw grew the transcript outside any state change, so it has to
      // ask for the follow-scroll the provider listener would otherwise have
      // done for it.
      widget.onRedrawn?.call();
    });
  }

  /// Adopt the newest streamed text and drop the cached answer built from the
  /// old one. Call inside `setState` when outside a build, bare when the
  /// framework is about to rebuild anyway.
  void _draw() {
    _shown = widget.text;
    _bubble = null;
    _sinceDrawn.reset();
  }

  @override
  void dispose() {
    _redraw?.cancel();
    _sinceDrawn.stop();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    // A plain model reply has no steps to be placed among, so it stays what it
    // has always been: the whole answer, with the dots under it carrying "still
    // going" across a pause between bursts.
    if (!widget.showActivity) {
      _bubble ??= ChatBubble(
        message: ChatMessage(role: ChatRole.assistant, text: _shown),
      );
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          _bubble!,
          const Padding(
            padding: EdgeInsets.only(left: 2, bottom: 10),
            child: TypingDots(),
          ),
        ],
      );
    }

    // An agent turn is drawn as the turn: the passages already closed off by the
    // steps that followed them, then whatever it is saying now. Only this last
    // passage is redrawn per token — the rest is settled, and lives in the run.
    AppTheme.watch(context);
    final ink = AppPalette.textPrimary;
    final placed = ref.watch(
      agentRunProvider(widget.chatId).select((run) => run.said),
    );
    if (_placed != placed || _ink != ink) {
      _placed = placed;
      _ink = ink;
      _bubble = null;
    }
    // Empty right after a step closed the passage before it and before the next
    // word arrives — nothing to draw, rather than a blank block holding a gap
    // open under the steps.
    final open = unsaidTail(said: placed, answer: _shown);
    if (open.isNotEmpty) {
      _bubble ??= MessageContent(text: open, color: ink);
    }
    return Align(
      alignment: Alignment.centerLeft,
      // The same margin [ChatBubble] gives an assistant turn, so the reply
      // doesn't shift the moment it lands and becomes one.
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 14),
        child: AgentActivityFeed(
          chatId: widget.chatId,
          leadingGap: false,
          answer: open.isEmpty ? null : _bubble,
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
