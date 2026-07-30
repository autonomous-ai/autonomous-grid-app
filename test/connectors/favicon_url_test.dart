import 'package:flutter_test/flutter_test.dart';
import 'package:grid_app/features/connectors/logic/favicon_url.dart';

/// The privacy boundary around the icon lookup.
///
/// Deriving an icon means sending a hostname to a third party, so the tests that
/// matter most here are the ones asserting a request is *not* made. They are
/// easy to mistake for over-testing a string builder; they are not. Deleting one
/// leaks a private hostname, and the leak is invisible — the row renders the same
/// fallback glyph either way.
void main() {
  group('a public host gets an icon URL', () {
    test('an mcp.* endpoint is asked about by its registrable domain', () {
      // The difference between an icon and a grey globe. Measured 2026-07-30:
      // every `mcp.*` subdomain returns 404 (an API host serves no favicon)
      // while the apex returns a real mark — browserbase.com and notion.com at
      // 128×128, supabase.com at 16.
      final url = faviconUrl('https://mcp.supabase.com/mcp');

      expect(url, contains('domain=supabase.com'));
      expect(url, isNot(contains('mcp.supabase.com')));
      // 128 is a ceiling, not a promise — hosts return whatever they publish.
      expect(url, contains('sz=128'));
    });

    test('only an mcp label is trimmed, and only one level', () {
      // Walking further up would turn `mcp.eu.acme.co.uk` into `co.uk` and show
      // the wrong brand; anything that is not the MCP convention keeps its host.
      expect(faviconHost('https://api.example.com/mcp'), 'api.example.com');
      expect(faviconHost('https://mcp.eu.acme.com/mcp'), 'eu.acme.com');
      // A two-label host has nothing to trim to.
      expect(faviconHost('https://mcp.com/mcp'), 'mcp.com');
    });

    test('the path, query and port are dropped — only the host is sent', () {
      // Anything past the host can carry a token, a workspace id, or a customer
      // name. None of it is needed to find an icon, so none of it is sent.
      final url = faviconUrl('https://api.example.com:8443/v2/mcp?key=secret');

      expect(url, contains('domain=api.example.com'));
      expect(url, isNot(contains('secret')));
      expect(url, isNot(contains('8443')));
      expect(url, isNot(contains('/v2/mcp')));
    });

    test('the host is lower-cased so one server has one cache key', () {
      expect(
        faviconUrl('https://API.Example.COM/mcp'),
        contains('domain=api.example.com'),
      );
    });
  });

  group('a host that might be private is never sent', () {
    test('localhost and single-label names', () {
      // A name with no dot is resolved by search domain — an intranet short
      // name, and never something the public internet knows.
      expect(faviconUrl('http://localhost:3000/mcp'), isEmpty);
      expect(faviconUrl('http://mcp-internal/mcp'), isEmpty);
    });

    test('literal IP addresses, v4 and v6', () {
      expect(faviconUrl('http://127.0.0.1:8080/mcp'), isEmpty);
      expect(faviconUrl('http://192.168.1.10/mcp'), isEmpty);
      expect(faviconUrl('http://10.0.0.5/mcp'), isEmpty);
      // A public IP is refused too: a server reached by raw address has no brand
      // to show, and splitting public from private ranges is a second thing to
      // get subtly wrong.
      expect(faviconUrl('http://8.8.8.8/mcp'), isEmpty);
      // Uri.host strips the brackets from [::1], so the colon is what catches
      // IPv6 — looking for brackets would never match.
      expect(faviconUrl('http://[::1]:9000/mcp'), isEmpty);
    });

    test('reserved and conventional private suffixes', () {
      // The case this whole guard exists for: a company's own MCP server, whose
      // hostname describes their infrastructure.
      expect(faviconUrl('https://mcp.acme.internal/mcp'), isEmpty);
      expect(faviconUrl('https://mcp.acme.corp/mcp'), isEmpty);
      expect(faviconUrl('https://server.local/mcp'), isEmpty);
      expect(faviconUrl('https://box.lan/mcp'), isEmpty);
      expect(faviconUrl('https://thing.home.arpa/mcp'), isEmpty);
      expect(faviconUrl('https://a.test/mcp'), isEmpty);
    });

    test('a suffix match is on the label, not the substring', () {
      // `mycorp.com` ends with "corp" only if you ignore the dot. Refusing it
      // would silently drop icons for real companies.
      expect(faviconUrl('https://mcp.mycorp.com/mcp'), isNotEmpty);
      expect(faviconUrl('https://internal-tools.com/mcp'), isNotEmpty);
    });
  });

  group('input that is not a URL at all', () {
    test('empty, blank and unparseable values yield no icon', () {
      expect(faviconUrl(''), isEmpty);
      expect(faviconUrl('   '), isEmpty);
      expect(faviconUrl('not a url'), isEmpty);
      // A bare command, which is what a stdio server looks like.
      expect(faviconUrl('npx'), isEmpty);
    });

    test('surrounding whitespace is tolerated', () {
      expect(
        faviconUrl('  https://mcp.notion.com/mcp  '),
        contains('domain=notion.com'),
      );
    });
  });

  group('isPubliclyResolvable', () {
    test('answers the question directly, for callers that need it', () {
      expect(isPubliclyResolvable('mcp.supabase.com'), isTrue);
      expect(isPubliclyResolvable('localhost'), isFalse);
      expect(isPubliclyResolvable('192.168.0.1'), isFalse);
    });
  });
}
