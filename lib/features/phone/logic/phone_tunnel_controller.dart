/// The public address this computer offers a phone, and who owns it.
///
/// A quick tunnel is opened **by hand, never on launch** — the same rule the
/// pairing controller holds itself to, and for a stronger reason: this one
/// opens a door onto this machine that anybody on the internet can knock on.
/// Nothing here starts because the app did.
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../infrastructure/logging/app_log.dart';
import '../../../infrastructure/pairing_host/cloudflared_tunnel.dart';
import '../../../infrastructure/cli/host_environment.dart';

/// Where `cloudflared` is on this computer, or null when it isn't here.
///
/// Found the way every other tool this app drives is found, so a packaged build
/// looks in the same places a terminal would ([HostEnvironment]).
final cloudflaredPathProvider = Provider<String?>(
  (ref) => HostEnvironment.findExecutable('cloudflared'),
);

/// Whether this computer can open a tunnel at all.
final canOpenTunnelProvider = Provider<bool>(
  (ref) => ref.watch(cloudflaredPathProvider) != null,
);

/// The tunnel this computer has open, if it has one.
final phoneTunnelProvider =
    NotifierProvider<PhoneTunnelController, TunnelState>(
      PhoneTunnelController.new,
    );

class PhoneTunnelController extends Notifier<TunnelState> {
  CloudflaredTunnel? _tunnel;

  @override
  TunnelState build() {
    // The process outlives a rebuild otherwise, and a tunnel nobody is holding
    // is a public address into this machine that nothing will ever close.
    ref.onDispose(_release);
    return const TunnelOff();
  }

  /// Open a tunnel onto the cell listening on [port].
  ///
  /// Does nothing when one is already open or opening: two tunnels would give
  /// two addresses, and the record a phone reads can only name one.
  Future<void> open(int port) async {
    if (state is TunnelOpen || state is TunnelOpening) return;
    final executable = ref.read(cloudflaredPathProvider);
    if (executable == null) {
      state = const TunnelFailed(
        "The tunnel program isn't on this computer yet.",
      );
      return;
    }
    // A tunnel that died leaves its object behind; letting go of it here rather
    // than overwriting the field means its subscriptions go too.
    await _release();
    state = const TunnelOpening();
    late final CloudflaredTunnel tunnel;
    tunnel = _tunnel = CloudflaredTunnel(
      executable: executable,
      log: ref.read(appLogProvider),
      // Only for the tunnel that is current: an older one ending says nothing
      // about the address this computer is offering now.
      onClosed: () {
        if (!identical(_tunnel, tunnel)) return;
        _tunnel = null;
        state = const TunnelFailed(
          'The address for your phone closed. Cloudflare gives these out with '
          'no promise to keep them.',
        );
      },
    );
    final opened = await tunnel.open(port);
    // Closed while it was opening: the address it just won belongs to nothing.
    if (!identical(_tunnel, tunnel)) return;
    if (opened is! TunnelOpen) await _release();
    state = opened;
  }

  /// Close the tunnel, which takes the public address away with it.
  Future<void> close() async {
    await _release();
    state = const TunnelOff();
  }

  Future<void> _release() async {
    final tunnel = _tunnel;
    _tunnel = null;
    await tunnel?.close();
  }
}
