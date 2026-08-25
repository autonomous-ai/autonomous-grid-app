import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/composer_text.dart';
import '../../../infrastructure/analytics/analytics_events.dart';
import '../../../infrastructure/analytics/analytics_providers.dart';
import '../../../infrastructure/platform/clipboard_paste.dart';
import '../../../infrastructure/state/models/network_credential.dart';
import '../../../shared/layouts/shell_state.dart';
import '../../../shared/theme/app_theme.dart';
import '../../../shared/widgets/empty_state.dart';
import '../../../shared/widgets/glass_card.dart';
import '../../../shared/widgets/toast.dart';
import '../../auth/logic/session_controller.dart';
import '../../../shared/widgets/modality_mark.dart';
import '../../provider_node/logic/provider_run_controller.dart';
import '../logic/chat_controller.dart';
import '../logic/chat_message.dart';
import '../logic/local_test_state.dart';
import '../logic/playground_models.dart';
import '../logic/image_budget.dart';
import '../logic/image_shrink.dart';
import '../logic/playground_request.dart';
import 'attachment_bar.dart';
import 'chat_bubble.dart';
import 'chat_input_bar.dart';
import 'model_picker.dart';
import 'no_model_yet.dart';

/// Opens the quick model-test dialog for the selected grid and wipes the
/// transcript once it closes — the playground is a throwaway smoke test, not a
/// saved conversation, so every open starts from a clean slate. The notifier is
/// captured before the await so we never touch [ref] across the async gap.
Future<void> openPlaygroundDialog(BuildContext context, WidgetRef ref) async {
  final chat = ref.read(chatControllerProvider.notifier);
  await showDialog<void>(
    context: context,
    builder: (_) => const PlaygroundDialog(),
  );
  chat.clear();
}

/// Model-test playground as a dialog — a quick way to check a model responds.
/// Routes by the selected model's modality: text chats via the relay's
/// `chat/completions`, image/video models generate through the media endpoints.
/// Everything is a single-turn smoke test over HTTP; the transcript is local UI
/// state, cleared when the dialog closes (see [openPlaygroundDialog]).
class PlaygroundDialog extends ConsumerStatefulWidget {
  const PlaygroundDialog({super.key});

  @override
  ConsumerState<PlaygroundDialog> createState() => _PlaygroundDialogState();
}

class _PlaygroundDialogState extends ConsumerState<PlaygroundDialog> {
  final _model = TextEditingController();
  final _message = TextEditingController();
  final _scroll = ScrollController();
  final List<MediaAttachment> _attachments = [];
  String _autoModel = '';

