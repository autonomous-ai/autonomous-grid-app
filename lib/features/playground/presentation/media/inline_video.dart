import 'dart:async';

import 'package:flutter/material.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';

import 'media_chrome.dart';

/// A network video referenced from a chat message, played inline with
/// media_kit's adaptive controls. The clip is loaded paused — the user presses
/// play. The player is torn down with the widget.
class InlineVideo extends StatefulWidget {
  const InlineVideo({super.key, required this.url});
  final String url;

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
    unawaited(_player.open(Media(widget.url), play: false));
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
        url: widget.url,
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
