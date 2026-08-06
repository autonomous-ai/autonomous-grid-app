part of 'add_mcp_dialog.dart';

/// The dialog's headline and the sentence under it — what this screen is for,
/// and (on the form, for a remote server) where to go find one.
class _DialogTitle extends StatelessWidget {
  const _DialogTitle({
    required this.isEdit,
    required this.isRemote,
    required this.showDirectoryLink,
    required this.directory,
    required this.onClose,
  });

  final bool isEdit;
  final bool isRemote;

  /// Only on the form: once a server has been checked, "go find a server" is
  /// behind the user.
  final bool showDirectoryLink;

  /// Opens the public MCP directory. Owned by the dialog so it outlives this
  /// widget's rebuilds — a recognizer built in `build` leaks one per frame.
  final TapGestureRecognizer directory;

  /// Null while the dialog is locked for the file write.
  final VoidCallback? onClose;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Expanded(
              child: Text(
                isEdit ? 'Edit connection' : 'Add custom connector',
                style: theme.textTheme.headlineSmall?.copyWith(
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
            AppIconButton(
              icon: Icons.close,
              size: 18,
              tooltip: 'Close',
              onPressed: onClose,
            ),
          ],
        ),
        const SizedBox(height: 6),
        // The link is part of the sentence rather than a line of its own: a
        // user who already has a URL reads straight past it, and one who
        // doesn't finds the answer exactly where the question occurs to them.
        if (showDirectoryLink)
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
                  recognizer: directory,
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
            isRemote
                ? 'Give the assistant tools from an MCP server on the web.'
                : 'Give the assistant tools from a program on this computer.',
            style: theme.textTheme.bodyMedium?.copyWith(
              color: AppPalette.textSecondary,
            ),
          ),
      ],
    );
  }
}

/// Stage 1: where is it.
class _DetailsScreen extends StatelessWidget {
  const _DetailsScreen({
    required this.isEdit,
    required this.isRemote,
    required this.isManaged,
    required this.fieldFill,
    required this.name,
    required this.url,
    required this.command,
    required this.urlFocus,
    required this.urlProblem,
    required this.advanced,
    required this.advancedFields,
    required this.onToggleAdvanced,
    required this.onChanged,
    required this.onSubmitted,
  });

  final bool isEdit;
  final bool isRemote;

  /// A connector signed into through Grid: its URL and headers are rewritten
  /// from the token store, so the form shows them rather than offering them.
  final bool isManaged;

  final Color fieldFill;
  final TextEditingController name;
  final TextEditingController url;
  final TextEditingController command;
  final FocusNode urlFocus;

  /// What is wrong with the URL, once it's the user's turn to hear it.
  final String? urlProblem;

  /// Whether the optional half is folded open, and what is in it.
  final bool advanced;
  final Widget advancedFields;
  final VoidCallback onToggleAdvanced;

  final VoidCallback onChanged;
  final ValueChanged<String> onSubmitted;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const SizedBox(height: 10),
        LabeledField(
          fill: fieldFill,
          label: 'Name',
          controller: name,
          hint: 'notion',
          autofocus: !isEdit,
          onChanged: (_) => onChanged(),
          onSubmitted: onSubmitted,
        ),
        const SizedBox(height: 18),
        if (isManaged)
          // A signed-in connector's URL and headers are written from the token
          // store on every refresh, so an edit here would be reverted within the
          // hour without a word. Shown read-only instead: the value is worth
          // seeing, and a field that silently discards typing is worse than none.
          _ReadOnlyValue(label: 'Remote MCP server URL', value: url.text)
        else if (isRemote)
          LabeledField(
            fill: fieldFill,
            label: 'Remote MCP server URL',
            controller: url,
            focusNode: urlFocus,
            hint: 'https://mcp.notion.com/mcp',
            error: urlProblem,
            onChanged: (_) => onChanged(),
            onSubmitted: onSubmitted,
          )
        else
          LabeledField(
            fill: fieldFill,
            label: 'Command',
            controller: command,
            hint: 'npx',
            onChanged: (_) => onChanged(),
            onSubmitted: onSubmitted,
          ),
        // Editing an existing server keeps its optional fields to hand; adding
        // one does not, because everything optional is decided after the check.
        // A managed entry has none to offer — its headers carry the credential.
        if (!isManaged && (isEdit || !isRemote)) ...[
          const SizedBox(height: 14),
          _AdvancedToggle(open: advanced, onTap: onToggleAdvanced),
          if (advanced) ...[const SizedBox(height: 14), advancedFields],
        ],
        const SizedBox(height: 20),
        if (isManaged)
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
          const _TrustNotice(centered: false),
        const SizedBox(height: 4),
      ],
    );
  }
}

/// Stage 2: going to look.
///
/// Shows the icon it is about to claim, so the wait itself carries information
/// — the mark appearing is the first sign the host is real.
class _CheckingScreen extends StatelessWidget {
  const _CheckingScreen({required this.markUrl});

