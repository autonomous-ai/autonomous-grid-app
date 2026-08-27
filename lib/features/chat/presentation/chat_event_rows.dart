import 'package:flutter/material.dart';

import '../../../shared/widgets/transcript_event_row.dart';
import '../logic/commands/chat_compaction.dart';

/// Where `/compact` folded the context up.
///
/// The messages above it are still there to read; this is the line that says
/// the assistant is reading a summary of them instead.
class CompactedRow extends StatelessWidget {
  const CompactedRow({super.key, required this.compaction});

  final ChatCompaction compaction;

  @override
  Widget build(BuildContext context) => TranscriptEventRow(
    icon: Icons.unfold_less_rounded,
    label: compactedDividerLabel(compaction),
  );
}
