import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../infrastructure/logging/app_log.dart';
import '../../../../shared/external_launch.dart';
import '../../../../shared/theme/app_theme.dart';
import '../../../../shared/widgets/app_icon_button.dart';
import '../../../../shared/widgets/app_spinner.dart';
import '../../../../shared/widgets/labeled_field.dart';
import '../../../../shared/widgets/toast.dart';
import '../../logic/connector_link_controller.dart';
import '../../logic/connectors_controller.dart';
import '../../logic/favicon_url.dart';
import '../../logic/mcp_auth_probe.dart';
import '../../logic/mcp_input.dart';
import '../../../agents/logic/mcp_server.dart';
import 'connector_mark.dart';

/// Add a new MCP server to Hermes's config.
Future<void> showAddMcpDialog(BuildContext context) =>
    showDialog<void>(context: context, builder: (_) => const _McpDialog());

/// Reopen a configured server to change how it's reached.
///
/// [signedIn] marks a server whose credential the app fetched and owns. Such an
/// entry is still editable — renaming it is a reasonable thing to want — but its
/// URL and headers are not: they are a projection of the token store, and the
/// next refresh would overwrite anything typed over them. The dialog narrows
/// itself accordingly rather than offering fields whose edits silently vanish.
Future<void> showEditMcpDialog(
  BuildContext context,
  McpServer server, {
  bool signedIn = false,
}) => showDialog<void>(
  context: context,
  builder: (_) => _McpDialog(existing: server, signedIn: signedIn),
);

/// How the server is reached — a local process or a remote URL.
///
/// **No longer user-switchable.** Adding always means remote; the local half
/// stays reachable only when *editing* a server that already is one. See
/// [_McpDialogState._transport].
enum _Transport { local, remote }

/// Which of the three screens the dialog is showing.
///
/// Adding a connector is a question asked in stages, not a form filled in one
/// go: *where is it* → *what is it* → *connect to it*. Each stage only exists
/// because the one before it produced an answer, and folding them into a single
/// page is what made the old dialog say "Connected" for a server it had never
/// contacted.
enum _Stage {
  /// Typing the name and URL. Nothing has been asked of the network yet.
  details,

  /// Reaching the server: is it there, and what does it want?
  checking,

  /// It answered. Show what it is, and offer the action that fits.
  found,
}

/// The shared add/edit form. [existing] null means add.
class _McpDialog extends ConsumerStatefulWidget {
  const _McpDialog({this.existing, this.signedIn = false});

  final McpServer? existing;

  /// This entry is a projection of an OAuth token the app holds — see
  /// [showEditMcpDialog].
  final bool signedIn;

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

  /// Fixed for the life of the dialog: [_Transport.remote] when adding, and
  /// whatever the server already is when editing.
  ///
  /// Local is hidden rather than removed, and the difference matters. Servers
  /// with a `command` exist on real machines already; forcing this to `remote`
  /// would show their owner an empty URL form under their server's name, and a
  /// save from there would rewrite a working stdio entry as a broken HTTP one.
  /// Hiding the *choice* stops new local servers being made without touching the
  /// ones that are.
  _Transport _transport = _Transport.remote;

  /// The optional fields, folded away.
  ///
  /// Opens itself when there is already something inside — editing a server with
  /// headers must not hide them, or the user's next save silently rewrites a
  /// field they were never shown.
  bool _advanced = false;

  bool _saving = false;

  /// Which screen is showing. Editing an existing server starts at the details
  /// form and never leaves it — the server is already configured, and re-probing
  /// on the way to a rename would be asking a question nobody posed.
  _Stage _stage = _Stage.details;

  /// Opens the public MCP directory.
  ///
  /// A recognizer rather than a wrapping `GestureDetector`, because the link is
  /// a span inside a sentence and only those characters should be clickable.
  /// Held as a field so it can be disposed: a recognizer built in `build` leaks
  /// one per rebuild.
  late final TapGestureRecognizer _directory = TapGestureRecognizer()
    ..onTap = () =>
        openExternalUrl('https://mcpservers.org/remote-mcp-servers');

  /// What the URL in the box turned out to need, once asked.
  ///
  /// Null until a probe has run for the *current* URL — [_probedUrl] is what
  /// keeps those two from drifting, since a result for a URL the user has since
  /// edited would offer to sign into the wrong server.
  McpAuthProbeResult? _probe;
  String _probedUrl = '';

