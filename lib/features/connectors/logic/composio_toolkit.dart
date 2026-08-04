/// One integration in Composio's catalog — Gmail, Slack, Notion.
///
/// Composio calls these *toolkits*: a service plus the tools it exposes and the
/// way it signs in. They are the rows the Connectors screen browses, and they
/// replace `SmitheryServer` in that job.
///
/// **The shape is Composio's, not this app's.** Fields are read straight from
/// `GET /api/v3/toolkits`, which the Grid backend proxies verbatim — see
/// `ComposioCatalogClient` for why the proxy exists rather than the app calling
/// Composio directly. Keeping the parse faithful to the upstream body means a
/// backend that only attaches a key stays a pass-through, with nothing to keep
/// in sync on either side.
class ComposioToolkit {
  const ComposioToolkit({
    required this.slug,
    required this.name,
    this.description = '',
    this.logoUrl = '',
    this.categories = const [],
    this.noAuth = false,
    this.authSchemes = const [],
    this.managedAuthSchemes = const [],
    this.toolsCount = 0,
  });

  /// Composio's stable id — `gmail`, `googlesheets`. Lower-case, no slashes.
  ///
  /// **Also this app's connector id**, unchanged. Smithery's `qualifiedName`
  /// carried a publisher prefix (`smithery-ai/gmail`) that had to be rewritten
  /// to be usable as a key; a Composio slug is already the flat, stable name
  /// the token store and the agent projections want, so nothing is derived and
  /// nothing can drift.
  final String slug;

  /// The display name Composio publishes — "Gmail", "Google Sheets".
  final String name;

  /// Plain prose from `meta.description`.
  final String description;

  /// `meta.logo`. May be empty, and 29 of these were measured 404 upstream in
  /// Composio's own issue tracker — so the mark widget's fallback matters here
  /// exactly as much as it did for the previous directory.
  final String logoUrl;

  /// Subject labels from `meta.categories`, already flattened to their names.
  final List<String> categories;

  /// The toolkit needs no sign-in at all.
  ///
  /// Kept because it changes what the Connect button should even say: a
  /// no-auth toolkit is usable the moment it is added, and sending the user to
  /// a browser for it would be a round trip to nowhere.
  final bool noAuth;

  /// How this toolkit can be signed into — `OAUTH2`, `API_KEY`, `BEARER_TOKEN`.
  final List<String> authSchemes;

  /// The subset of [authSchemes] for which **Composio supplies the OAuth app**,
  /// so no client id or secret has to be registered by anyone here.
  ///
  /// The practical test for "can this be connected today": a toolkit whose only
  /// scheme is `API_KEY`, or whose OAuth is not Composio-managed, needs a
  /// developer-side auth config before any user can link it. See
  /// [connectableToday].
  final List<String> managedAuthSchemes;

  /// How many tools the toolkit exposes, from `meta.tools_count`.
  ///
  /// Stands in for Smithery's `useCount` as the row's one quality signal. It is
  /// a different quantity — breadth rather than popularity — and is labelled as
  /// such on the card rather than being dressed up as a star rating.
  final int toolsCount;

  /// Whether a user can link this without someone configuring it first.
  ///
  /// True when nothing needs signing in, or when Composio brokers the OAuth
  /// app itself. Anything else would send the user to a browser and fail at the
  /// far end, which is the one outcome worth spending a field to avoid.
  bool get connectableToday =>
      noAuth ||
      managedAuthSchemes.any((scheme) => scheme.toUpperCase() == 'OAUTH2');

  static ComposioToolkit? fromJson(Object? raw) {
    if (raw is! Map) return null;
    final slug = raw['slug'];
    if (slug is! String || slug.isEmpty) return null;

    // `meta` holds everything a person reads. A toolkit without it is still a
    // valid row — it just has no blurb or logo — so this degrades rather than
    // rejecting the item.
    final meta = raw['meta'];
    final metaMap = meta is Map ? meta : const {};

    final name = raw['name'];
    return ComposioToolkit(
      slug: slug,
      // Falling back to the slug rather than dropping the row: a nameless
      // toolkit still connects, and `gmail` reads better than a blank card.
      name: name is String && name.isNotEmpty ? name : slug,
      description: _string(metaMap['description']),
      logoUrl: _string(metaMap['logo']),
      categories: _categories(metaMap['categories']),
      noAuth: raw['no_auth'] == true,
      authSchemes: _strings(raw['auth_schemes']),
      managedAuthSchemes: _strings(raw['composio_managed_auth_schemes']),
      toolsCount: _int(metaMap['tools_count']),
    );
  }

  /// `meta.categories` is a list of objects, not strings — each carries an id
  /// and a name. Only the name is ever shown, so only the name survives here.
  static List<String> _categories(Object? raw) {
    if (raw is! List) return const [];
    final names = <String>[];
    for (final item in raw) {
      if (item is Map) {
        final name = item['name'] ?? item['slug'];
        if (name is String && name.isNotEmpty) names.add(name);
      } else if (item is String && item.isNotEmpty) {
        names.add(item);
      }
    }
    return names;
  }

  static List<String> _strings(Object? raw) => raw is List
      ? [
          for (final item in raw)
            if (item is String && item.isNotEmpty) item,
        ]
      : const [];

  static String _string(Object? raw) => raw is String ? raw : '';

  static int _int(Object? raw) => switch (raw) {
    final int value => value,
    final num value => value.toInt(),
    final String value => int.tryParse(value) ?? 0,
    _ => 0,
  };
}

/// One page of the catalog.
///
/// **Cursor-paged, unlike the page numbers the previous directory used.**
/// Composio hands back an opaque `next_cursor` and null means the end; there is
/// no page arithmetic to get wrong and no "page 11 comes back empty" ceiling to
/// discover by measurement.
class ComposioPage {
  const ComposioPage({
    required this.toolkits,
    this.nextCursor,
    this.totalItems = 0,
  });

  final List<ComposioToolkit> toolkits;

  /// Pass to the next request. Null — or absent — means this was the last page.
  final String? nextCursor;

  /// How many toolkits match, across every page.
  final int totalItems;

  bool get hasMore => nextCursor != null && nextCursor!.isNotEmpty;

  static ComposioPage? fromJson(Object? raw) {
    if (raw is! Map) return null;
    final items = raw['items'];
    if (items is! List) return null;

    final cursor = raw['next_cursor'];
    return ComposioPage(
      toolkits: [for (final item in items) ?ComposioToolkit.fromJson(item)],
      nextCursor: cursor is String && cursor.isNotEmpty ? cursor : null,
      totalItems: ComposioToolkit._int(raw['total_items']),
    );
  }
}

/// How the catalog is ordered.
///
/// **Sent to the server, unlike the previous directory's sort.** Smithery had
/// no sort parameter — every spelling of one was measured and returned the
/// identical page — so ordering had to happen locally, over whatever rows
/// happened to be loaded. Composio sorts the whole catalog, so "Most used" now
/// means most-used of all of them rather than most-used of the fifty on screen.
///
/// The cost is that changing sort refetches. That is the honest trade: a local
/// reorder that only ever saw one page was quietly answering a different
/// question than the one the control asks.
enum ComposioToolkitSort {
  /// First, and the default — the same opening the previous directory had.
  mostUsed('Most used', 'usage'),
  name('Name', 'alphabetically');

  const ComposioToolkitSort(this.label, this.parameter);

  final String label;

  /// The literal value Composio's `sort_by` accepts.
  final String parameter;
}
