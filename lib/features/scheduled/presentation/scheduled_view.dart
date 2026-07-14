import 'package:flutter/material.dart';

import '../../../shared/widgets/coming_soon_view.dart';

/// The Scheduled screen: work you hand the assistant to run on its own, on a
/// timer, instead of sitting in the chat waiting for it.
///
/// Not built yet — this states that plainly rather than shipping buttons that
/// don't do anything. TODO(BE): needs a job store + a runner that can wake the
/// agent while the app is idle.
class ScheduledView extends StatelessWidget {
  const ScheduledView({super.key});

  @override
  Widget build(BuildContext context) {
    return const ComingSoonView(
      title: 'Scheduled',
      subtitle:
          'Tasks the assistant runs on its own — every morning, every hour, on '
          'the day you pick.',
      icon: Icons.schedule_rounded,
      points: [
        'Hand it a task and a time — "summarise my notes every Monday".',
        'Let it run on your grid while you get on with something else.',
        'Come back to the answer waiting for you in a chat.',
      ],
    );
  }
}