  /// True when this URL can be signed into without any backend: the provider's
  /// authorization server registers clients on demand, so the app can be its own
  /// OAuth client (path A).
  bool get _canSignIn =>
      _isRemote &&
      _probe?.canSelfRegister == true &&
      _probedUrl == _url.text.trim() &&
      _name.text.trim().isNotEmpty;

  /// The host the icon is looked up from, for the found screen.
  String get _markUrl => _isRemote ? faviconUrl(_url.text.trim()) : '';

  bool get _isEdit => widget.existing != null;

  bool get _isRemote => _transport == _Transport.remote;

  /// Editing an entry the app owns: the name is the user's, everything else is
  /// a projection of the token store and is shown read-only.
  bool get _isManaged => _isEdit && widget.signedIn;

  /// A field sitting on a *raised* dialog, not on the page.
  ///
  /// `LabeledField` defaults to [AppPalette.cardBg], picked to read against the
  /// window; on `AppGlass.surfaceFill` (`#202020` in dark) that lands at 1.023:1
  /// and the unfocused field dissolves into the dialog. [AppCard.inset] recesses
  /// properly at 1.09:1. Light inverts the order — `cardBg` (1.054:1 against
  /// white) beats `inset` there — hence the pick rather than one constant.
  Color get _fieldFill => AppTheme.isDark ? AppCard.inset : AppPalette.cardBg;

