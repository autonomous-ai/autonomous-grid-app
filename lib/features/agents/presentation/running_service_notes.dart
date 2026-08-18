import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../../infrastructure/logging/app_log.dart';
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
          // Only while something answers there. The same row that just said
          // nothing is listening must not also offer to open it: that button
          // leads to a browser error page, which is the app telling the user
          // twice that it doesn't know what is going on (§5).
          if (status.answering != false)
            if (status.service.url case final url?)
              TextButton(
                onPressed: () => launchUrl(Uri.parse(url)),
                child: const Text('Open'),
              ),
          _StopButton(service: status.service, answering: status.answering),
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

/// What to say when the service outlived the stop.
///
/// Names the port, because that is how the user finds it, and names the way
/// out — a terminal — rather than only reporting that the click failed (§5).
String stopFailedMessage(ServedService service) {
  final port = service.port;
  final where = port == null ? '' : ' on port $port';
  return "Couldn't stop ${service.name}$where — it's still running, so it may "
      'need stopping from a terminal.';
}

/// Stop one service — or, when nothing is answering for it any more, take its
/// row away.
///
/// Stateful for the seconds the stop takes: without it a click looks like it did
/// nothing until the row happens to redraw, and the user clicks again. Which is
/// exactly what they did while the row could not be cleared at all, so the
/// button now promises only what it can deliver.
class _StopButton extends ConsumerStatefulWidget {
  const _StopButton({required this.service, required this.answering});

  final ServedService service;

  /// Whether its port answers — null when there is no port to ask.
  final bool? answering;

  @override
  ConsumerState<_StopButton> createState() => _StopButtonState();
}

class _StopButtonState extends ConsumerState<_StopButton> {
  bool _busy = false;

  /// What the button says, before and during the click.
  ///
  /// "Stop" only where there may be something to stop: on a row that already
  /// says nothing is answering there, the honest promise is that the row goes.
  ({String idle, String busy}) get _words => widget.answering == false
      ? (idle: 'Clear', busy: 'Clearing…')
      : (idle: 'Stop', busy: 'Stopping…');

  Future<void> _stop() async {
    setState(() => _busy = true);
    final outcome = await stopServedService(
      widget.service,
      log: ref.read(appLogProvider),
    );
    if (!mounted) return;
    setState(() => _busy = false);
    // Ask again either way: a stop that failed must not leave the row reading
    // as though it worked.
    ref.invalidate(servedServicesProvider);
    if (outcome != ServiceStopOutcome.stillRunning) return;
    ToastScope.show(
      context,
      ToastSpec(
        message: stopFailedMessage(widget.service),
        severity: ToastSeverity.error,
      ),
    );
  }

  @override
  Widget build(BuildContext context) => TextButton(
    onPressed: _busy ? null : _stop,
    child: Text(_busy ? _words.busy : _words.idle),
  );
}
