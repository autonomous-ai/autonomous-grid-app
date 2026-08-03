import 'package:flutter_test/flutter_test.dart';
import 'package:grid_app/features/connectors/logic/mcp_auth_probe.dart';

void main() {
  group('metadataCandidates', () {
    List<String> urlsFor(String issuer) => McpAuthProbe.metadataCandidates(
      Uri.parse(issuer),
    ).map((u) => u.toString()).toList();

    test('an issuer with a path asks the RFC 8414 form first', () {
      // Stripe. Measured 2026-07-31: only the inserted form answers, and asking
      // the appended one first is what sent a self-registering server to "you
      // will need to paste a token".
      expect(
        urlsFor('https://access.stripe.com/mcp').first,
        [
          'https://access.stripe.com/.well-known/oauth-authorization-server/mcp',
        ].single,
      );
    });

    test('the appended form is still asked, after', () {
      expect(
        urlsFor('https://access.stripe.com/mcp'),
        containsAllInOrder([
          'https://access.stripe.com/.well-known/oauth-authorization-server/mcp',
          'https://access.stripe.com/mcp/.well-known/oauth-authorization-server',
        ]),
      );
    });

    test('the OpenID document comes after both spellings of the RFC one', () {
      expect(urlsFor('https://access.stripe.com/mcp'), [
        'https://access.stripe.com/.well-known/oauth-authorization-server/mcp',
        'https://access.stripe.com/mcp/.well-known/oauth-authorization-server',
        'https://access.stripe.com/.well-known/openid-configuration/mcp',
        'https://access.stripe.com/mcp/.well-known/openid-configuration',
      ]);
    });

    test('a bare issuer asks each document once, not twice', () {
      // Notion, Linear, Canva. The two spellings collapse to one URL here, and
      // the common case must not pay for a duplicate request.
      expect(urlsFor('https://mcp.notion.com'), [
        'https://mcp.notion.com/.well-known/oauth-authorization-server',
        'https://mcp.notion.com/.well-known/openid-configuration',
      ]);
    });

    test('a trailing slash on the issuer is not a path', () {
      // `https://auth.prisma.io/` is published exactly like this.
      expect(urlsFor('https://auth.prisma.io/'), [
        'https://auth.prisma.io/.well-known/oauth-authorization-server',
        'https://auth.prisma.io/.well-known/openid-configuration',
      ]);
    });

    test('a deep path keeps every segment, in order', () {
      // GitHub: `https://github.com/login/oauth`.
      expect(
        urlsFor('https://github.com/login/oauth').first,
        [
          'https://github.com/.well-known/oauth-authorization-server/login/oauth',
        ].single,
      );
    });
  });

  group('resourceMetadataCandidates', () {
    List<String> urlsFor(String resource) =>
        McpAuthProbe.resourceMetadataCandidates(
          Uri.parse(resource),
        ).map((u) => u.toString()).toList();

    test('inserts the well-known before the path, then falls back', () {
      // RFC 9728 §3.1, the same rule RFC 8414 uses for the authorization
      // server. Only the bare origin was tried before, which happened to work
      // for Hugging Face — it serves both — and would miss a resource that
      // publishes only the spelling the RFC names.
      expect(urlsFor('https://huggingface.co/mcp'), [
        'https://huggingface.co/.well-known/oauth-protected-resource/mcp',
        'https://huggingface.co/.well-known/oauth-protected-resource',
      ]);
    });

    test('a resource with no path asks once, not twice', () {
      expect(urlsFor('https://mcp.stripe.com'), [
        'https://mcp.stripe.com/.well-known/oauth-protected-resource',
      ]);
    });

    test('a trailing slash is not a path', () {
      expect(urlsFor('https://mcp.miro.com/'), [
        'https://mcp.miro.com/.well-known/oauth-protected-resource',
      ]);
    });

    test('a deep path keeps every segment', () {
      expect(
        urlsFor('https://gateway.example.com/yahoo/mcp').first,
        [
          'https://gateway.example.com/.well-known/oauth-protected-resource/yahoo/mcp',
        ].single,
      );
    });

    test('a query on the resource is not carried into the metadata URL', () {
      expect(
        urlsFor('https://mcp.example.com/mcp?tenant=7').first,
        isNot(contains('tenant')),
      );
    });
  });

  group('resourceMetadataFrom', () {
    test('reads a quoted value', () {
      expect(
        resourceMetadataFrom(
          'Bearer realm="mcp", '
          'resource_metadata="https://mcp.notion.com/.well-known/oauth-protected-resource"',
        ),
        Uri.parse(
          'https://mcp.notion.com/.well-known/oauth-protected-resource',
        ),
      );
    });

    test('reads a bare value', () {
      // Stripe sends it unquoted, which RFC 7235 allows. Requiring quotes read
      // this as "no hint given" and fell through to a guess that happened to
      // match — silently, which is the part worth a test.
      expect(
        resourceMetadataFrom(
          'Bearer resource_metadata=https://mcp.stripe.com/.well-known/oauth-protected-resource',
        ),
        Uri.parse(
          'https://mcp.stripe.com/.well-known/oauth-protected-resource',
        ),
      );
    });

    test('a bare value stops at the next parameter', () {
      expect(
        resourceMetadataFrom(
          'Bearer resource_metadata=https://x/meta, error="invalid_token"',
        ),
        Uri.parse('https://x/meta'),
      );
    });

    test('a quoted value survives a comma inside it', () {
      // Supabase's header is a three-parameter list whose descriptions contain
      // commas; splitting on commas loses the parameter that matters.
      expect(
        resourceMetadataFrom(
          'Bearer error="invalid_request", '
          'error_description="No token was provided, so this failed", '
          'resource_metadata="https://mcp.supabase.com/.well-known/oauth-protected-resource"',
        ),
        Uri.parse(
          'https://mcp.supabase.com/.well-known/oauth-protected-resource',
        ),
      );
    });

    test('a header with no hint is null, not an empty Uri', () {
      expect(resourceMetadataFrom('Bearer realm="mcp"'), isNull);
      expect(resourceMetadataFrom(''), isNull);
    });
  });
}
