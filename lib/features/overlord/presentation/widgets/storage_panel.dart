import 'package:flutter/material.dart';

import 'panel_frame.dart';
import 'panel_message.dart';

/// Middle column placeholder — CPU/RAM/network and disk mounts land here next.
class StoragePanel extends StatelessWidget {
  const StoragePanel({super.key});

  @override
  Widget build(BuildContext context) {
    return const PanelFrame(
      label: 'Storage & System',
      child: PanelMessage(
        icon: Icons.storage_outlined,
        text: 'Storage & System\ncoming next',
      ),
    );
  }
}