  @override
  void initState() {
    super.initState();
    _prefill(widget.existing);
    _advanced = _hasAdvancedContent;
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

  bool get _hasAdvancedContent => _isRemote
      ? _headers.text.trim().isNotEmpty
      : _args.text.trim().isNotEmpty || _env.text.trim().isNotEmpty;

  @override
  void dispose() {
    _name.dispose();
    _command.dispose();
    _args.dispose();
    _env.dispose();
    _url.dispose();
    _headers.dispose();
    _directory.dispose();
    super.dispose();
  }

  bool get _canSave {
    if (_saving || _name.text.trim().isEmpty) return false;
    return _isRemote
        ? _url.text.trim().isNotEmpty
        : _command.text.trim().isNotEmpty;
  }

  McpServer _build() {
    final transport = _isRemote
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
    // The other button. Distinguishing the two in the log is what separates
    // "the sign-in flow broke" from "the sign-in flow was never offered, and
    // this only recorded a URL in the manual store".
    ref
        .read(appLogProvider)
        .info(
          'connectors',
          '${_isEdit ? 'Save' : 'Add'} pressed for "${server.name}" — '
              'manual store only, no sign-in',
        );
    setState(() => _saving = true);

    // A rename writes a new key, so the controller drops the old one first —
    // one call, so this dialog can't get the two-write dance wrong.
    final previous = widget.existing;
    final error = previous != null && previous.name != server.name
        ? await controller.rename(previous.name, server)
        : await controller.save(server);

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

  /// Enter confirms from any single-line field, but only once the form is
  /// actually saveable — otherwise Enter on a half-filled form reads as a
  /// control that does nothing.
  void _submit(String _) {
    if (_canSave) _save();
  }

  /// Step 1: go and look at the URL.
  ///
  /// The user asked for this by pressing Continue, which is the whole reason it
  /// is a stage rather than something that happens behind their back. A probe is
  /// several real requests to a host they just typed; doing it on every focus
  /// change meant a dozen lookups for one URL and no way to tell that any of it
  /// was happening.
  ///
  /// Failure is not fatal here. Every outcome lands on the found screen, which
  /// says what was learned and offers whatever action fits — including "save it
  /// anyway" for a server the app cannot drive.
  Future<void> _check() async {
    final url = _url.text.trim();
    if (!_isRemote || url.isEmpty) return;

    setState(() {
      _stage = _Stage.checking;
      // Clear first: a stale result belongs to the previous URL, and leaving it
      // up would offer to sign into a server the user has navigated away from.
      _probe = null;
      _probedUrl = '';
    });
    final result = await ref.read(mcpAuthProbeProvider).probe(url);
    if (!mounted) return;
    // Which branch the URL landed in decides which button the user gets, so it
    // is the first thing to know when a sign-in didn't happen: "Add" instead of
    // "Connect" means the probe said this server can't be self-registered, not
    // that the OAuth flow broke.
    ref
        .read(appLogProvider)
        .info(
          'connectors',
          'Probed $url → ${result.kind.name} '
              '(issuer ${result.issuer.isEmpty ? '—' : result.issuer}, '
              'registration '
              '${result.registrationEndpoint.isEmpty ? '—' : result.registrationEndpoint}, '
              'S256 ${result.supportsS256})'
              '${result.detail.isEmpty ? '' : ' — ${result.detail}'}',
        );
    setState(() {
      _stage = _Stage.found;
      // Record which URL this answers. The box may have moved on while the
      // network was busy, and [_canSignIn] compares the two.
      _probedUrl = url;
      _probe = result;
      // Open the optional fields when the answer is "you will need a token" —
      // that is where the Headers box is, and leaving it folded away sends the
      // user back to a screen whose one useful control is hidden.
      if (result.kind == McpAuthKind.manual ||
          result.kind == McpAuthKind.preRegistered) {
        _advanced = true;
      }
    });
  }

  /// Sign in through the provider itself, then save.
  ///
  /// This is path A end to end: register with the authorization server, run
  /// PKCE in the system browser, and file the token in the agent-neutral master
  /// store so *every* agent gets it — not just whichever one is selected.
  Future<void> _signIn() async {
    final probe = _probe;
    if (probe == null) return;
    final toast = ToastScope.of(context);
    final navigator = Navigator.of(context);
    final name = _name.text.trim();
    ref
        .read(appLogProvider)
        .info('connectors', 'Connect pressed for "$name" — running path A');
    setState(() => _saving = true);

    final error = await ref
        .read(connectorLinkControllerProvider.notifier)
        .connectDirect(connector: name, mcpUrl: _url.text.trim(), probe: probe);

    if (!mounted) return;
    setState(() => _saving = false);
    // The row explains cancels and timeouts itself, so a null here is not
    // necessarily success — but it is always "nothing more for this dialog to
    // say", and staying open would leave the user with a form they already used.
    navigator.pop();
    if (error != null) {
      toast?.show(ToastSpec(message: error, severity: ToastSeverity.error));
    }
  }

  @override
  Widget build(BuildContext context) {
    // Dialog/overlay content: watch brightness so tokens re-color on theme flip.
    AppTheme.watch(context);
    final theme = Theme.of(context);
    return AlertDialog(
      backgroundColor: AppGlass.surfaceFill,
      surfaceTintColor: Colors.transparent,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
      // Tighter on the right than the left: the close button's box is wider than
      // its glyph, so equal padding would leave the ✕ looking indented against
      // the text below it.
      titlePadding: const EdgeInsets.fromLTRB(28, 22, 20, 0),
      contentPadding: const EdgeInsets.fromLTRB(28, 14, 28, 4),
      actionsPadding: const EdgeInsets.fromLTRB(28, 10, 22, 22),
      title: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  _isEdit ? 'Edit connection' : 'Add custom connector',
                  style: theme.textTheme.headlineSmall?.copyWith(
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
              AppIconButton(
                icon: Icons.close,
                size: 18,
                tooltip: 'Close',
                onPressed: _saving ? null : () => Navigator.of(context).pop(),
              ),
            ],
          ),
          const SizedBox(height: 6),
          // The link is part of the sentence rather than a line of its own: a
          // user who already has a URL reads straight past it, and one who
          // doesn't finds the answer exactly where the question occurs to them.
          // Only on the details screen — once a server has been checked, "go
          // find a server" is behind them.
          if (_isRemote && _stage == _Stage.details)
            Text.rich(
              TextSpan(
                style: theme.textTheme.bodyMedium?.copyWith(
                  color: AppPalette.textSecondary,
                ),
                children: [
                  const TextSpan(
                    text:
                        'Give the assistant tools from an MCP server on the '
                        'web. Browse ',
                  ),
                  TextSpan(
                    text: 'mcpservers.org',
                    style: TextStyle(
                      // accentOnSurface, not accent: #2F5BEA is tuned as a fill
                      // and reaches only 2.6:1 as ink on this dark dialog, while
                      // the dark variant #6E8BFF clears 4.65:1.
                      color: AppPalette.accentOnSurface,
                      decoration: TextDecoration.underline,
                      decorationColor: AppPalette.accentOnSurface,
                    ),
                    recognizer: _directory,
                    // Underlined *and* coloured. Colour alone fails for anyone
                    // who can't distinguish it (WCAG 1.4.1), and this is the
                    // only interactive text in the dialog.
                    mouseCursor: SystemMouseCursors.click,
                  ),
                  const TextSpan(text: ' to find one.'),
                ],
              ),
            )
          else
            Text(
              _isRemote
                  ? 'Give the assistant tools from an MCP server on the web.'
                  : 'Give the assistant tools from a program on this computer.',
              style: theme.textTheme.bodyMedium?.copyWith(
                color: AppPalette.textSecondary,
              ),
            ),
        ],
      ),
      content: SizedBox(
        width: 520,
        child: SingleChildScrollView(
          child: switch (_stage) {
            _Stage.details => _detailsScreen(theme),
            _Stage.checking => _checkingScreen(theme),
            _Stage.found => _foundScreen(theme),
          },
        ),
      ),
      actions: _actions(theme),
    );
  }

  /// Stage 1: where is it.
  Widget _detailsScreen(ThemeData theme) => Column(
    mainAxisSize: MainAxisSize.min,
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      const SizedBox(height: 10),
      LabeledField(
        fill: _fieldFill,
        label: 'Name',
        controller: _name,
        hint: 'notion',
        autofocus: !_isEdit,
        onChanged: (_) => setState(() {}),
        onSubmitted: _submit,
      ),
      const SizedBox(height: 18),
      if (_isManaged)
        // A signed-in connector's URL and headers are written from the token
        // store on every refresh, so an edit here would be reverted within the
        // hour without a word. Shown read-only instead: the value is worth
        // seeing, and a field that silently discards typing is worse than none.
        _ReadOnlyValue(label: 'Remote MCP server URL', value: _url.text)
      else if (_isRemote)
        LabeledField(
          fill: _fieldFill,
          label: 'Remote MCP server URL',
          controller: _url,
          hint: 'https://mcp.notion.com/mcp',
          onChanged: (_) => setState(() {}),
          onSubmitted: _submit,
        )
      else
        LabeledField(
          fill: _fieldFill,
          label: 'Command',
          controller: _command,
          hint: 'npx',
          onChanged: (_) => setState(() {}),
          onSubmitted: _submit,
        ),
      // Editing an existing server keeps its optional fields to hand; adding one
      // does not, because everything optional is decided after the check. A
      // managed entry has none to offer — its headers carry the credential.
      if (!_isManaged && (_isEdit || !_isRemote)) ...[
        const SizedBox(height: 14),
        _AdvancedToggle(
          open: _advanced,
          onTap: () => setState(() => _advanced = !_advanced),
        ),
        if (_advanced) ...[const SizedBox(height: 14), ..._advancedFields()],
      ],
      const SizedBox(height: 20),
      if (_isManaged)
        Text(
          'Signed in through Grid. The address and credential are managed for '
          'you and refresh automatically — disconnect from the list to remove '
          'them.',
          style: theme.textTheme.bodySmall?.copyWith(
            color: AppPalette.textSecondary,
            height: 1.45,
          ),
        )
      else
        _trustNotice(theme),
      const SizedBox(height: 4),
    ],
  );

  /// Stage 2: going to look.
  ///
  /// Shows the icon it is about to claim, so the wait itself carries information
  /// — the mark appearing is the first sign the host is real.
  Widget _checkingScreen(ThemeData theme) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 44),
    child: Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        ConnectorMark(imageUrl: _markUrl, fallbackIcon: Icons.cloud_outlined),
        const SizedBox(height: 20),
        const AppSpinner(),
        const SizedBox(height: 16),
        Text(
          'Checking connection…',
          style: theme.textTheme.bodyMedium?.copyWith(
            color: AppPalette.textSecondary,
          ),
        ),
      ],
    ),
  );

  /// Stage 3: what it turned out to be.
  Widget _foundScreen(ThemeData theme) {
    final probe = _probe;
    final reachable = probe != null && probe.kind != McpAuthKind.unreachable;
    return Padding(
      padding: const EdgeInsets.only(top: 24, bottom: 8),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          ConnectorMark(
            imageUrl: reachable ? _markUrl : '',
            fallbackIcon: reachable
                ? Icons.cloud_outlined
                : Icons.cloud_off_outlined,
          ),
          const SizedBox(height: 14),
          Text(
            _url.text.trim(),
            textAlign: TextAlign.center,
            style: theme.textTheme.bodySmall?.copyWith(
              color: AppPalette.textSecondary,
            ),
          ),
          const SizedBox(height: 14),
          Text(
            _foundHeadline,
            textAlign: TextAlign.center,
            style: theme.textTheme.bodyLarge,
          ),
          if (_foundDetail.isNotEmpty) ...[
            const SizedBox(height: 8),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 24),
              child: Text(
                _foundDetail,
                textAlign: TextAlign.center,
                style: theme.textTheme.bodySmall?.copyWith(
                  color: AppPalette.textSecondary,
                  height: 1.45,
                ),
              ),
            ),
          ],
          // A server that wants a hand-pasted token needs its Headers box on
          // this screen — sending the user back a step for the one control that
          // could help would be the dialog hiding its own answer.
          if (reachable && !_canSignIn) ...[
            const SizedBox(height: 20),
            _AdvancedToggle(
              open: _advanced,
              onTap: () => setState(() => _advanced = !_advanced),
            ),
            if (_advanced) ...[
              const SizedBox(height: 14),
              ..._advancedFields(),
            ],
          ],
          const SizedBox(height: 20),
          _trustNotice(theme),
        ],
      ),
    );
  }

  /// The headline on the found screen — what this server *is*.
  String get _foundHeadline {
    final name = _name.text.trim();
    return switch (_probe?.kind) {
      McpAuthKind.unreachable => "That server couldn't be reached.",
      McpAuthKind.dynamicRegistration => 'You are not connected to $name yet.',
      McpAuthKind.open => '$name is ready to add.',
      McpAuthKind.preRegistered => '$name needs a token.',
      McpAuthKind.manual || null => '$name needs a token.',
    };
  }

  /// The sentence under it — why, and what happens next.
  String get _foundDetail {
    final probe = _probe;
    return switch (probe?.kind) {
      McpAuthKind.unreachable => probe!.detail,
      McpAuthKind.dynamicRegistration =>
        'Connect opens your browser to sign in. The account will work for '
            'every agent on this computer.',
      McpAuthKind.open =>
        'This server needs no sign-in — the assistant can use its tools as '
            'soon as it is added.',
      McpAuthKind.preRegistered =>
        'This server requires an app registered with it in advance, so it '
            'cannot be signed into from here yet. Paste a token below if you '
            'have one.',
      McpAuthKind.manual =>
        probe!.detail.isEmpty
            ? 'Paste a token below if this server needs one.'
            : probe.detail,
      null => '',
    };
  }

  Widget _trustNotice(ThemeData theme) => Text(
    'Only add servers from developers you trust. The assistant can call '
    'whatever tools a server exposes, and Grid cannot check what those are or '
    'whether they change.',
    textAlign: _stage == _Stage.found ? TextAlign.center : TextAlign.start,
    style: theme.textTheme.bodySmall?.copyWith(
      // Not textFaint: measured against this dialog's own fill
      // (AppGlass.surfaceFill, #202020 in dark) it reaches only 3.18:1, under
      // the 4.5:1 body-text floor. textSecondary is 6.82:1 dark, 6.21:1 light.
      color: AppPalette.textSecondary,
      height: 1.45,
    ),
  );

  /// The buttons, which differ per stage.
  List<Widget> _actions(ThemeData theme) {
    // Nothing to press while the network is being asked. Cancel stays, because
    // a probe against a dead host runs out its timeout and the user should not
    // have to wait for it.
    if (_stage == _Stage.checking) {
      return [
        TextButton(
          onPressed: () => setState(() => _stage = _Stage.details),
          child: const Text('Cancel'),
        ),
      ];
    }

    if (_stage == _Stage.found) {
      return [
        TextButton(
          onPressed: _saving
              ? null
              : () => setState(() => _stage = _Stage.details),
          child: const Text('Back'),
        ),
        const SizedBox(width: 4),
        if (_probe?.kind == McpAuthKind.unreachable)
          // Nothing answered, so there is nothing to connect to — but the user
          // may still know better than the probe (a server that is down right
          // now, a host only reachable later), so saving stays available.
          FilledButton(
            onPressed: _canSave ? _save : null,
            child: Text(_saving ? 'Saving…' : 'Add anyway'),
          )
        else if (_canSignIn)
          FilledButton(
            onPressed: _saving ? null : _signIn,
            child: Text(_saving ? 'Connecting…' : 'Connect'),
          )
        else
          FilledButton(
            onPressed: _canSave ? _save : null,
            child: Text(_saving ? 'Saving…' : 'Add'),
          ),
      ];
    }

    return [
      TextButton(
        onPressed: _saving ? null : () => Navigator.of(context).pop(),
        child: const Text('Cancel'),
      ),
      const SizedBox(width: 4),
      // Adding a remote server goes through the check first — that is the whole
      // point of the staged flow. Editing, and the local-command form, save
      // directly: there is nothing to discover about either.
      if (_isRemote && !_isEdit)
        FilledButton(
          onPressed: _canSave ? _check : null,
          child: const Text('Continue'),
        )
      else
        FilledButton(
          onPressed: _canSave ? _save : null,
          child: Text(_saving ? 'Saving…' : (_isEdit ? 'Save' : 'Add')),
        ),
    ];
  }

  /// The optional half, whichever transport this is.
  List<Widget> _advancedFields() => _isRemote
      ? [
          LabeledField(
            fill: _fieldFill,
            label: 'Headers (Name: value, one per line)',
            controller: _headers,
            hint: 'Authorization: Bearer …',
            minLines: 2,
            maxLines: 4,
          ),
        ]
      : [
          LabeledField(
            fill: _fieldFill,
            label: 'Arguments (one per line)',
            controller: _args,
            hint: '-y\n@modelcontextprotocol/server-notion',
            minLines: 2,
            maxLines: 5,
          ),
          const SizedBox(height: 18),
          LabeledField(
            fill: _fieldFill,
            label: 'Environment (KEY=value, one per line)',
            controller: _env,
            hint: 'NOTION_TOKEN=secret_…',
            minLines: 2,
            maxLines: 4,
          ),
        ];
}

