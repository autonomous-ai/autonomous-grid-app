/// Where a hand-configured MCP server's icon comes from.
///
/// Catalog connectors carry an `image_url` the gateway chose. A server the user
/// typed a URL for has nothing — the gateway has never heard of it, and the MCP
/// endpoint itself does not serve a favicon (`mcp.supabase.com/favicon.ico`
/// returns 404, measured 2026-07-30). The only thing left is to ask a favicon
/// service about the host.
///
/// **This sends the hostname to a third party**, which is the one thing in this
/// file worth pausing over. It is a real cost, accepted deliberately: rule 1
/// says only the catalog reaches a server, and this widens that to "the catalog
/// and the icon lookup". The mitigation is [faviconUrl] refusing every host that
/// could be private — a name that never leaves this machine must not leak
/// through a request for a picture.
library;

/// Google's favicon service, at 128px.
///
/// `sz` is a ceiling rather than a promise: measured 2026-07-30, `notion.com`
/// honours it (128×128), `linear.app` and `asana.com` cap at 48, `github.com`
/// at 32, and `supabase.com` only ever returns 16 — the same 16 whether asked
/// for 64, 128 or 256. Asking for more than the row needs costs nothing and
/// takes the best each host has.
///
/// DuckDuckGo's equivalent was rejected, though it serves *larger* icons: it
/// returns `image/vnd.microsoft.icon`, and Flutter's codecs cannot decode `.ico`
/// at all. That failure is invisible — a clean 200 followed by a blank — and it
/// is the same one that sent Figma's SVG mark to the fallback glyph (`1d72ee6`).
const String _service = 'https://www.google.com/s2/favicons';

/// The icon URL for [serverUrl], or empty when this host must not be asked
/// about.
///
/// Empty is not a failure — it is the row falling back to its transport glyph,
/// which is what every unknown server looked like before this existed.
String faviconUrl(String serverUrl) {
  final host = faviconHost(serverUrl);
  return host.isEmpty ? '' : faviconUrlForHost(host);
}

/// The service URL for an already-vetted [host].
String faviconUrlForHost(String host) =>
    '$_service?domain=${Uri.encodeQueryComponent(host)}&sz=128';

/// The host to ask about, or empty when this one must not be asked about.
///
/// **Asks about the registrable domain, not the MCP subdomain.** Measured
/// 2026-07-30, and it is the difference between an icon and a grey globe:
///
/// ```
/// mcp.browserbase.com  → 404   browserbase.com → 200, 128×128
/// mcp.supabase.com     → 404   supabase.com    → 200,  16×16
/// mcp.notion.com       → 404   notion.com      → 200, 128×128
/// ```
///
/// Every `mcp.*` subdomain measured returns 404 — an MCP endpoint is an API host
/// and serves no favicon. The brand lives on the apex. Since MCP servers are
/// *conventionally* published on such a subdomain, asking about the host as
/// typed would fail for almost every connector this feature exists to decorate.
///
/// The trim is one label deep, deliberately. Walking further up would turn
/// `mcp.eu.acme.co.uk` into `co.uk` and show the wrong brand entirely; the
/// public-suffix list that would make this exact is a dependency and a data file
/// to keep current, for a picture. One level covers the convention it is aimed
/// at, and anything else keeps its own host.
String faviconHost(String serverUrl) {
  final uri = Uri.tryParse(serverUrl.trim());
  if (uri == null || !uri.hasAuthority) return '';
  final host = uri.host.toLowerCase();
  if (host.isEmpty || !isPubliclyResolvable(host)) return '';

  final labels = host.split('.');
  // Only `mcp.<something>.<tld>` is rewritten, and only when a real domain is
  // left afterwards. `mcp.com` stays as it is.
  if (labels.length > 2 && labels.first == 'mcp') {
    return labels.sublist(1).join('.');
  }
  return host;
}

/// Whether [host] is a name the public internet could resolve, and so one that
/// is safe to hand to an icon service.
///
/// The point is not that a private host would fail the lookup — it would, and
/// harmlessly. The point is that **asking is itself the disclosure.** A company
/// running `mcp.acme-internal.corp` has told this app a name that describes
/// their infrastructure; sending it to Google to fetch a picture leaks it to a
/// third party, and nothing about the resulting glyph would tell the user it
/// happened.
///
/// So the test runs before any request, and it is deliberately conservative:
/// anything that cannot be shown to be public is treated as private.
bool isPubliclyResolvable(String host) {
  // Any literal IP address. A public one would work, but an MCP server reached
  // by raw IP has no brand to show anyway, and distinguishing public from
  // private ranges here would be a second thing to get subtly wrong.
  if (_looksLikeIpAddress(host)) return false;

  // No dot means a single-label name — `localhost`, or an intranet short name
  // resolved by search domain. Never public.
  if (!host.contains('.')) return false;

  // Reserved and special-use TLDs (RFC 6761, RFC 8375) plus the conventional
  // ones. `.local` is mDNS; `.internal` and `.corp` are what private networks
  // actually use.
  const privateSuffixes = [
    '.local',
    '.localhost',
    '.internal',
    '.intranet',
    '.private',
    '.corp',
    '.home',
    '.lan',
    '.test',
    '.example',
    '.invalid',
    '.home.arpa',
  ];
  for (final suffix in privateSuffixes) {
    if (host.endsWith(suffix)) return false;
  }

  return true;
}

/// True for IPv4 dotted quads and anything carrying a colon (IPv6).
///
/// `Uri.host` strips the brackets from `[::1]`, so the colon test is what
/// catches IPv6 — checking for brackets would never match.
bool _looksLikeIpAddress(String host) {
  if (host.contains(':')) return true;
  final parts = host.split('.');
  if (parts.length != 4) return false;
  return parts.every((part) {
    final value = int.tryParse(part);
    return value != null && value >= 0 && value <= 255;
  });
}
