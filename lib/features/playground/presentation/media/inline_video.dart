import 'dart:async';

import 'package:flutter/material.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';

import 'media_chrome.dart';

/// A video played inline with media_kit's adaptive controls. [source] is what
/// the player opens — a network URL (referenced in a chat message) or a local
/// file path (a generated result). [openHref] is what the failure box's "Open"
/// button launches, defaulting to [source]. The clip loads paused; the player is
/// torn down with the widget.
class InlineVideo extends StatefulWidget {
  const InlineVideo({super.key, required this.source, this.openHref});
  final String source;
  final String? openHref;

  @override
  State<InlineVideo> createState() => _InlineVideoState();
}

class _InlineVideoState extends State<InlineVideo> {
  late final Player _player = Player();
  late final VideoController _controller = VideoController(_player);
  StreamSubscription<String>? _errorSub;
  bool _failed = false;

  @override
  void initState() {
    super.initState();
    _errorSub = _player.stream.error.listen((_) {
      if (mounted) setState(() => _failed = true);
    });
    unawaited(_player.open(Media(widget.source), play: false));
  }

  @override
  void dispose() {
    _errorSub?.cancel();
    _player.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (_failed) {
      return MediaErrorBox(
        url: widget.openHref ?? widget.source,
        icon: Icons.videocam_off_outlined,
        label: 'Video failed to load',
      );
    }
    return MediaFrame(
      child: AspectRatio(
        aspectRatio: 16 / 9,
        child: Video(controller: _controller, fit: BoxFit.contain),
      ),
    );
  }
}