  @override
  void initState() {
    super.initState();
    // The picker is a plain TextEditingController, not a provider, so selecting a
    // model won't rebuild the dialog on its own. Refresh on change so the
    // modality-driven UI (attach bar, hints, send gating) tracks the selection.
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

  /// Default the model field to the first advertised model (blank when none),
  /// re-applying when the list changes — but never clobbering a model the user
  /// typed themselves.
  void _syncDefaultModel(List<String> models) {
    final first = models.isEmpty ? '' : models.first;
    if (first == _autoModel) return;
    final userCustomized = _model.text.isNotEmpty && _model.text != _autoModel;
    _autoModel = first;
    if (userCustomized) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && _model.text != first) _model.text = first;
    });
  }

  /// The modality of the currently-selected option. Unknown / hand-typed ids
  /// fall back to text (a plain chat model).
  PlaygroundModality _modalityFor(List<PlaygroundModelOption> options) {
    final id = _model.text.trim();
    final match = options.where((o) => o.id == id);
    return match.isEmpty ? PlaygroundModality.text : match.first.modality;
  }

  void _send(NetworkCredential network) {
    final message = _message.text.trim();
    if (message.isEmpty) return;
    final useLocal = ref.read(useLocalTestProvider);
    final localEndpoint = ref.read(localProviderEndpointProvider);
    // Resolve the modality from the *current* selection, not a build-time
    // capture — the picker can change without a rebuild, so reading it here is
    // what keeps an image selection from being sent to the chat endpoint.
    final modality = useLocal
        ? PlaygroundModality.text
        : _modalityFor(ref.read(playgroundModelsProvider));
    ref
        .read(chatControllerProvider.notifier)
        .send(
          network: network,
          model: _model.text.trim(),
          message: message,
          modality: modality,
          attachments: useLocal ? const [] : List.of(_attachments),
          localBaseUrl: useLocal ? localEndpoint : null,
        );
    _message.clear();
    if (_attachments.isNotEmpty) setState(_attachments.clear);
  }

  /// How many pictures this mode takes: one to animate, three to edit — and no
  /// number at all for a plain message, where what runs out is the room in the
  /// request body rather than a count (see [imageBudgetLeft]).
  int? _imageLimit(PlaygroundModality modality) => switch (modality) {
    PlaygroundModality.video => 1,
    PlaygroundModality.image => 3,
    PlaygroundModality.text => null,
  };

  /// ⌘V / Ctrl+V: a screenshot becomes an attachment, copied images become
  /// attachments, and anything else lands as text — the same paste the Chat tab
  /// does, since this dialog is where most people first try a model.
  Future<void> _paste() async {
    final paste = await readClipboardPaste();
    if (!mounted) return;
    final modality = _modalityFor(ref.read(playgroundModelsProvider));
    switch (paste) {
      case PastedImage(:final bytes, :final filename):
        await _attachImage(
          MediaAttachment(filename: filename, bytes: bytes),
          modality,
        );
      case PastedFiles(:final paths):
        await _attachImageFiles(paths, modality);
      case PastedText(:final text):
        _insertText(text);
      case PastedNothing():
        break;
    }
  }

  /// Attaches the images among [paths]. The dialog is a model smoke test with no
  /// agent behind it, so a document has nothing here that could read it — those
  /// belong in the Chat tab, which says so rather than taking the file and
  /// quietly ignoring it.
  Future<void> _attachImageFiles(
    List<String> paths,
    PlaygroundModality modality,
  ) async {
    for (final path in paths) {
      if (!isImageFilename(path)) continue;
      final file = File(path);
      // Refused unopened past the cap: shrinking decodes the picture first, and
      // reading a 200 MB file to find that out would stop the window.
      if (await file.length() > kMaxImageFileBytes) {
        if (!mounted) return;
        _sayOversized(fileNameOf(path));
        continue;
      }
      final bytes = await file.readAsBytes();
      if (!mounted) return;
      await _attachImage(
        MediaAttachment(filename: fileNameOf(path), bytes: bytes),
        modality,
      );
    }
  }

  /// Attaches one picture, shrunk to what a request may carry.
  ///
  /// The same ceiling the Chat tab attaches under: a picture rides in the
  /// request body as base64 text, and one 5K screenshot is bigger on its own
  /// than the whole body the relay accepts.
  Future<void> _attachImage(
    MediaAttachment image,
    PlaygroundModality modality,
  ) async {
    final limit = _imageLimit(modality);
    if (limit != null && _attachments.length >= limit) return;
    final left = imageBudgetLeft(_attachments);
    if (left <= 0) {
      _say(pictureBudgetFullMessage(image.filename));
      return;
    }
    final fitted = await fitImageToBudget(
      image,
      budgetBytes: imageBudgetForNext(left),
    );
    if (!mounted) return;
    if (fitted == null) {
      _sayOversized(image.filename);
      return;
    }
    setState(() => _attachments.add(fitted));
  }

  void _sayOversized(String filename) {
    final message = oversizedAttachmentMessage([filename]);
    if (message == null) return;
    _say(message);
  }

  void _say(String message) => ToastScope.show(
    context,
    ToastSpec(message: message, severity: ToastSeverity.warning),
  );

  /// Drops pasted text in at the cursor, exactly where the field would have.
  void _insertText(String insert) {
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

  void _scrollToBottom() {
    if (!_scroll.hasClients) return;
    _scroll.jumpTo(_scroll.position.maxScrollExtent);
  }

  @override
  Widget build(BuildContext context) {
    final network = ref.watch(selectedNetworkProvider);

    // Keep the transcript pinned to the latest message.
    ref.listen(chatControllerProvider, (_, _) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _scrollToBottom());
    });

    return Dialog(
      backgroundColor: AppPalette.panelBg,
      insetPadding: const EdgeInsets.symmetric(horizontal: 40, vertical: 32),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 560, maxHeight: 660),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(20, 16, 20, 20),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              _DialogHeader(network: network),
              const Divider(height: 24),
              Expanded(child: _buildBody(context, network)),
            ],
          ),
        ),
      ),
    );
  }

  /// The chat area, or a guiding placeholder when there's no grid / no model
  /// that could answer yet.
  Widget _buildBody(BuildContext context, NetworkCredential? network) {
    if (network == null) {
      // Also [EmptyState] rather than `ComingSoon`: nothing here is unbuilt —
      // the dialog just needs a grid picked before it has anywhere to send to.
      return const EmptyState(
        icon: Icons.bolt_outlined,
        title: 'No grid selected',
        message: 'Select a grid first to start chatting.',
        compact: true,
      );
    }

    final theme = Theme.of(context);
    final options = ref.watch(playgroundModelsProvider);
    // Waiting on the first answer from either source — the same gate ChatView
    // uses; see [playgroundModelsResolvingProvider].
    final loadingModels = ref.watch(playgroundModelsResolvingProvider);
    if (options.isNotEmpty) {
      _syncDefaultModel([for (final o in options) o.id]);
    }
    final localEndpoint = ref.watch(localProviderEndpointProvider);
    final useLocal = ref.watch(useLocalTestProvider);
    final chat = ref.watch(chatControllerProvider);

    // Nothing can answer yet: no model advertised on the grid and no local
    // engine serving. Guide the user to start one instead of a dead input box.
    final hasUsableModel = options.isNotEmpty || localEndpoint != null;
    if (!loadingModels && !hasUsableModel) {
      return NoModelYet(
        canManage: network.canManageProvider,
        onGoToEngines: () {
          ref.read(analyticsProvider).enginesOpened('start_engine_btn');
          Navigator.of(context).pop();
          ref.read(shellSectionProvider.notifier).select(ShellSection.engines);
        },
      );
    }

    final modality = useLocal ? PlaygroundModality.text : _modalityFor(options);
    final needsImage = modality == PlaygroundModality.video;
    final canSend = !chat.sending && (!needsImage || _attachments.isNotEmpty);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (localEndpoint != null) ...[
          _LocalTestToggle(
            value: useLocal,
            endpoint: localEndpoint,
            onChanged: (v) => ref.read(useLocalTestProvider.notifier).set(v),
          ),
          const SizedBox(height: 12),
        ],
        ModelPicker(
          controller: _model,
          options: options,
          networkName: network.name,
        ),
        const SizedBox(height: 12),
        // The bar is for the media modes — but it also appears the moment a
        // picture is pasted into a plain chat, so a screenshot has somewhere to
        // land instead of riding along invisibly.
        if (!useLocal &&
            (modality != PlaygroundModality.text ||
                _attachments.isNotEmpty)) ...[
          AttachmentBar(
            attachments: _attachments,
            maxCount: _imageLimit(modality),
            showAddTile: modality != PlaygroundModality.text,
            hint: modality == PlaygroundModality.text
                ? null
                : needsImage
                ? 'Video needs a starting image to animate.'
                : 'Optional: attach up to 3 images to edit instead of generate.',
            onAdd: (a) => setState(() => _attachments.add(a)),
            onRemoveAt: (i) => setState(() => _attachments.removeAt(i)),
          ),
          const SizedBox(height: 12),
        ],
        Expanded(
          child: chat.messages.isEmpty
              ? EmptyState(
                  // The picker's own mark for this modality. It used to be a
                  // second switch here that claimed to match the picker and
                  // didn't — different glyphs for all three.
                  icon: modalityIcon(modality),
                  title: _emptyTitle(modality),
                  message: _emptyHint(modality),
                  compact: true,
                )
              : ListView.builder(
                  controller: _scroll,
                  itemCount:
                      chat.messages.length +
                      (chat.phase is SendGenerating ? 1 : 0),
                  itemBuilder: (context, i) => i < chat.messages.length
                      ? ChatBubble(message: chat.messages[i])
                      : GeneratingBubble(phase: chat.phase as SendGenerating),
                ),
        ),
        if (chat.error != null) ...[
          const SizedBox(height: 8),
          Text(
            chat.error!,
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.error,
            ),
          ),
        ],
        const SizedBox(height: 12),
        ChatInputBar(
          controller: _message,
          sending: chat.sending,
          canSend: canSend,
          hint: _inputHint(modality),
          onSend: () => _send(network),
          onPaste: () => unawaited(_paste()),
        ),
      ],
    );
  }

  /// The waiting-for-your-first-message state.
  ///
  /// [EmptyState], not `ComingSoon` — that one is for a screen the app has a
  /// place for but *hasn't built*, and it says so with a wrench. This dialog is
  /// finished and working; it's just empty until you type. The wrench was
  /// telling a working feature's users it wasn't ready.
  String _emptyTitle(PlaygroundModality modality) => switch (modality) {
    PlaygroundModality.image => 'No images yet',
    PlaygroundModality.video => 'No videos yet',
    PlaygroundModality.text => 'No messages yet',
  };

  String _emptyHint(PlaygroundModality modality) => switch (modality) {
    PlaygroundModality.image => 'Describe an image to generate.',
    PlaygroundModality.video => 'Attach an image, then describe the motion.',
    PlaygroundModality.text => 'Send a message to start chatting.',
  };

  String _inputHint(PlaygroundModality modality) => switch (modality) {
    PlaygroundModality.image => 'Describe the image…',
    PlaygroundModality.video => 'Describe the motion…',
    PlaygroundModality.text => 'Message…',
  };
}

