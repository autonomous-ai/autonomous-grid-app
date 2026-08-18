import 'package:flutter/material.dart';

import '../theme/app_theme.dart';

/// A line across the transcript for something that happened *to* the
/// conversation rather than something said in it — the context folded up, a
/// goal met, a repeating prompt stopped.
///
/// It sits in the conversation because that is where the fact lives, at the
/// point it happened: the messages around it are still there to read, and this
/// says what changed between them. The alternative the app used to run — a card
/// pinned over the composer until the user waved it away — told the news at the
/// moment it happened and then went on telling it for the rest of the day,
/// between the transcript and the box the user was typing in.
/// A quiet aside beside a turn — not a rule across the whole transcript.
///
/// [TranscriptEventRow] draws a line through the conversation, which is right
/// for something that changed it for good (the context folded up). A goal
/// starting or finishing is smaller than that: it belongs to *one* turn, reads
/// in a glance, and a full-width rule for it made every goal look like a chapter
/// break. It is also what keeps the line short — the long form is what `/goal`
/// prints when asked.
class TranscriptSideNote extends StatelessWidget {
  const TranscriptSideNote({
    super.key,
    required this.icon,
    required this.label,
    this.alignment = Alignment.centerLeft,
  });

  final IconData icon;

  /// A few words. Anything that needs a sentence belongs in the answer above.
  final String label;

  /// Right for something the *user* did (it sits under their own message),
  /// left for something the assistant or the app did.
  final Alignment alignment;

  @override
  Widget build(BuildContext context) {
    AppTheme.watch(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 2, 12, 8),
      child: Align(
        alignment: alignment,
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 13, color: AppPalette.textFaint),
            const SizedBox(width: 6),
            // Bounded even though it is short: a narrow window is still a
            // window, and this one sits inside a Row that would otherwise
            // measure it against infinity.
            Flexible(
              child: Text(
                label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(fontSize: 12, color: AppPalette.textFaint),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class TranscriptEventRow extends StatelessWidget {
  const TranscriptEventRow({
    super.key,
    required this.icon,
    required this.label,
  });

  final IconData icon;

  /// One line, in the user's terms. Centred between two rules, so it reads as a
  /// marker in the conversation rather than another message in it.
  final String label;

  @override
  Widget build(BuildContext context) {
    AppTheme.watch(context); // rebuild on theme flip — reads palette tokens
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 14),
      child: LayoutBuilder(
        builder: (context, constraints) => Row(
          children: [
            Expanded(child: Divider(color: AppPalette.divider, height: 1)),
            // The `Flexible` inside is not enough on its own, and this is why:
            // a Row lays a **non-flex** child out with an unbounded main axis,
            // so the cluster below used to be measured against infinity. The
            // text then never had a width to wrap at and laid the whole
            // sentence out in one line — 226px past the window, in stripes.
            //
            // Bounding it here is what gives the text something to wrap at. A
            // share rather than a fixed number, because the rules on either
            // side have to stay visible at any window width; loose, so a short
            // label still sits centred between them instead of being stretched
            // to the cap.
            ConstrainedBox(
              constraints: BoxConstraints(maxWidth: constraints.maxWidth * 0.9),
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 12),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(icon, size: 15, color: AppPalette.textFaint),
                    const SizedBox(width: 6),
                    Flexible(
                      child: Text(
                        label,
                        textAlign: TextAlign.center,
                        style: TextStyle(
                          fontSize: 12,
                          color: AppPalette.textFaint,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
            Expanded(child: Divider(color: AppPalette.divider, height: 1)),
          ],
        ),
      ),
    );
  }
}
