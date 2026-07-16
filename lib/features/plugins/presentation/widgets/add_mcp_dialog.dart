import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../shared/theme/app_theme.dart';
import '../../../../shared/widgets/labeled_field.dart';
import '../../../../shared/widgets/pill_choice.dart';
import '../../../../shared/widgets/toast.dart';
import '../../logic/mcp_controller.dart';
import '../../logic/mcp_input.dart';
import '../../logic/mcp_server.dart';

/// Add a new MCP server to Hermes's config.
Future<void> showAddMcpDialog(BuildContext context) =>
    showDialog<void>(context: context, builder: (_) => const _McpDialog());

/// Reopen a configured server to change how it's reached.
Future<void> showEditMcpDialog(BuildContext context, McpServer server) =>
    showDialog<void>(
      context: context,
      builder: (_) => _McpDialog(existing: server),
    );

/// How the server is reached — a local process or a remote URL. Drives which
/// half of the form shows.
enum _Transport { local, remote }

/// The shared add/edit form. [existing] null means add.
class _McpDialog extends ConsumerStatefulWidget {
  const _McpDialog({this.existing});

  final McpServer? existing;

  @override
  ConsumerState<_McpDialog> createState() => _McpDialogState();
}

class _McpDialogState extends ConsumerState<_McpDialog> {
  final _name = TextEditingController();
  final _command = TextEditingController();
  final _args = TextEditingController();
  final _env = TextEditingController();
  final _url = TextEditingController();
  final _headers = TextEditingController();
  _Transport _transport = _Transport.local;
  bool _saving = false;

  bool get _isEdit => widget.existing != null;

  @override
  void initState() {
    super.initState();
    _prefill(widget.existing);
  }

  void _prefill(McpServer? server) {
    if (server == null) return;
    _name.text = server.name;
    switch (server.transport) {
      case McpStdio(:final command, :final args, :final env):
        _transport = _Transport.local;
        _command.text = command;
        _args.text = args.join('\n');
        _env.text = [
          for (final e in env.entries) '${e.key}=${e.value}',
        ].join('\n');
      case McpHttp(:final url, :final headers):
        _transport = _Transport.remote;
        _url.text = url;
        _headers.text = [
          for (final h in headers.entries) '${h.key}: ${h.value}',
        ].join('\n');
    }
  }

  @override
  void dispose() {
    _name.dispose();
    _command.dispose();
    _args.dispose();
    _env.dispose();
    _url.dispose();
    _headers.dispose();
    super.dispose();
  }

  bool get _canSave {
    if (_saving || _name.text.trim().isEmpty) return false;
    return _transport == _Transport.local
        ? _command.text.trim().isNotEmpty
        : _url.text.trim().isNotEmpty;
  }

  McpServer _build() {
    final transport = _transport == _Transport.remote
        ? McpHttp(
            url: _url.text.trim(),
            headers: parseHeaderLines(_headers.text),
          )
        : McpStdio(
            command: _command.text.trim(),
            args: parseArgLines(_args.text),
            env: parseEnvLines(_env.text),
          );
    return McpServer(name: _name.text.trim(), transport: transport);
  }

  Future<void> _save() async {
    final toast = ToastScope.of(context);
    final navigator = Navigator.of(context);
    final controller = ref.read(mcpServersProvider.notifier);
    final server = _build();
    setState(() => _saving = true);

    // A rename writes a new key, so drop the old one first, or both would linger.
    final previous = widget.existing;
    if (previous != null && previous.name != server.name) {
      await controller.remove(previous.name);
    }
    final error = await controller.save(server);

    if (!mounted) return;
    setState(() => _saving = false);
    if (error != null) {
      toast?.show(ToastSpec(message: error, severity: ToastSeverity.error));
      return;
    }
    navigator.pop();
    toast?.show(
      ToastSpec(
        message: '${server.name} is ready.',
        severity: ToastSeverity.success,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    // Dialog/overlay content: watch brightness so tokens re-color on theme flip.
    AppTheme.watch(context);
    final theme = Theme.of(context);
    return AlertDialog(
      backgroundColor: AppPalette.windowBg,
      surfaceTintColor: Colors.transparent,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
      titlePadding: const EdgeInsets.fromLTRB(28, 26, 28, 0),
      contentPadding: const EdgeInsets.fromLTRB(28, 14, 28, 4),
      actionsPadding: const EdgeInsets.fromLTRB(28, 10, 22, 22),
      title: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            _isEdit ? 'Edit MCP server' : 'Add an MCP server',
            style: theme.textTheme.headlineSmall?.copyWith(
              fontWeight: FontWeight.w600,
            ),
          ),
          const SizedBox(height: 6),
          Text(
            'Give the assistant tools from another program — running locally or '
            'reached over the web.',
            style: theme.textTheme.bodyMedium?.copyWith(
              color: AppPalette.textSecondary,
            ),
          ),
        ],
      ),
      content: SizedBox(
        width: 560,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const SizedBox(height: 10),
              LabeledField(
                label: 'Name',
                controller: _name,
                hint: 'notion',
                autofocus: !_isEdit,
                onChanged: (_) => setState(() {}),
              ),
              const SizedBox(height: 20),
              _TransportToggle(
                value: _transport,
                onChanged: (value) => setState(() => _transport = value),
              ),
              const SizedBox(height: 20),
              if (_transport == _Transport.local)
                ..._localFields()
              else
                ..._remoteFields(),
              const SizedBox(height: 4),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: _saving ? null : () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        const SizedBox(width: 4),
        FilledButton(
          onPressed: _canSave ? _save : null,
          child: Text(_saving ? 'Saving…' : (_isEdit ? 'Save' : 'Add server')),
        ),
      ],
    );
  }

  List<Widget> _localFields() => [
    LabeledField(
      label: 'Command',
      controller: _command,
      hint: 'npx',
      onChanged: (_) => setState(() {}),
    ),
    const SizedBox(height: 18),
    LabeledField(
      label: 'Arguments (one per line)',
      controller: _args,
      hint: '-y\n@modelcontextprotocol/server-notion',
      minLines: 2,
      maxLines: 5,
    ),
    const SizedBox(height: 18),
    LabeledField(
      label: 'Environment (KEY=value, one per line)',
      controller: _env,
      hint: 'NOTION_TOKEN=secret_…',
      minLines: 2,
      maxLines: 4,
    ),
  ];

  List<Widget> _remoteFields() => [
    LabeledField(
      label: 'URL',
      controller: _url,
      hint: 'https://mcp.notion.com/mcp',
      onChanged: (_) => setState(() {}),
    ),
    const SizedBox(height: 18),
    LabeledField(
      label: 'Headers (Name: value, one per line)',
      controller: _headers,
      hint: 'Authorization: Bearer …',
      minLines: 2,
      maxLines: 4,
    ),
  ];
}

/// The Local / Remote switch above the transport-specific fields — the app's
/// own soft segmented pills, not a hard-outlined Material control.
class _TransportToggle extends StatelessWidget {
  const _TransportToggle({required this.value, required this.onChanged});

  final _Transport value;
  final ValueChanged<_Transport> onChanged;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        PillChoice(
          label: const Text('Local command'),
          icon: Icons.terminal_rounded,
          selected: value == _Transport.local,
          onTap: () => onChanged(_Transport.local),
        ),
        const SizedBox(width: 8),
        PillChoice(
          label: const Text('Remote URL'),
          icon: Icons.cloud_outlined,
          selected: value == _Transport.remote,
          onTap: () => onChanged(_Transport.remote),
        ),
      ],
    );
  }
}
