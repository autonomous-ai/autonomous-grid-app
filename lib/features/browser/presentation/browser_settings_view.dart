import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../infrastructure/state/chat_prefs_store.dart';
import '../../../shared/theme/app_theme.dart';
import '../../../shared/widgets/app_select_field.dart';
import '../../../shared/widgets/labeled_field.dart';
import '../../../shared/widgets/section_scaffold.dart';
import '../../../shared/widgets/selectable_body.dart';
import '../../network/presentation/grid_overview_widgets.dart';
import '../logic/browser_url.dart';

/// The Browser settings screen: where a new tab starts, where the address bar
/// searches, and where a link you click goes.
///
/// Three settings, and every one of them changes something. The screen this is
/// modelled on carries ten — remote rendering, SSH egress, cookie profiles,
/// per-worktree localhost labels — and none of those have anything behind them
/// here. A settings screen padded out with controls that do nothing is worse
/// than a short one: the user has no way to tell which half is which.
class BrowserSettingsView extends ConsumerWidget {
  const BrowserSettingsView({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    AppTheme.watch(context);
    return SectionScaffold(
      title: 'Browser',
      subtitle:
          'Grid can open a web page beside a conversation — the Browser tab in '
          'the panel, or ⌘⇧B. These settings are about that tab, not about the '
          'browser you already use.',
      child: SingleChildScrollView(
        child: SelectableBody(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: const [
              _HomePageSection(),
              SizedBox(height: 26),
              _SearchEngineSection(),
              SizedBox(height: 26),
              _LinkRoutingSection(),
            ],
          ),
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
                        ? 'On — a link in a message or a Markdown file opens in '
                              'a Browser tab beside it. Signing in to something '
                              'still opens your own browser.'
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
