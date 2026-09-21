/// The public address a phone dials, opened by this computer and nobody else.
///
/// A phone and a desktop both dial *out* to the pairing cell, because neither
/// can accept a connection — so the cell needs an address that exists on the
/// internet. Rather than asking somebody to run one, the desktop puts a
/// Cloudflare quick tunnel in front of the cell it already runs on loopback:
/// no account, no signup, nothing for a person to configure. See ADR 0045.
///
/// The address is **not stable**. A quick tunnel is a new hostname every time,
/// and Cloudflare offers it with no uptime guarantee — which is why the design
/// this belongs to never stores the address as a fact about a computer.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import '../logging/app_log.dart';

/// How long to wait for a tunnel to name itself before giving up.
///
/// Measured against cloudflared 2026.9.1: the address arrives about six
/// seconds after launch. A minute is not generosity, it is the difference
/// between a slow network and a tunnel that is never coming.
const Duration kTunnelReadyTimeout = Duration(seconds: 60);

/// The public address of a quick tunnel, from whatever cloudflared has printed.
///
/// It arrives inside a drawn box, as one field of a log line:
///
/// ```
/// 2026-09-21T09:16:24Z INF |  https://phase-fridge-spa-realize.trycloudflare.com  |
/// ```
///
/// Read by looking for the hostname rather than by taking the banner apart: the
/// box is decoration and decoration is what changes between releases, while a
/// `trycloudflare.com` address is the one thing the command exists to produce.
/// Null for every other line, which is nearly all of them.
///
/// Pure, so the one piece of cloudflared's output this depends on is pinned by
/// a test against real captured output rather than by watching a phone fail.
String? parseQuickTunnelUrl(String line) =>
    _quickTunnelUrl.firstMatch(line)?.group(0);

final RegExp _quickTunnelUrl = RegExp(
  r'https://[a-z0-9-]+\.trycloudflare\.com',
  caseSensitive: false,
);

/// The `ws://`/`wss://` origin a desktop dials and a cell signs with, for an
/// `https://` tunnel address.
///
/// The cell bakes its origin into every host proof, so the two spellings have
/// to agree exactly or every handshake fails with both sides blaming the other
/// (`scripts/run_phone_link.sh` exists because of this). Deriving it here means
/// there is one conversion and nowhere for the two to drift apart.
String websocketOriginOf(String httpsUrl) =>
    httpsUrl.replaceFirst(RegExp('^http'), 'ws');

/// Where the tunnel has got to.
sealed class TunnelState {
  const TunnelState();
}

/// No tunnel, and none asked for.
final class TunnelOff extends TunnelState {
  const TunnelOff();
}

/// Launched, waiting for Cloudflare to name it.
final class TunnelOpening extends TunnelState {
  const TunnelOpening();
}

/// Up, and reachable at [url] (`https://…`); [origin] is the `wss://` spelling
/// the cell and the desktop both have to use.
///
/// Both are kept because both are shown: the `https://` one is what a person
/// can open in a browser to see whether the tunnel is alive at all, and the
/// `wss://` one is the only spelling a proof will verify against.
final class TunnelOpen extends TunnelState {
  TunnelOpen({required this.url}) : origin = websocketOriginOf(url);

  final String url;
  final String origin;
}

/// It didn't come up, and [message] is what to tell somebody about it.
final class TunnelFailed extends TunnelState {
  const TunnelFailed(this.message);

  final String message;
}

/// Runs `cloudflared tunnel --url` and owns the process for as long as the
/// tunnel is wanted.
///
/// One tunnel per instance. [close] is what stops it; nothing here outlives the
/// object, because a tunnel nobody can see is a public door onto this machine
/// that nobody knows is open.
class CloudflaredTunnel {
  CloudflaredTunnel({
    required String executable,
    required AppLog log,
    this.readyTimeout = kTunnelReadyTimeout,
  }) : _executable = executable,
       _log = log;

  final String _executable;
  final AppLog _log;

  /// How long [open] waits for an address before calling it a failure.
  final Duration readyTimeout;

  Process? _process;
  StreamSubscription<String>? _out;
  StreamSubscription<String>? _err;

  /// Open a tunnel to [port] on loopback and resolve once it has an address.
  ///
  /// Never throws: a failure comes back as [TunnelFailed] carrying something a
  /// person can act on, because every caller of this has a screen to put it on.
  Future<TunnelState> open(int port) async {
    if (_process != null) {
      return const TunnelFailed('A tunnel is already open.');
    }
    final address = Completer<String>();
    try {
      final process = _process = await Process.start(_executable, [
        'tunnel',
        '--url',
        'http://127.0.0.1:$port',
      ]);
      // Both streams: cloudflared logs to stderr today, and which stream a line
      // lands on is not something to depend on.
      _out = _watch(process.stdout, address);
      _err = _watch(process.stderr, address);
      unawaited(
        process.exitCode.then((code) {
          if (address.isCompleted) return;
          address.completeError(
            'cloudflared stopped before it opened a tunnel (exit $code).',
          );
        }),
      );
      final url = await address.future.timeout(readyTimeout);
      _log.info('phone', 'quick tunnel open at $url');
      return TunnelOpen(url: url);
    } on TimeoutException {
      await close();
      return TunnelFailed(
        "Cloudflare didn't give this computer an address within "
        '${readyTimeout.inSeconds} seconds. Check the connection and try again.',
      );
    } on ProcessException catch (error) {
      await close();
      _log.warn('phone', "couldn't start cloudflared: $error");
      return const TunnelFailed(
        "Couldn't start the tunnel program on this computer.",
      );
    } on Object catch (error) {
      await close();
      _log.warn('phone', 'the tunnel failed to open: $error');
      return TunnelFailed('$error');
    }
  }

  /// Stop the tunnel and let go of the process.
  Future<void> close() async {
    await _out?.cancel();
    await _err?.cancel();
    _out = null;
    _err = null;
    final process = _process;
    _process = null;
    if (process == null) return;
    process.kill();
    // Waited for rather than fired and forgotten: the port is reopened by the
    // next attempt, and a half-dead tunnel still holding it is a failure that
    // reads as Cloudflare being broken.
    await process.exitCode;
  }

  StreamSubscription<String> _watch(
    Stream<List<int>> stream,
    Completer<String> address,
  ) => stream.transform(utf8.decoder).transform(const LineSplitter()).listen((
    line,
  ) {
    final url = parseQuickTunnelUrl(line);
    if (url == null || address.isCompleted) return;
    address.complete(url);
  });
}
