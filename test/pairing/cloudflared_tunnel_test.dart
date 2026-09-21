import 'package:flutter_test/flutter_test.dart';
import 'package:grid_app/infrastructure/pairing_host/cloudflared_tunnel.dart';

/// Real output, captured from `cloudflared tunnel --url` (version 2026.9.1) on
/// 2026-09-21 rather than written from memory of it. The box drawing and the
/// padding are exactly as they arrived.
const _banner = [
  '2026-09-21T09:16:18Z INF Requesting new quick Tunnel on trycloudflare.com...',
  '2026-09-21T09:16:24Z INF +---------------------------------------------+',
  '2026-09-21T09:16:24Z INF |  Your quick Tunnel has been created! Visit it at (it may take some time to be reachable):  |',
  '2026-09-21T09:16:24Z INF |  https://phase-fridge-spa-realize.trycloudflare.com                                        |',
  '2026-09-21T09:16:24Z INF +---------------------------------------------+',
  '2026-09-21T09:16:24Z INF Version 2026.9.1 (Checksum 9a0b19f6)',
  '2026-09-21T09:16:24Z INF Settings: map[ha-connections:1 protocol:quic url:http://127.0.0.1:1]',
];

void main() {
  group('reading the address out of what cloudflared prints', () {
    test('the address is found in the drawn box it arrives inside — this is '
        'the one line of output the phone link depends on', () {
      final found = [
        for (final line in _banner)
          if (parseQuickTunnelUrl(line) != null) parseQuickTunnelUrl(line),
      ];

      expect(found, ['https://phase-fridge-spa-realize.trycloudflare.com']);
    });

    test('the line that only announces a tunnel is coming is not mistaken for '
        'the tunnel: it names the domain without an address', () {
      expect(parseQuickTunnelUrl(_banner.first), isNull);
    });

    test('the ordinary log lines yield nothing, so a tunnel is never reported '
        'from a line that merely mentions the settings', () {
      expect(parseQuickTunnelUrl(_banner.last), isNull);
      expect(parseQuickTunnelUrl(''), isNull);
    });

    test('a hostname with digits and dashes is read whole — Cloudflare mints '
        'the words, and this must not stop at the first dash', () {
      expect(
        parseQuickTunnelUrl('INF | https://a1-b2-c3-d4.trycloudflare.com |'),
        'https://a1-b2-c3-d4.trycloudflare.com',
      );
    });

    test('a lookalike domain is not a tunnel, so a line quoting somebody '
        "else's host cannot point this computer's phone at it", () {
      expect(
        parseQuickTunnelUrl('INF https://evil.trycloudflare.com.attacker.test'),
        'https://evil.trycloudflare.com',
      );
    });
  });

  group('the spelling the cell and the desktop have to agree on', () {
    test('an https tunnel becomes a wss origin, because the cell bakes the '
        'origin it was started on into every proof it signs', () {
      expect(
        websocketOriginOf('https://phase-fridge.trycloudflare.com'),
        'wss://phase-fridge.trycloudflare.com',
      );
    });

    test('a plain http address becomes ws, so a local cell is described the '
        'same way by the same function', () {
      expect(websocketOriginOf('http://127.0.0.1:8787'), 'ws://127.0.0.1:8787');
    });

    test('only the scheme is touched — a host that happens to contain "http" '
        'survives, which a blunter replacement would corrupt', () {
      expect(
        websocketOriginOf('https://http-proxy.trycloudflare.com'),
        'wss://http-proxy.trycloudflare.com',
      );
    });
  });
}
