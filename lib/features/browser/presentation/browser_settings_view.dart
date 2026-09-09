import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../infrastructure/state/agent_browser_choice.dart';
import '../../../infrastructure/state/chat_prefs_store.dart';
import '../../../shared/panels/panel_tabs.dart';
import '../../agents/logic/agent_browser_controller.dart';
import '../../../shared/theme/app_theme.dart';
import '../../../shared/widgets/app_select_field.dart';
import '../../../shared/widgets/labeled_field.dart';
import '../../../shared/widgets/section_scaffold.dart';
import '../../network/presentation/grid_overview_widgets.dart';
import '../logic/browser_url.dart';

/// The Browser settings screen: which browser the *assistant* may use, and —
/// where this computer can draw a page of its own — how the Browser tab
/// behaves.
///
/// The assistant's browser leads because it is the consequential one: it is the
/// only setting here that lets something act on the user's behalf. It was two
/// controls in two places before, and one of the three lanes had no control at
/// all — see [AgentBrowserChoice].
///
/// Every setting on this screen changes something. The screen this is modelled
/// on carries ten — remote rendering, SSH egress, cookie profiles, per-worktree
/// localhost labels — and none of those have anything behind them here. A
/// settings screen padded out with controls that do nothing is worse than a
/// short one: the user has no way to tell which half is which.
class BrowserSettingsView extends ConsumerWidget {
  const BrowserSettingsView({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    AppTheme.watch(context);
    return SectionScaffold(
      title: 'Browser',
      subtitle:
          'Which browser the assistant may use, and how Grid’s own Browser tab '
          'behaves. The tab opens beside a conversation from the panel, or '
          'with ⌘⇧B.',
      child: SingleChildScrollView(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const _AssistantBrowserSection(),
            // The rest of the screen is about a tab this computer may not be
            // able to draw. Left out rather than greyed out: a Linux user
            // cannot act on any of it, and three dead controls under a live
            // one reads as the screen being broken.
            if (availablePanelFeatures.contains(
              PanelFeature.browser,
            )) ...const [
              SizedBox(height: 26),
              Divider(height: 1),
              SizedBox(height: 26),
              _HomePageSection(),
              SizedBox(height: 26),
              _SearchEngineSection(),
              SizedBox(height: 26),
              _LinkRoutingSection(),
            ],
          ],
        ),
      ),
    );
  }
}

/// Where a new Browser tab starts.
class _HomePageSection extends ConsumerStatefulWidget {
  const _HomePageSection();

  @override
  ConsumerState<_HomePageSection> createState() => _HomePageSectionState();
}

class _HomePageSectionState extends ConsumerState<_HomePageSection> {
  late final _text = TextEditingController(
    text: ref.read(chatPrefsProvider).browserHomePage,
  );

  @override
  void dispose() {
    _text.dispose();
    super.dispose();
  }

  /// Saved as typed, and read the same way the address bar reads it — so
  /// `example.com` here opens the same page it would if you typed it into a
  /// tab, rather than being rejected for having no scheme.
  void _save() => ref
      .read(chatPrefsProvider.notifier)
      .setBrowserHomePage(_text.text.trim());

  @override
  Widget build(BuildContext context) {
    AppTheme.watch(context);
    final saved = ref.watch(chatPrefsProvider.select((p) => p.browserHomePage));
    final typed = _text.text.trim();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const SectionHeading(
          title: 'Home page',
          subtitle:
              'Where a new Browser tab starts. Leave it empty and a new tab '
              'opens on nothing, which is what it does today.',
        ),
        const SizedBox(height: 12),
        Row(
          crossAxisAlignment: CrossAxisAlignment.end,
          children: [
            Expanded(
              child: LabeledField(
                label: 'Address',
                controller: _text,
                hint: 'example.com',
                // Rebuilds the row so Save can appear the moment the field
                // stops matching what is stored.
                onChanged: (_) => setState(() {}),
                onSubmitted: (_) => _save(),
              ),
            ),
            const SizedBox(width: 8),
            // Only while there is a change to save. A button that is always
            // there and usually does nothing teaches people not to press it.
            Padding(
              padding: const EdgeInsets.only(bottom: 2),
              child: FilledButton(
                onPressed: typed == saved ? null : _save,
                child: const Text('Save'),
              ),
            ),
          ],
        ),
      ],
    );
  }
}

/// Where the address bar searches when what was typed isn't an address.
class _SearchEngineSection extends ConsumerWidget {
  const _SearchEngineSection();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    AppTheme.watch(context);
    final current = BrowserSearchEngine.byId(
      ref.watch(chatPrefsProvider.select((p) => p.browserSearchEngine)),
    );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const SectionHeading(
          title: 'Search',
          // Says where the words go, because that is the part worth knowing:
          // anything typed into the bar that isn't an address is sent to this
          // company.
          subtitle:
              'Type something that isn’t an address into the Browser tab’s bar '
              'and it is searched for here. What you type goes to whoever this '
              'names.',
        ),
        const SizedBox(height: 12),
        SizedBox(
          width: 260,
          child: AppSelectField<BrowserSearchEngine>(
            label: 'Search engine',
            value: current,
            options: [
              for (final engine in BrowserSearchEngine.values)
                AppSelectOption(value: engine, label: engine.label),
            ],
            onChanged: (engine) => ref
                .read(chatPrefsProvider.notifier)
                .setBrowserSearchEngine(engine.id),
          ),
        ),
      ],
    );
  }
}

