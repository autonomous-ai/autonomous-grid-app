import 'package:flutter/material.dart';

import '../theme/app_theme.dart';
import '../../features/playground/logic/playground_models.dart';
import '../../features/playground/logic/playground_request.dart';

/// What a model row *does*, not what it is: a text model answers in words, the
/// image mode draws, the video mode takes a picture and moves it. The media
/// entries aren't models at all — they're modes the grid's nodes offer — so the
/// glyph is what tells them apart from the model ids beside them.
///
/// Shared because three screens were each mapping this themselves, with three
/// different sets of glyphs — the chat picker, the playground's picker and its
/// empty state — while one of them carried a comment claiming it matched the
/// others. The mark you pick by has to be the mark you're left looking at.
IconData modalityIcon(PlaygroundModality modality) => switch (modality) {
  // "Aa", not a speech bubble. The bubble was meant to say "answers you in
  // words", but it is the same glyph the command palette puts on *Open a chat* —
  // so in a list of model names it read as "this row is a conversation". The
  // mark's whole job here is text-vs-image-vs-video, and this is the one that
  // says text without also naming something else in the app.
  PlaygroundModality.text => Icons.text_fields_rounded,
  PlaygroundModality.image => Icons.auto_awesome_outlined,
  // Not a film reel — the mode's whole point is that it starts from an image you
  // attach. The play-on-a-frame says "your picture, moving".
  PlaygroundModality.video => Icons.slideshow_outlined,
};

/// The mark for one row of the model list — [modalityIcon], except that a text
/// model says **where it runs** instead of merely that it answers in words.
///
/// A grid mixes both kinds under names that give nothing away: `laguna-s-2.1`
/// runs on a machine in the room, `codex:gpt-5.5` is a node relaying to OpenAI,
/// and the list showed them with one identical glyph. Since the whole product is
/// "models you run yourself", which of the two you are about to send your message
/// to is the most useful thing the row can tell you.
///
/// A model we can't place keeps the plain text mark: no cloud glyph on something
/// that might be private, no computer glyph on something that might not be.
IconData modelIcon(PlaygroundModelOption option) => switch (option.modality) {
  PlaygroundModality.text => switch (option.hosting) {
    ModelHosting.cloud => Icons.cloud_outlined,
    // The same computer the "Run locally" choice wears — one glyph for "a
    // machine is doing this", wherever the app says it.
    ModelHosting.onGrid => Icons.computer_outlined,
    // The router picks per request, so it is neither until it has.
    ModelHosting.routed => Icons.alt_route_rounded,
    ModelHosting.unknown => modalityIcon(option.modality),
  },
  _ => modalityIcon(option.modality),
};

/// Text is the ordinary case and stays in the quiet ink; the media modes are the
/// exceptions and carry a tint, so the eye finds them without the row having to
/// shout. Same reasoning as the approval menu's per-mode hues — colour marks
/// what differs, not everything.
Color modalityTone(PlaygroundModality modality) => switch (modality) {
  PlaygroundModality.text => AppPalette.textFaint,
  PlaygroundModality.image => AppPalette.teal,
  PlaygroundModality.video => AppPalette.brandBolt,
};
