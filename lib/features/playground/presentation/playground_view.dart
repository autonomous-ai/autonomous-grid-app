import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../shared/layouts/shell_state.dart';
import '../../../shared/theme/app_theme.dart';
import '../../../shared/widgets/section_scaffold.dart';
import '../../auth/logic/session_controller.dart';
import '../../provider_node/logic/provider_run_controller.dart';
import '../logic/chat_controller.dart';
import '../logic/local_test_state.dart';
import '../logic/network_models_provider.dart';
import 'message_content.dart';

/// Consumer chat playground — the main consumer action. Sends a message via
/// `grid request chat --network <net> --model <model> --message "<msg>"` and
/// shows the reply. Single-turn (the CLI keeps no history); transcript is local.
class PlaygroundView extends ConsumerStatefulWidget {
  const PlaygroundView({super.key});

  @override
  ConsumerState<PlaygroundView> createState() => _PlaygroundViewState();
}

class _PlaygroundViewState extends ConsumerState<PlaygroundView> {
  final _model = TextEditingController();
  final _message = TextEditingController();
  final _scroll = ScrollController();
  String _autoModel = '';

  @override
  void dispose() {
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

  void _send(String networkId) {
    final message = _message.text.trim();
    if (message.isEmpty) return;
    final useLocal = ref.read(useLocalTestProvider);
    final localEndpoint = ref.read(localProviderEndpointProvider);
    ref.read(chatControllerProvider.notifier).send(
          network: networkId,
          model: _model.text.trim(),
          message: message,
          localBaseUrl: useLocal ? localEndpoint : null,
        );
    _message.clear();
  }

  void _scrollToBottom() {
    if (!_scroll.hasClients) return;
    _scroll.jumpTo(_scroll.position.maxScrollExtent);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final network = ref.watch(selectedNetworkProvider);
    final chat = ref.watch(chatControllerProvider);
    final localEndpoint = ref.watch(localProviderEndpointProvider);
    final useLocal = ref.watch(useLocalTestProvider);

    // Keep the transcript pinned to the latest message.
    ref.listen(chatControllerProvider, (_, __) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _scrollToBottom());
    });

    if (network == null) {
      return const SectionScaffold(
        title: 'Playground',
        child: ComingSoon(message: 'Select a grid first to start chatting.'),
      );
    }

    final models = ref.watch(networkModelsProvider).asData?.value;
    if (models != null) _syncDefaultModel(models);

    // Nothing can answer yet: no model advertised on the grid and no local
    // engine serving. Guide the user to start one instead of presenting a chat
    // box that would just fail on send. (While models is null we're still
    // loading — keep the normal UI to avoid a flash of this state.)
    final hasUsableModel =
        (models != null && models.isNotEmpty) || localEndpoint != null;
    if (models != null && !hasUsableModel) {
      return SectionScaffold(
        title: 'Playground',
        subtitle: network.name,
        child: _NoModelYet(canManage: network.canManageProvider),
      );
    }

    return SectionScaffold(
      title: 'Playground',
      subtitle: network.name,
      child: Column(
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
          _ModelPicker(controller: _model),
          const SizedBox(height: 12),
          Expanded(
            child: chat.messages.isEmpty
                ? const ComingSoon(message: 'Send a message to start chatting.')
                : ListView.builder(
                    controller: _scroll,
                    itemCount: chat.messages.length,
                    itemBuilder: (context, i) => _Bubble(message: chat.messages[i]),
                  ),
          ),
          if (chat.error != null) ...[
            const SizedBox(height: 8),
            Text(chat.error!,
                style: theme.textTheme.bodySmall
                    ?.copyWith(color: theme.colorScheme.error)),
          ],
          const SizedBox(height: 12),
          _InputBar(
            controller: _message,
            sending: chat.sending,
            onSend: () => _send(network.networkId),
          ),
        ],
      ),
    );
  }
}

/// Editable model dropdown — lists models advertised on the network (relay
/// `/models`), yet stays typeable so it still works when none can be fetched
/// (no provider online, missing inference scope, or relay down).
class _ModelPicker extends ConsumerWidget {
  const _ModelPicker({required this.controller});
  final TextEditingController controller;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final network = ref.watch(selectedNetworkProvider);
    final models = ref.watch(networkModelsProvider).asData?.value ?? const [];

    return DropdownMenu<String>(
      controller: controller,
      enableFilter: true,
      requestFocusOnTap: true,
      expandedInsets: EdgeInsets.zero,
      label: const Text('Model'),
      hintText: 'Qwen3.6-35B-A3B',
      leadingIcon: const Icon(Icons.smart_toy_outlined, size: 18),
      helperText: models.isEmpty
          ? 'No models available yet — type a name'
          : '${models.length} model(s) on ${network?.name ?? 'grid'}',
      dropdownMenuEntries: [
        for (final model in models)
          DropdownMenuEntry(value: model, label: model),
      ],
      onSelected: (value) {
        if (value != null) controller.text = value;
      },
    );
  }
}