/// A labelled value the user can read but not change.
///
/// Built from [FieldLabel] plus a plain box rather than a disabled [LabeledField]
/// — a greyed-out text field invites a click and then refuses it, which reads as
/// broken. This says "here is the value" without pretending to be an input.
class _ReadOnlyValue extends StatelessWidget {
  const _ReadOnlyValue({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    AppTheme.watch(context); // reads AppPalette / AppCard tokens.
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        FieldLabel(label),
        Container(
          width: double.infinity,
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 13),
          decoration: BoxDecoration(
            // The same recessed fill an editable field gets on this dialog, so
            // the two read as the same kind of thing at a glance.
            color: AppTheme.isDark ? AppCard.inset : AppPalette.cardBg,
            borderRadius: BorderRadius.circular(12),
          ),
          child: SelectableText(
            value,
            style: TextStyle(
              fontSize: 14,
              height: 1.4,
              // Quieter than an editable value: it is information, not input.
              color: AppPalette.textSecondary,
            ),
          ),
        ),
      ],
    );
  }
}

/// The "Advanced settings" disclosure line.
///
/// Owns its own hover, because nothing above it does: a parent that lightens on
/// hover cannot tell this row where the pointer is, and a label that keeps its
/// resting ink under the cursor reads as a caption rather than something to
/// press. Both the text and the chevron climb — the row *is* the affordance, so
/// half of it lifting would look like a rendering bug.
class _AdvancedToggle extends StatefulWidget {
  const _AdvancedToggle({required this.open, required this.onTap});