/// Dialog title with the grid it targets, plus a Close button.
class _DialogHeader extends StatelessWidget {
  const _DialogHeader({required this.network});
  final NetworkCredential? network;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('Test a model', style: theme.textTheme.titleLarge),
              const SizedBox(height: 2),
              Text(
                network == null
                    ? 'Chat with a model, or generate images and video.'
                    : 'Chat, or generate images and video, on ${network!.name}.',
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
            ],
          ),
        ),
        IconButton(
          tooltip: 'Close',
          icon: const Icon(Icons.close_rounded, size: AppControl.iconSize),
          onPressed: () => Navigator.of(context).pop(),
        ),
      ],
    );
  }
}

/// Shown only while a local provider is serving — flips the chat from the relay
/// to a direct HTTP call against the local server (the curl smoke test).
class _LocalTestToggle extends StatelessWidget {
  const _LocalTestToggle({
    required this.value,
    required this.endpoint,
    required this.onChanged,
  });

  final bool value;
  final String endpoint;
  final ValueChanged<bool> onChanged;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return GlassCard(
      style: GlassCardStyle.inset,
      padding: const EdgeInsets.fromLTRB(14, 4, 8, 4),
      child: Row(
        children: [
          Icon(Icons.bolt_outlined, size: 18, color: AppPalette.online),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Test your own model',
                  style: theme.textTheme.bodyMedium?.copyWith(
                    fontWeight: FontWeight.w500,
                  ),
                ),
                Text(
                  'Chat with your model directly, without going through the grid',
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
              ],
            ),
          ),
          Switch(value: value, onChanged: onChanged),
        ],
      ),
    );
  }
}
