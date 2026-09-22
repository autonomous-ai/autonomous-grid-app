/// Settings ▸ Phone — sharing this computer with a phone.
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../../shared/widgets/app_spinner.dart';
import '../../../shared/widgets/error_box.dart';
import '../../../shared/widgets/section_scaffold.dart';
import '../../../shared/widgets/soft_action_button.dart';
import '../logic/phone_sharing_controller.dart';
import '../logic/phone_sharing_state.dart';
import '../logic/phone_tunnel_controller.dart';
import 'phone_live_view.dart';

/// Where to send somebody who does not have the tunnel program.
///
/// Cloudflare's own page rather than a package manager command: which one is
/// right depends on the machine, and Grid installing software nobody asked for
/// is not something this screen gets to decide.
const _cloudflaredHelp =
    'https://developers.cloudflare.com/cloudflare-one/connections/connect-networks/downloads/';

/// The Phone screen.
class PhoneView extends ConsumerWidget {
  const PhoneView({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) => SectionScaffold(
    title: 'Phone',
    subtitle:
        'Use Grid from your phone. It reads what this computer tells it, over '
        'a connection only the two of them can read.',
    child: switch (ref.watch(phoneSharingProvider)) {
      PhoneSharingOff() => const _Off(),
      PhoneSharingStarting(:final step) => _Starting(step),
      PhoneSharingLive() && final live => PhoneLiveView(live),
      PhoneSharingFailed(:final message) => _Failed(message),
    },
  );
}

/// Starting, and saying which part it is on.
class _Starting extends StatelessWidget {
  const _Starting(this.step);

  final String step;

  @override
  Widget build(BuildContext context) => Center(
    child: Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        const AppSpinner(),
        const SizedBox(height: 12),
        Text('$step…', style: Theme.of(context).textTheme.bodySmall),
      ],
    ),
  );
}

/// Not sharing: say what turning it on does, then offer the one action.
class _Off extends ConsumerWidget {
  const _Off();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final canTunnel = ref.watch(canOpenTunnelProvider);
    return ListView(
      children: [
        const SizedBox(height: 8),
        Text(
          'Grid gives each phone a short code. Type it into Grid on the phone '
          'and it finds this computer by itself, wherever either of you are — '
          'there is nothing to set up and no address to remember.',
          style: theme.textTheme.bodyMedium,
        ),
        const SizedBox(height: 16),
        Text(
          'While this is on, your computer keeps an address on the internet '
          'open so your phone can reach it. Only a phone holding one of your '
          'codes can get in, and what they say to each other is readable by '
          'nobody else — not by Cloudflare, who carry it.',
          style: theme.textTheme.bodySmall,
        ),
        const SizedBox(height: 24),
        if (canTunnel)
          Align(
            alignment: Alignment.centerLeft,
            child: SoftActionButton(
              label: 'Turn on sharing',
              filled: true,
              leading: const Icon(LucideIcons.smartphone, size: 16),
              onPressed: () =>
                  unawaited(ref.read(phoneSharingProvider.notifier).start()),
            ),
          )
        else
          const _NeedsCloudflared(),
      ],
    );
  }
}

/// The one thing this computer may be missing, said plainly.
///
/// A disabled button with no explanation is the version of this that gets
/// reported as "Phone doesn't work"; and installing software because somebody
/// opened a settings screen is not a decision Grid makes for anybody.
class _NeedsCloudflared extends ConsumerWidget {
  const _NeedsCloudflared();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          "Grid needs Cloudflare's free tunnel program (cloudflared) to give "
          'your computer an address, and it is not on this computer yet. '
          'Install it, then press Check again.',
          style: theme.textTheme.bodySmall,
        ),
        const SizedBox(height: 12),
        Row(
          children: [
            SoftActionButton(
              label: 'How to install it',
              leading: const Icon(LucideIcons.externalLink, size: 16),
              onPressed: () =>
                  unawaited(launchUrl(Uri.parse(_cloudflaredHelp))),
            ),
            const SizedBox(width: 10),
            // The button exists because the answer is cached: where a program is
            // gets looked up once, so something installed while this screen was
            // open is invisible until somebody asks again. A screen that claimed
            // to notice by itself would be lying about a thing easy to check.
            SoftActionButton(
              label: 'Check again',
              onPressed: () => ref.invalidate(cloudflaredPathProvider),
            ),
          ],
        ),
      ],
    );
  }
}

/// It did not start. Says what happened and offers both ways out.
class _Failed extends ConsumerWidget {
  const _Failed(this.message);

  final String message;

  @override
  Widget build(BuildContext context, WidgetRef ref) => ListView(
    children: [
      const SizedBox(height: 8),
      ErrorBox(message: message),
      const SizedBox(height: 20),
      Row(
        children: [
          SoftActionButton(
            label: 'Try again',
            filled: true,
            onPressed: () =>
                unawaited(ref.read(phoneSharingProvider.notifier).start()),
          ),
          const SizedBox(width: 10),
          // Leaves it switched off for next launch, which "Try again" must not
          // do: somebody whose tunnel failed once still wants sharing on.
          SoftActionButton(
            label: 'Turn off sharing',
            onPressed: () =>
                unawaited(ref.read(phoneSharingProvider.notifier).stop()),
          ),
        ],
      ),
    ],
  );
}