  final bool open;
  final VoidCallback onTap;

  @override
  State<_AdvancedToggle> createState() => _AdvancedToggleState();
}

class _AdvancedToggleState extends State<_AdvancedToggle> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    AppTheme.watch(context); // reads AppPalette / AppSurface tokens.
    final ink = _hovered ? AppPalette.textPrimary : AppPalette.textSecondary;
    return Align(
      alignment: Alignment.centerLeft,
      child: MouseRegion(
        cursor: SystemMouseCursors.click,
        onEnter: (_) => setState(() => _hovered = true),
        onExit: (_) => setState(() => _hovered = false),
        child: GestureDetector(
          onTap: widget.onTap,
          child: AnimatedContainer(
            duration: AppMotion.hover,
            curve: AppMotion.curve,
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
            decoration: BoxDecoration(
              color: _hovered ? AppSurface.hoverFill : Colors.transparent,
              // 7 — the app's radius for a small inline control, and never
              // rounder than the 12 of the fields it sits between.
              borderRadius: BorderRadius.circular(7),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                // Points down at what it opened — the same turn the rest of the
                // app's disclosures use, so one chevron language runs through.
                AnimatedRotation(
                  turns: widget.open ? 0.5 : 0,
                  duration: AppMotion.hover,
                  curve: AppMotion.curve,
                  child: Icon(Icons.expand_more_rounded, size: 18, color: ink),
                ),
                const SizedBox(width: 4),
                Text(
                  'Advanced settings',
                  style: TextStyle(
                    fontSize: 12.5,
                    fontWeight: AppFont.medium,
                    color: ink,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