/// Where a link clicked in the app's own content opens.
class _LinkRoutingSection extends ConsumerWidget {
  const _LinkRoutingSection();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    AppTheme.watch(context);
    final theme = Theme.of(context);
    final inside = ref.watch(
      chatPrefsProvider.select((p) => p.browserOpensLinks),
    );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const SectionHeading(title: 'Links', subtitle: ''),
        const SizedBox(height: 12),
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'Open links in Grid',
                    style: theme.textTheme.bodyMedium?.copyWith(
                      color: AppPalette.textPrimary,
                    ),
                  ),
                  const SizedBox(height: 2),
                  // Both states are spelt out, and the "on" one names what it
                  // does *not* do: sign-ins go to the real browser whatever
                  // this says, because that is where the account already is.
                  Text(
                    inside
                        ? 'On — a link in a message or a Markdown file opens '
                              'in a Browser tab beside it. Signing in to '
                              'something still opens your own browser.'
                        : 'Off — links open in the browser you already use, '
                              'with your logins and extensions.',
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: AppPalette.textSecondary,
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(width: 12),
            Switch(
              value: inside,
              onChanged: ref
                  .read(chatPrefsProvider.notifier)
                  .setBrowserOpensLinks,
            ),
          ],
        ),
      ],
    );
  }
}

/// Which browser the assistant may use, if any.
///
/// The one place this is answered. It reaches three different things — Grid's
/// own tab through the MCP server, a Chrome the app starts, and the Chrome the
/// user already has open — and the copy's whole job is to make the difference
/// between them plain *before* the pick, because the difference is who the
/// browser is signed in as.
class _AssistantBrowserSection extends ConsumerWidget {
  const _AssistantBrowserSection();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    AppTheme.watch(context);
    final theme = Theme.of(context);
    final current = ref.watch(agentBrowserChoiceProvider);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const SectionHeading(
          title: 'The assistant’s browser',
          subtitle:
              'Off to start with, on purpose: every other answer lets the '
              'assistant move around a browser while you are typing. It takes '
              'effect on the next turn.',
        ),
        const SizedBox(height: 12),
        SizedBox(
          width: 360,
          child: AppSelectField<AgentBrowserChoice>(
            label: 'Use',
            value: current,
            // The closed field is only as wide as the control, so a sentence
            // arrives clipped — the menu is where it is read, while choosing.
            showDetailInField: false,
            options: [
              for (final choice in agentBrowserChoices)
                AppSelectOption(
                  value: choice,
                  label: choice.label,
                  detail: agentBrowserChoiceDetail(choice),
                ),
            ],
            onChanged: ref.read(agentBrowserProvider).choose,
          ),
        ),
        const SizedBox(height: 8),
        Text(
          agentBrowserChoiceDetail(current),
          style: theme.textTheme.bodySmall?.copyWith(
            color: AppPalette.textSecondary,
          ),
        ),
      ],
    );
  }
}

/// The choices this computer can actually offer.
///
/// [AgentBrowserChoice.gridTab] needs an engine to draw a page with, which
/// Linux has none of — see [availablePanelFeatures].
List<AgentBrowserChoice> get agentBrowserChoices => [
  for (final choice in AgentBrowserChoice.values)
    if (choice != AgentBrowserChoice.gridTab ||
        availablePanelFeatures.contains(PanelFeature.browser))
      choice,
];

/// What picking one actually means, in one line under the control.
///
/// Each says **who the browser is signed in as**, because that is the whole
/// difference between them and the only part with a consequence the user
/// cannot undo. Each also names which assistants honour it: these lanes run
/// through each CLI's own browser support, and a user on Codex who picked one
/// would otherwise wait for a browser that never comes.
String agentBrowserChoiceDetail(AgentBrowserChoice choice) => switch (choice) {
  AgentBrowserChoice.none =>
    'No assistant opens a browser — including Hermes, which has one of its '
        'own. It can still search the web and read pages through your grid.',
  AgentBrowserChoice.gridTab =>
    'The assistant works in the Browser tab beside the conversation, and you '
        'watch it happen. It is signed in as you in that tab. The only one '
        'every assistant can use.',
  AgentBrowserChoice.cleanWindow =>
    'A browser of its own, signed in to nothing — so anything behind a login '
        'stays out of reach. Claude Code opens a Chrome window; Hermes uses '
        'its own. Codex has neither.',
  AgentBrowserChoice.yourBrowser =>
    'The assistant drives the Chrome you already have open, so it can act in '
        'every account you are signed in to. Needs the Claude in Chrome '
        'extension, and Claude Code only — the others get no browser.',
};
