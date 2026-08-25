import 'dart:io';

import '../../../shared/skills/agent_skill_home.dart';
import 'grid_web_skill.dart';

/// The method behind a researched answer, as a skill.
///
/// `grid-web` gave every agent a way to search and to read a page. What it did
/// not give them was a *method*: one search, one page, one confident paragraph
/// is what an agent does by default, and it is exactly how a wrong answer gets
/// written in a trustworthy voice.
///
/// So this is the discipline rather than a new tool — several passes, sources
/// that disagree reconciled instead of averaged, a link on every claim, and a
/// plain list of what could not be checked. The last one matters most: an answer
/// that hides its gaps is the one that gets acted on.
///
/// No scripts of its own; it drives `grid-web`'s — which are standard library
/// only, so this card names no package runner either. ⚠️ Removing it from one
/// guide and not the other would leave this one telling an agent to provision a
/// package for a script that no longer uses it.
const String kGridResearchSkillName = 'grid-research';

/// The `grid-research` skill as it lands in [skillDir]. The card names
/// `grid-web`'s scripts by absolute path, so it is built from where that skill
/// sits rather than being a constant.
GridSkillFiles gridResearchSkillFiles(Directory skillDir) {
  // Sibling of this skill's own folder: the installer writes every builtin into
  // the same parent, so `grid-web`'s scripts are one folder over.
  final webScripts = '${skillDir.parent.path}/$kGridWebSkillName/scripts';
  return GridSkillFiles(
    card: gridResearchSkillMd(
      searchScriptPath: '$webScripts/search.py',
      readScriptPath: '$webScripts/read.py',
    ),
  );
}

/// The card. The frontmatter fires on the shape of the question — "compare",
/// "is it true that", "what are the options" — not on the word "research",
/// which is not what people type.
String gridResearchSkillMd({
  required String searchScriptPath,
  required String readScriptPath,
}) =>
    '''
---
name: grid-research
description: >-
  Answer a question that needs evidence, not recall: comparing options,
  checking whether something is true, finding what changed, or anything where
  being wrong matters. Searches several ways, reads the actual pages, and
  writes an answer where every claim carries the link it came from.
---

# Researching an answer properly

One search, one page and a confident paragraph is how a wrong answer gets
written in a trustworthy voice. Do this instead.

## 1. Ask more than one way

Two or three searches with **different wording**, not the same query rephrased:
the words a vendor uses, the words a critic uses, and the plain words the user
used. Each surfaces a different set of pages.

```
python3 "$searchScriptPath" "<query>"
```

## 2. Read the pages, don't trust the snippets

A search snippet is written to be clicked, not to be true. Open the three or
four that look most likely to hold the answer — including at least one that
disagrees with the others, if there is one.

```
python3 "$readScriptPath" "<url>"
```

## 3. Reconcile, don't average

When sources disagree, say so and say which you believe, with the reason: it is
more recent, it is the primary source, the other is quoting it second-hand.
Never split the difference — a number nobody published is worse than either
number.

## 4. Write it with the links in it

- Every claim that could be wrong carries a markdown link to the page it came
  from, inline: `the limit is 200 requests ([docs](https://…))`.
- A date on anything that moves — prices, versions, limits, availability.
- Lead with the answer. The evidence supports it; it doesn't precede it.

## 5. Say what you could not check

Finish with a short **"Not verified"** list: what you looked for and didn't
find, what only one source said, what was behind a login. An answer that hides
its gaps is the one that gets acted on.

If the web gave you nothing usable, say that plainly. A researched-sounding
answer with no sources behind it is the worst thing this skill can produce.
''';
