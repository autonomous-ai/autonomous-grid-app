import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../logging/app_log.dart';
import 'panel_link.dart';
import 'panel_port.dart';

/// The USB port a Grid Panel is plugged into — built here, opened by
/// `PanelScope`.
///
/// Construction touches no hardware on purpose: reading a provider must never
/// run `ioreg` or open a `/dev` node, and the app has to decide *when* to start
/// looking (after the first frame, not during it).
///
/// Kept in its own file so [PanelPort] itself stays free of Flutter, like
/// `connectorBridgeProvider` does for `ConnectorBridge`. That is not tidiness:
/// a plain `dart:io` transport can be driven from a scratch script, which is how
/// this protocol is checked against a real device rather than by reading it —
/// see `tool/panel_tap.dart`.
final panelPortProvider = Provider<PanelPort>((ref) {
  final log = ref.read(appLogProvider);
  // Attaching, detaching and reopening are the whole diagnosis when a panel
  // "does nothing", and they happen with no UI to show them.
  final port = PanelPort(log: (message) => log.info('panel', message));
  ref.onDispose(port.close);
  return port;
});

/// The framing and message layer over that port — what the app talks to.
///
/// Both this and [panelPortProvider] release their own object: closing the link
/// closes the port too, and closing a closed port is a no-op, so registering
/// both costs nothing and neither can leak when it is the only one read.
final panelLinkProvider = Provider<PanelLink>((ref) {
  final log = ref.read(appLogProvider);
  final link = PanelLink(
    ref.watch(panelPortProvider),
    // Letting a port go is the one thing this layer does that looks, from the
    // outside, exactly like a panel that never connected. Logged for the same
    // reason attaching and detaching are one provider up.
    log: (message) => log.info('panel', message),
  );
  ref.onDispose(link.close);
  return link;
});
