import 'package:flutter/material.dart';

import '../../../shared/theme/app_theme.dart';
import '../../../shared/widgets/labeled_field.dart';
import '../logic/engine_endpoint.dart';
import '../logic/engine_reachability.dart';

/// Where someone types the address of an engine they run themselves, with the
/// URL Grid will actually call echoed underneath it.
///
/// The echo is the whole point of this widget existing rather than a plain
/// [LabeledField]. A person pasting an address has their own server's docs open
/// beside them, and those docs show a `curl` against the full endpoint — so a
/// line reading back `…/chat/completions` is directly comparable, and a missing
/// `/v1` stands out at the moment it can still be fixed for free. Left to the
/// old bare field, the same mistake surfaced as a node that joined, went green,
/// and then refused every message
/// (`1_docs/bubu/BUG-GBX03073-3-REQUEST-FAILED-404.md`).
class ServerAddressField extends StatelessWidget {
  const ServerAddressField({
    super.key,
    required this.controller,
    required this.checking,
    required this.reach,
    required this.onRetry,
  });

  final TextEditingController controller;

  /// A check is scheduled or in flight. Covers the typing pause too, so the
  /// line never reads "ready" in the gap before the request goes out.
  final bool checking;

  /// The last check's outcome for **this** address, or null when there isn't
  /// one yet.
  final EngineReach? reach;

  /// Ask the server again — for the ordinary case of an engine that had not
  /// finished starting up when the first check went out.
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: controller,
      builder: (context, _) {
        final address = readEngineAddress(controller.text);
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            LabeledField(
              // The design names the *kind* of thing in the label, because
              // "server address" tells someone who has one where to put it and
              // tells someone who hasn't nothing at all.
              label: 'Endpoint, any OpenAI-compatible server',
              controller: controller,
              // The full endpoint, not the base: it is what people have in
              // front of them, so it can be pasted whole. The suffix is cut
              // back off in `readEngineAddress`.
              hint: 'http://localhost:8080/v1/chat/completions',
              error: switch (address) {
                EngineAddressRejected(:final message) => message,
                _ => null,
              },
            ),
            _Status(
              address: address,
              checking: checking,
              reach: reach,
              onRetry: onRetry,
            ),
          ],
        );
      },
    );
  }
}

/// The line under the field: what will be called, or why nothing could be.
class _Status extends StatelessWidget {
  const _Status({
    required this.address,
    required this.checking,
    required this.reach,
    required this.onRetry,
  });

  final EngineAddress address;
  final bool checking;
  final EngineReach? reach;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    // A rejected address already says its piece through the field's own error
    // ink; a second line under it would say the same thing twice.
    if (address is! EngineAddressReady) return const SizedBox.shrink();
    final ready = address as EngineAddressReady;
    if (checking) {
      return const _Line('Checking the server…', icon: Icons.sync_rounded);
    }
    if (reach case EngineUnreachable(:final message)) {
      return _Line(
        message,
        icon: Icons.error_outline_rounded,
        bad: true,
        onRetry: onRetry,
      );
    }
    // Named even once the server has answered: the address is still the thing
    // most likely to be subtly wrong, and it stays comparable against the
    // `curl` in the server's own docs for as long as the form is open.
    return _Line(
      'Grid will call ${ready.chatUrl}',
      icon: reach is EngineReachable
          ? Icons.check_rounded
          : Icons.arrow_forward_rounded,
    );
  }
}

class _Line extends StatelessWidget {
  const _Line(this.text, {required this.icon, this.bad = false, this.onRetry});

  final String text;
  final IconData icon;
  final bool bad;

  /// Offered only on a failure, where the usual cause is an engine that hadn't
  /// finished starting — retyping a correct address to ask again is a chore
  /// with nothing to teach.
  final VoidCallback? onRetry;

  @override
  Widget build(BuildContext context) {
    final ink = bad ? fieldErrorInk() : AppPalette.textFaint;
    return Padding(
      padding: const EdgeInsets.only(left: 2, top: 6),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.only(top: 1),
            child: Icon(icon, size: 13, color: ink),
          ),
          const SizedBox(width: 6),
          // The URL can be long and the rail is not; wrapping keeps it readable
          // instead of trailing off into an ellipsis where the interesting part
          // — the end of the path — lives.
          Expanded(
            child: Text(
              text,
              style: TextStyle(fontSize: 11.5, color: ink, height: 1.35),
            ),
          ),
          if (onRetry case final retry?) ...[
            const SizedBox(width: 8),
            TextButton(
              style: TextButton.styleFrom(
                minimumSize: const Size(0, AppControl.heightSmall),
                padding: AppControl.paddingSmall,
                textStyle: const TextStyle(fontSize: 11.5),
              ),
              onPressed: retry,
              child: const Text('Try again'),
            ),
          ],
        ],
      ),
    );
  }
}
