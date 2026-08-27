import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../shared/widgets/app_dialog.dart';
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

part 'add_mcp_dialog_actions.dart';
part 'add_mcp_dialog_screens.dart';

/// Add a new MCP server to Hermes's config.
///
/// [initialName] and [initialUrl] prefill the form. The browse dialog uses them
/// to hand over a directory entry the app cannot sign into on its own: rather
/// than dead-ending on "this server needs a token", it opens the form the user
/// would otherwise have had to find and retype the address into, already on the
/// screen that has the Headers box.
Future<void> showAddMcpDialog(
  BuildContext context, {
  String initialName = '',
  String initialUrl = '',
}) => showAppDialog<void>(
  context: context,
  builder: (_) => _McpDialog(initialName: initialName, initialUrl: initialUrl),
);

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
}) => showAppDialog<void>(
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
  const _McpDialog({
    this.existing,
    this.signedIn = false,
    this.initialName = '',
    this.initialUrl = '',
  });

  final McpServer? existing;

  /// Prefill for the add case — see [showAddMcpDialog]. Ignored when [existing]
  /// is set: an edit's fields come from the server being edited, and letting a
  /// caller override those would be a way to rewrite a working entry by
  /// accident.
  final String initialName;
  final String initialUrl;

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

  /// The browser is open and the app is parked on the loopback callback.
  ///
  /// Tracked apart from [_saving] because the two are nothing alike in length.
  /// Saving is a file write and locking the dialog for it is invisible; a
  /// sign-in waits **five minutes** for a callback that never arrives once the
  /// user has closed the tab, and locking the dialog for *that* is the bug this
  /// flag exists to end.
  bool _signingIn = false;

  /// Watched so the URL's error waits for the user to leave the field. Reddening
  /// on the first keystroke — while `h` is not yet `https` — is a field that
  /// fights whoever is typing in it.
  final _urlFocus = FocusNode();

  /// Set once a press has been refused for a bad URL. After that the error stays
  /// visible while they fix it, rather than vanishing the moment focus returns
  /// and leaving a button that does nothing for no stated reason.
  bool _urlRejected = false;

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

  /// True when the URL can't be used, having just said so on screen.
  ///
  /// Called at the top of every action that would send the address somewhere: an
  /// `http` URL silently rewritten to `https` would point at a different server
  /// than the one typed, and one saved as-is would carry a credential in the
  /// clear.
  bool _refuseBadUrl() {
    if (!_isRemote || _urlProblem == null) return false;
    setState(() => _urlRejected = true);
    return true;
  }

  /// What's wrong with the typed URL, or null when nothing is.
  String? get _urlProblem => mcpUrlProblem(_url.text);

  /// The problem, only once it is fair to show it.
  String? get _shownUrlProblem =>
      (_urlFocus.hasFocus && !_urlRejected) ? null : _urlProblem;

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
    // The error appears on blur, and blur is not a rebuild on its own.
    _urlFocus.addListener(() {
      if (mounted) setState(() {});
    });
    _prefill(widget.existing);
    _advanced = _hasAdvancedContent;
  }

  void _prefill(McpServer? server) {
    if (server == null) {
      // The add case, possibly handed an address by the browse dialog. Left at
      // [_Stage.details] rather than probed on open: the probe is several
      // requests to a third-party host, and doing it before the user has said
      // "this one" would fire on every dialog that happens to be prefilled.
      _name.text = widget.initialName;
      _url.text = widget.initialUrl;
      return;
    }
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
    _urlFocus.dispose();
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
    // Deliberately *not* gated on the URL being valid. A dead button is the
    // worst way to report a bad address — it states nothing and leaves the user
    // hunting. The press is allowed through and refused by [_refuseBadUrl],
    // which says why.
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
    if (_refuseBadUrl()) return;
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

    // Same rule as the connect path: the toast belongs to the screen, not to
    // this dialog, and reporting the outcome of a write that already happened
    // must not depend on the dialog still being open. Only the two things that
    // genuinely need this widget are guarded — `setState`, and the pop, which
    // would otherwise close whatever route replaced this one.
    if (mounted) setState(() => _saving = false);
    if (error != null) {
      toast?.show(ToastSpec(message: error, severity: ToastSeverity.error));
      return;
    }
    if (mounted) navigator.pop();
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
    if (_refuseBadUrl()) return;
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
    setState(() {
      _saving = true;
      _signingIn = true;
    });

    final error = await ref
        .read(connectorLinkControllerProvider.notifier)
        .connectDirect(connector: name, mcpUrl: _url.text.trim(), probe: probe);

    // `!_signingIn` as well as `!mounted`, and the second test is the load
    // bearing one. Closing the dialog pops the route immediately but disposes
    // this state only once the route has animated out, so for ~200ms after the
    // user leaves, `mounted` is still true — long enough for the aborted
    // `connectDirect` to return here and run `navigator.pop()` a **second**
    // time, taking whatever route is now on top with it. [_abortSignIn] clears
    // the flag, which is what makes "the user already let themselves out"
    // answerable.
    if (!mounted || !_signingIn) return;
    setState(() {
      _saving = false;
      _signingIn = false;
    });
    // The row explains cancels and timeouts itself, so a null here is not
    // necessarily success — but it is always "nothing more for this dialog to
    // say", and staying open would leave the user with a form they already used.
    navigator.pop();
    if (error != null) {
      toast?.show(ToastSpec(message: error, severity: ToastSeverity.error));
    }
  }

  /// Stop waiting for a callback that isn't coming.
  ///
  /// Called from [PopScope] rather than from the buttons, so it covers *every*
  /// way out of this dialog — the ✕, Cancel, Esc, a tap on the barrier — with
  /// one line each of them cannot forget. Closing the dialog while the listener
  /// stayed bound was its own quieter bug: the port held for the rest of the
  /// five minutes, and the next Connect had to bind a different one, which some
  /// authorization servers refuse because the `redirect_uri` no longer matches
  /// the registration.
  ///
  /// [ConnectorLinkController.cancel] is what actually ends it — it aborts the
  /// loopback wait, so `connectDirect` returns at once instead of on the
  /// timeout.
  void _abortSignIn() {
    if (!_signingIn) return;
    _signingIn = false;
    ref.read(connectorLinkControllerProvider.notifier).cancel();
    ref
        .read(appLogProvider)
        .info('connectors', 'Sign-in dialog closed — abandoning the wait');
  }

  @override
  Widget build(BuildContext context) {
    // Dialog/overlay content: watch brightness so tokens re-color on theme flip.
    AppTheme.watch(context);
    // The dialog always closes; what this hooks is the *aftermath*. Blocking
    // the pop and asking "are you sure" would be the wrong shape — the user has
    // already decided, and the thing to clean up is the listener, not their
    // mind.
    return PopScope<void>(
      onPopInvokedWithResult: (didPop, _) {
        if (didPop) _abortSignIn();
      },
      child: AlertDialog(
        backgroundColor: AppGlass.surfaceFill,
        surfaceTintColor: Colors.transparent,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        // Tighter on the right than the left: the close button's box is wider than
        // its glyph, so equal padding would leave the ✕ looking indented against
        // the text below it.
        titlePadding: const EdgeInsets.fromLTRB(28, 22, 20, 0),
        contentPadding: const EdgeInsets.fromLTRB(28, 14, 28, 4),
        actionsPadding: const EdgeInsets.fromLTRB(28, 10, 22, 22),
        title: _DialogTitle(
          isEdit: _isEdit,
          isRemote: _isRemote,
          showDirectoryLink: _isRemote && _stage == _Stage.details,
          directory: _directory,
          // Locked only for the file write. A sign-in keeps its ✕: it is the
          // button anyone reaches for after closing the browser tab, and
          // disabling it was what turned "I changed my mind" into a five-minute
          // wait with no way out.
          onClose: _saving && !_signingIn
              ? null
              : () => Navigator.of(context).pop(),
        ),
        content: SizedBox(
          width: 520,
          child: SingleChildScrollView(
            child: switch (_stage) {
              _Stage.details => _DetailsScreen(
                isEdit: _isEdit,
                isRemote: _isRemote,
                isManaged: _isManaged,
                fieldFill: _fieldFill,
                name: _name,
                url: _url,
                command: _command,
                urlFocus: _urlFocus,
                urlProblem: _shownUrlProblem,
                advanced: _advanced,
                advancedFields: _advancedFields,
                onToggleAdvanced: () => setState(() => _advanced = !_advanced),
                onChanged: () => setState(() {}),
                onSubmitted: _submit,
              ),
              _Stage.checking => _CheckingScreen(markUrl: _markUrl),
              _Stage.found => _FoundScreen(
                probe: _probe,
                markUrl: _markUrl,
                address: _url.text.trim(),
                name: _name.text.trim(),
                canSignIn: _canSignIn,
                advanced: _advanced,
                advancedFields: _advancedFields,
                onToggleAdvanced: () => setState(() => _advanced = !_advanced),
              ),
            },
          ),
        ),
        actions: [
          _DialogActions(
            stage: _stage,
            saving: _saving,
            signingIn: _signingIn,
            primary: _primary,
            onCancel: () => Navigator.of(context).pop(),
            onBack: () => setState(() => _stage = _Stage.details),
          ),
        ],
      ),
    );
  }

  /// The button that moves the dialog on: what it says, and what it does.
  ///
  /// One place, because which of the four it is depends on the stage *and* on
  /// what the probe found — a server nothing answered for can still be saved,
  /// one that offers a sign-in gets Connect instead of Add.
  ({String label, VoidCallback? onPressed}) get _primary {
    if (_stage == _Stage.found) {
      if (_probe?.kind == McpAuthKind.unreachable) {
        // Nothing answered, so there is nothing to connect to — but the user
        // may still know better than the probe (a server that is down right
        // now, a host only reachable later), so saving stays available.
        return (
          label: _saving ? 'Saving…' : 'Add anyway',
          onPressed: _canSave ? _save : null,
        );
      }
      if (_canSignIn) {
        return (
          label: _saving ? 'Connecting…' : 'Connect',
          onPressed: _saving ? null : _signIn,
        );
      }
      return (
        label: _saving ? 'Saving…' : 'Add',
        onPressed: _canSave ? _save : null,
      );
    }
    // Adding a remote server goes through the check first — that is the whole
    // point of the staged flow. Editing, and the local-command form, save
    // directly: there is nothing to discover about either.
    if (_isRemote && !_isEdit) {
      return (label: 'Continue', onPressed: _canSave ? _check : null);
    }
    return (
      label: _saving ? 'Saving…' : (_isEdit ? 'Save' : 'Add'),
      onPressed: _canSave ? _save : null,
    );
  }

  /// The optional half, built here because both screens that can show it need
  /// the same controllers.
  Widget get _advancedFields => _AdvancedFields(
    isRemote: _isRemote,
    fill: _fieldFill,
    headers: _headers,
    args: _args,
    env: _env,
  );
}