/// Blocked state when no model can answer yet. Points provider-capable users to
/// the Engines tab to start one; pure consumers are told to wait for a provider.
class _NoModelYet extends ConsumerWidget {
  const _NoModelYet({required this.canManage});
  final bool canManage;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 420),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.smart_toy_outlined,
                size: 40, color: theme.colorScheme.onSurfaceVariant),
            const SizedBox(height: 16),
            Text('No model is running yet',
                style: theme.textTheme.titleMedium, textAlign: TextAlign.center),
            const SizedBox(height: 8),
            Text(
              canManage
                  ? 'Start an engine on this grid to chat with a model.'
                  : 'Wait for someone on this grid to bring a model online, or '
                      'ask the grid owner to run one.',
              textAlign: TextAlign.center,
              style: theme.textTheme.bodyMedium
                  ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
            ),
            if (canManage) ...[
              const SizedBox(height: 16),
              FilledButton.icon(
                onPressed: () => ref
                    .read(navSectionProvider.notifier)
                    .select(NavSection.provider),
                icon: const Icon(Icons.dns_outlined, size: 18),
                label: const Text('Go to Engines'),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

/// Shown only while a local provider is serving — flips the Playground from the
/// relay to a direct HTTP call against the local server (the curl smoke test).
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
    return Container(
      padding: const EdgeInsets.fromLTRB(14, 4, 8, 4),
      decoration: BoxDecoration(
        color: AppPalette.cardBg,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: AppPalette.divider),
      ),
      child: Row(
        children: [
          const Icon(Icons.bolt_outlined, size: 18, color: AppPalette.online),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('Test your own model',
                    style: theme.textTheme.bodyMedium
                        ?.copyWith(fontWeight: FontWeight.w500)),
                Text('Chat with your model directly, without going through the grid',
                    style: theme.textTheme.bodySmall
                        ?.copyWith(color: theme.colorScheme.onSurfaceVariant)),
              ],
            ),
          ),
          Switch(value: value, onChanged: onChanged),
        ],
      ),
    );
  }
}

class _Bubble extends StatelessWidget {
  const _Bubble({required this.message});
  final ChatMessage message;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isUser = message.role == ChatRole.user;
    return Align(
      alignment: isUser ? Alignment.centerRight : Alignment.centerLeft,
      child: Container(
        margin: const EdgeInsets.symmetric(vertical: 4),
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
        constraints: const BoxConstraints(maxWidth: 520),
        decoration: BoxDecoration(
          color: isUser
              ? theme.colorScheme.primary
              : theme.colorScheme.surfaceContainerHighest,
          borderRadius: BorderRadius.circular(12),
        ),
        child: MessageContent(
          text: message.text,
          color: isUser
              ? theme.colorScheme.onPrimary
              : theme.colorScheme.onSurface,
        ),
      ),
    );
  }
}

class _InputBar extends StatelessWidget {
  const _InputBar({
    required this.controller,
    required this.sending,
    required this.onSend,
  });

  final TextEditingController controller;
  final bool sending;
  final VoidCallback onSend;

  @override
  Widget build(BuildContext context) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.end,
      children: [
        Expanded(
          child: TextField(
            controller: controller,
            minLines: 1,
            maxLines: 5,
            enabled: !sending,
            textInputAction: TextInputAction.send,
            onSubmitted: (_) => onSend(),
            decoration: InputDecoration(
              hintText: 'Message…',
              filled: true,
              fillColor: AppPalette.cardBg,
              contentPadding:
                  const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
              border: _border(AppPalette.divider),
              enabledBorder: _border(AppPalette.divider),
              focusedBorder: _border(AppPalette.accent, width: 1.5),
            ),
          ),
        ),
        const SizedBox(width: 10),
        SizedBox(
          width: 48,
          height: 48,
          child: FilledButton(
            onPressed: sending ? null : onSend,
            style: FilledButton.styleFrom(
              shape: const CircleBorder(),
              padding: EdgeInsets.zero,
            ),
            child: sending
                ? const SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(strokeWidth: 2))
                : const Icon(Icons.arrow_upward_rounded, size: 20),
          ),
        ),
      ],
    );
  }

  OutlineInputBorder _border(Color color, {double width = 1}) =>
      OutlineInputBorder(
        borderRadius: BorderRadius.circular(14),
        borderSide: BorderSide(color: color, width: width),
      );
}
