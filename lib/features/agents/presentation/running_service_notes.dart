import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../../shared/widgets/composer_status_line.dart';
import '../../../shared/widgets/toast.dart';
import '../logic/served_service.dart';

/// What the assistant has left running on this computer, for the composer's
/// status strip.
///
/// Not "in this chat": the record carries no conversation, the process outlives
/// the chat that started it, and a line claiming otherwise would be inventing a
/// link that isn't there. It says *this computer*, which is what's true.
///
/// Empty when nothing is running — which is the usual case, so the strip draws
/// nothing at all.
List<StatusNote> runningServiceNotes(WidgetRef ref) {
  final services = ref.watch(servedServicesProvider).value ?? const [];
  return [
    for (final status in services)
      StatusNote(
        icon: Icons.dns_outlined,
        label: serviceLabel(status),
        actions: [
          if (status.service.url case final url?)
            TextButton(
              onPressed: () => launchUrl(Uri.parse(url)),
              child: const Text('Open'),
            ),
          _StopButton(name: status.service.name),
        ],
      ),
  ];
}

/// The one line per service.
///
/// A port that answers is the only thing the app can honestly call "running";
/// with no port there is nothing to ask, so the line says what it knows — that
/// it was started — rather than claiming a state it cannot check (§5).
String serviceLabel(ServiceStatus status) {
  final name = status.service.name;
  final port = status.service.port;
  return switch (status.answering) {
    true => '$name is running on port $port',
    false =>
      '$name was started on port $port, but nothing is answering there now',
    null => '$name was started on this computer',
  };
}

/// Stop one service, and say so when it couldn't be stopped.
///
/// Stateful for the seconds the stop takes: without it a click looks like it did
/// nothing until the row happens to redraw, and the user clicks again.
class _StopButton extends ConsumerStatefulWidget {
  const _StopButton({required this.name});

  final String name;

  @override
  ConsumerState<_StopButton> createState() => _StopButtonState();
}

class _StopButtonState extends ConsumerState<_StopButton> {
  bool _stopping = false;

  Future<void> _stop() async {
    setState(() => _stopping = true);
    final stopped = await stopServedService(widget.name);
    if (!mounted) return;
    setState(() => _stopping = false);
    // Ask again either way: a stop that failed must not leave the row reading
    // as though it worked.
    ref.invalidate(servedServicesProvider);
    if (stopped) return;
    ToastScope.show(
      context,
      ToastSpec(
        message:
            "Couldn't stop ${widget.name} — it may need stopping from a "
            'terminal.',
        severity: ToastSeverity.error,
      ),
    );
  }

  @override
  Widget build(BuildContext context) => TextButton(
    onPressed: _stopping ? null : _stop,
    child: Text(_stopping ? 'Stopping…' : 'Stop'),
  );
}
