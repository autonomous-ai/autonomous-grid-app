/// Stand-in descriptions for connectors the gateway ships without one.
///
/// **This is scaffolding, and it is meant to be deleted** — the same bargain as
/// `rest_entry_fallback.dart`, for the same reason. D14 makes the gateway the
/// source of truth for presentation: a row arrives with `label`, `description`
/// and `image_url` filled in, and copy living in the app ships on the app's
/// release cadence instead of a backend edit.
///
/// It exists because the backend has not filled the column in. Measured against
/// `GET /v1/grid/connectors` on 2026-07-31: eight of twelve connectors return
/// `description: ""` — `asana`, `amplitude`, `figma-api-app`, `github`,
/// `hubspot`, `linear`, `mondaydotcom`, `slack`. Only `gmail` and
/// `google_calendar` carry real copy; `google_drive` and `notion` carry
/// placeholders ("Google drive description"), which the gateway still wins with,
/// because a placeholder is a statement that someone is editing that row.
///
/// **The gateway always wins.** This is applied through
/// `ConnectorCatalogEntry.withPresentation`, which only fills fields the entry
/// left empty — so the moment the backend sends copy, that copy shows, with no
/// flag and no release. Deleting this file is then the whole migration.
///
/// One sentence each, written to answer the only question a user opening the
/// dialog has: *what do I get if I connect this?* Deliberately about the
/// service's own vocabulary — issues, boards, deals — rather than about MCP or
/// tools, which is what the rest of that dialog already avoids saying.
const Map<String, String> _blurbs = {
  'amplitude':
      'Product analytics: charts, funnels and user behaviour from your '
      'Amplitude projects.',
  'asana': 'Tasks, projects and workloads across your Asana workspaces.',
  'figma-api-app':
      'Design files in Figma — read a file, its pages and the layers inside it.',
  'github':
      'Repositories, issues and pull requests on GitHub, including code search.',
  'hubspot': 'Contacts, companies and deals in your HubSpot CRM.',
  'linear': 'Issues, projects and cycles from your Linear workspace.',
  'mondaydotcom': 'Boards, items and updates from your monday.com account.',
  'notion': 'Pages and databases in your Notion workspace.',
  'slack':
      'Messages, channels and threads in your Slack workspace — read them and '
      'post to them.',
};

/// The stand-in blurb for [code], or empty when there is none.
///
/// Empty rather than a generic sentence: "Connect this service" tells the reader
/// nothing they did not get from the button they are looking at, and a dialog
/// with no description reads as a service that needs no explanation rather than
/// as one the app failed to describe.
String connectorBlurbFallback(String code) => _blurbs[code] ?? '';