  final String markUrl;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 44),
    child: Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        ConnectorMark(imageUrl: markUrl, fallbackIcon: Icons.cloud_outlined),
        const SizedBox(height: 20),
        const AppSpinner(),
        const SizedBox(height: 16),
        Text(
          'Checking connection…',
          style: Theme.of(
            context,
          ).textTheme.bodyMedium?.copyWith(color: AppPalette.textSecondary),
        ),
      ],
    ),
  );
}

/// Stage 3: what it turned out to be.
class _FoundScreen extends StatelessWidget {
  const _FoundScreen({
    required this.probe,
    required this.markUrl,
    required this.address,
    required this.name,
    required this.canSignIn,
    required this.advanced,
    required this.advancedFields,
    required this.onToggleAdvanced,
  });

  final McpAuthProbeResult? probe;
  final String markUrl;

  /// The URL as typed — repeated here because this screen is the last place to
  /// notice it was the wrong one.
  final String address;

  /// What the user called the server, which is what the headline talks about.
  final String name;

  final bool canSignIn;
  final bool advanced;
  final Widget advancedFields;
  final VoidCallback onToggleAdvanced;

  bool get _reachable =>
      probe != null && probe!.kind != McpAuthKind.unreachable;

  /// The headline — what this server *is*.
  String get _headline => switch (probe?.kind) {
    McpAuthKind.unreachable => "That server couldn't be reached.",
    McpAuthKind.dynamicRegistration => 'You are not connected to $name yet.',
    McpAuthKind.open => '$name is ready to add.',
    McpAuthKind.preRegistered => '$name needs a token.',
    McpAuthKind.manual || null => '$name needs a token.',
  };

  /// The sentence under it — why, and what happens next.
  String get _detail => switch (probe?.kind) {
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
          : probe!.detail,
    null => '',
  };

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.only(top: 24, bottom: 8),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          ConnectorMark(
            imageUrl: _reachable ? markUrl : '',
            fallbackIcon: _reachable
                ? Icons.cloud_outlined
                : Icons.cloud_off_outlined,
          ),
          const SizedBox(height: 14),
          Text(
            address,
            textAlign: TextAlign.center,
            style: theme.textTheme.bodySmall?.copyWith(
              color: AppPalette.textSecondary,
            ),
          ),
          const SizedBox(height: 14),
          Text(
            _headline,
            textAlign: TextAlign.center,
            style: theme.textTheme.bodyLarge,
          ),
          if (_detail.isNotEmpty) ...[
            const SizedBox(height: 8),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 24),
              child: Text(
                _detail,
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
          if (_reachable && !canSignIn) ...[
            const SizedBox(height: 20),
            _AdvancedToggle(open: advanced, onTap: onToggleAdvanced),
            if (advanced) ...[const SizedBox(height: 14), advancedFields],
          ],
          const SizedBox(height: 20),
          const _TrustNotice(centered: true),
        ],
      ),
    );
  }
}

/// The optional half, whichever transport this is.
class _AdvancedFields extends StatelessWidget {
  const _AdvancedFields({
    required this.isRemote,
    required this.fill,
    required this.headers,
    required this.args,
    required this.env,
  });

  final bool isRemote;
  final Color fill;
  final TextEditingController headers;
  final TextEditingController args;
  final TextEditingController env;

  @override
  Widget build(BuildContext context) {
    if (isRemote) {
      return LabeledField(
        fill: fill,
        label: 'Headers (Name: value, one per line)',
        controller: headers,
        hint: 'Authorization: Bearer …',
        minLines: 2,
        maxLines: 4,
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        LabeledField(
          fill: fill,
          label: 'Arguments (one per line)',
          controller: args,
          hint: '-y\n@modelcontextprotocol/server-notion',
          minLines: 2,
          maxLines: 5,
        ),
        const SizedBox(height: 18),
        LabeledField(
          fill: fill,
          label: 'Environment (KEY=value, one per line)',
          controller: env,
          hint: 'NOTION_TOKEN=secret_…',
          minLines: 2,
          maxLines: 4,
        ),
      ],
    );
  }
}

/// What Grid can and cannot vouch for, on every screen that can add a server.
class _TrustNotice extends StatelessWidget {
  const _TrustNotice({required this.centered});

  /// Centred on the found screen, where the whole column is; ranged left on the
  /// form, where it sits under fields.
  final bool centered;

  @override
  Widget build(BuildContext context) => Text(
    'Only add servers from developers you trust. The assistant can call '
    'whatever tools a server exposes, and Grid cannot check what those are or '
    'whether they change.',
    textAlign: centered ? TextAlign.center : TextAlign.start,
    style: Theme.of(context).textTheme.bodySmall?.copyWith(
      // Not textFaint: measured against this dialog's own fill
      // (AppGlass.surfaceFill, #202020 in dark) it reaches only 3.18:1, under
      // the 4.5:1 body-text floor. textSecondary is 6.82:1 dark, 6.21:1 light.
      color: AppPalette.textSecondary,
      height: 1.45,
    ),
  );
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
