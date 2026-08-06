import 'dart:io';

import '../../../shared/skills/agent_skill_home.dart';

/// The skill that tells an agent the app can draw, and how to ask.
///
/// Without it the format is a secret: the transcript renders a ```chart fence as
/// a chart (see `ChartSpec`), and no agent would ever emit one because nothing
/// told it the fence exists. So the capability shipped invisible — the same
/// failure as a button drawn off-screen.
///
/// No scripts: the whole skill is a card. The agent already has the numbers by
/// the time this matters; what it needs is the shape to put them in.
const String kGridChartSkillName = 'grid-chart';

/// The `grid-chart` skill as it lands in [skillDir]. Takes the directory like
/// every other builtin so the registry can treat them alike, though this one has
/// nothing on disk to point at.
GridSkillFiles gridChartSkillFiles(Directory skillDir) =>
    const GridSkillFiles(card: kGridChartSkillMd);

/// The card. The frontmatter decides when it fires, so it names the words a
/// person actually uses ("chart", "graph", "plot", "trend") rather than the
/// fence they've never heard of.
const String kGridChartSkillMd = '''
---
name: grid-chart
description: >-
  Draw a chart in the Grid chat instead of listing numbers. Use whenever the
  answer compares quantities across categories or shows a value changing over
  time — a chart, graph, plot, trend, breakdown, or "how has X changed". Grid
  renders the block below as a real chart in the reply.
---

# Showing numbers as a chart

Grid's chat draws a fenced `chart` block as a chart. Anywhere you would have
written a table of numbers whose *shape* is the point, write one of these
instead — and keep the sentence that says what it shows.

## The format

A `chart` fence holding one JSON object:

```chart
{
  "type": "bar",
  "title": "Requests per day",
  "labels": ["Mon", "Tue", "Wed", "Thu", "Fri"],
  "values": [120, 180, 90, 240, 210]
}
```

- `type` — `bar` to compare things side by side, `line` for a value moving
  through a sequence. Defaults to `bar`.
- `title` — optional, one short line.
- `labels` — one per point, along the bottom. Required.
- `values` — the numbers, for a single-series chart.

For more than one series, replace `values` with `series`:

```chart
{
  "type": "line",
  "title": "Response time",
  "labels": ["Jan", "Feb", "Mar", "Apr"],
  "series": [
    {"name": "p50", "values": [120, 118, 140, 132]},
    {"name": "p95", "values": [420, 460, 510, 480]}
  ]
}
```

## Rules

- **Numbers only.** Every value must be a plain number — no units, no `"1.2k"`,
  no `null`. Convert first and say the unit in the title.
- **One label per value.** A series longer than `labels` is cut; a shorter one
  is drawn short. Neither is what you meant, so line them up.
- **Say it too.** The chart is not the answer on its own — one sentence above it
  saying what it shows, because a reader who skims the picture still needs the
  finding.
- **Don't chart two points.** A pair of numbers is a sentence, not a chart.
- If the block can't be parsed it shows as plain code, so a malformed chart
  costs the reader nothing except the picture.
''';
