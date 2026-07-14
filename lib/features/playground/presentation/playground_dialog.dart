import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../infrastructure/state/models/network_credential.dart';
import '../../../shared/layouts/shell_state.dart';
import '../../../shared/theme/app_theme.dart';
import '../../../shared/widgets/glass_card.dart';
import '../../../shared/widgets/section_scaffold.dart';
import '../../auth/logic/session_controller.dart';
import '../../network/logic/grid_overview_provider.dart';
import '../../network/logic/network_models_provider.dart';
import '../../provider_node/logic/provider_run_controller.dart';
import '../logic/chat_controller.dart';
import '../logic/chat_message.dart';
import '../logic/local_test_state.dart';
import '../logic/playground_models.dart';
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
      return const ComingSoon(
        message: 'Select a grid first to start chatting.',
      );
    }

    final theme = Theme.of(context);
    final options = ref.watch(playgroundModelsProvider);
    final loadingModels =
        ref.watch(gridOverviewProvider).isLoading &&
        ref.watch(networkModelsProvider).isLoading;
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
        if (!useLocal && modality != PlaygroundModality.text) ...[
          AttachmentBar(
            attachments: _attachments,
            maxCount: needsImage ? 1 : 3,
            hint: needsImage
                ? 'Video needs a starting image to animate.'
                : 'Optional: attach up to 3 images to edit instead of generate.',
            onAdd: (a) => setState(() => _attachments.add(a)),
            onRemoveAt: (i) => setState(() => _attachments.removeAt(i)),
          ),
          const SizedBox(height: 12),
        ],
        Expanded(
          child: chat.messages.isEmpty
              ? ComingSoon(message: _emptyHint(modality))
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
        ),
      ],
    );
  }

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
          icon: const Icon(Icons.close_rounded, size: 20),
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
          const Icon(Icons.bolt_outlined, size: 18, color: AppPalette.online),
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
