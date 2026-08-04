/// A subject to narrow the directory by — Finance, Design, Developer.
///
/// **These are search terms wearing a label, not a taxonomy.** The registry has
/// no category field: a server carries `displayName`, `description`,
/// `useCount`, `verified` and little else, and there is nothing on it to group
/// by. Filter tokens do not help either — measured 2026-08-04, `category:zzzz`
/// and `category:finance` both answer with the identical 100 rows, which is
/// what the registry returns when it cannot parse a token. So `category:` is
/// not a feature it has; using it would quietly serve wrong results.
///
/// What does work is ordinary search. Each entry below carries the query that
/// produced a coherent first page when it was checked against the live
/// registry, and the label is what the user reads. The two are allowed to
/// differ where the label makes a poor query: "Data" searches `database`,
/// because the word "data" appears in a large share of the directory's
/// descriptions and matches almost nothing usefully.
///
/// Six, cut down from ten (Tony, 2026-08-04). The four dropped —
/// Communication, Search, Cloud, Analytics — each returned a coherent page, so
/// this is a judgement about how many subjects a filter bar should offer rather
/// than about any of them being wrong. The counts in the comments are the
/// totals when each was checked and will drift as the directory grows.
enum ConnectorCategory {
  finance('Finance', 'finance'), // 167 — Ynab, Organizze, Hiro
  developer('Developer', 'developer'), // 170 — Wakatime, Gitlab, DevMatch
  productivity('Productivity', 'productivity'), // 200 — Todoist, Google Tasks
  data('Data', 'database'), // 169 — Neon, Tinybird, PubMed
  design('Design', 'design'), // 143 — Canva, Webflow
  marketing('Marketing', 'marketing'); // 187 — Facebook, VibeMarketing

  const ConnectorCategory(this.label, this.query);

  /// What the pill reads.
  final String label;

  /// What is actually sent to the registry. See the note above on why this is
  /// not always the label lower-cased.
  final String query;
}

/// The text to search for [category] alongside the user's own words.
///
/// Both, when there are both: a user who has typed "stripe" with Finance
/// selected means stripe *within* that subject, and dropping either half
/// answers a question they did not ask. The registry ANDs the terms, so this
/// reads the way it looks — `stripe finance` returns Stripe first, measured
/// against the live registry.
String categorySearchTerms(ConnectorCategory? category, String query) {
  final typed = query.trim();
  final subject = category?.query ?? '';
  if (subject.isEmpty) return typed;
  if (typed.isEmpty) return subject;
  return '$typed $subject';
}
