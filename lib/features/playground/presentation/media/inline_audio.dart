import 'dart:async';

import 'package:flutter/material.dart';
import 'package:media_kit/media_kit.dart';

import 'media_chrome.dart';

/// A network audio clip referenced from a chat message, played inline with a
/// compact play/pause + scrubber bar. media_kit has no audio chrome of its own,
/// so this builds a minimal one driven by the player streams.
class InlineAudio extends StatefulWidget {
  const InlineAudio({super.key, required this.url});
  final String url;

  @override
  State<InlineAudio> createState() => _InlineAudioState();
}

class _InlineAudioState extends State<InlineAudio> {
  late final Player _player = Player();
  final List<StreamSubscription<dynamic>> _subs = [];

  bool _playing = false;
  bool _failed = false;
  Duration _position = Duration.zero;
  Duration _duration = Duration.zero;

  @override
  void initState() {
    super.initState();
    _subs.addAll([
      _player.stream.playing.listen((v) => _set(() => _playing = v)),
      _player.stream.position.listen((v) => _set(() => _position = v)),
      _player.stream.duration.listen((v) => _set(() => _duration = v)),
      _player.stream.error.listen((_) => _set(() => _failed = true)),
    ]);
    unawaited(_player.open(Media(widget.url), play: false));
  }

  void _set(VoidCallback fn) {
    if (mounted) setState(fn);
  }

  @override
  void dispose() {
    for (final sub in _subs) {
      sub.cancel();
    }
    _player.dispose();
    super.dispose();
  }

  void _seek(double ms) => _player.seek(Duration(milliseconds: ms.round()));

  @override
  Widget build(BuildContext context) {
    if (_failed) {
      return MediaErrorBox(
        url: widget.url,
        icon: Icons.music_off_outlined,
        label: 'Audio failed to load',
      );
    }

    final theme = Theme.of(context);
    final maxMs = _duration.inMilliseconds.toDouble();
    final value = _position.inMilliseconds
        .toDouble()
        .clamp(0, maxMs)
        .toDouble();

    return MediaFrame(
      padding: const EdgeInsets.fromLTRB(4, 4, 14, 4),
      child: Row(
        children: [
          IconButton(
            iconSize: 34,
            color: theme.colorScheme.primary,
            icon: Icon(
              _playing
                  ? Icons.pause_circle_filled
                  : Icons.play_circle_fill_rounded,
            ),
            onPressed: _player.playOrPause,
          ),
          Expanded(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                SliderTheme(
                  data: SliderTheme.of(context).copyWith(
                    trackHeight: 3,
                    overlayShape: const RoundSliderOverlayShape(
                      overlayRadius: 12,
                    ),
                    thumbShape: const RoundSliderThumbShape(
                      enabledThumbRadius: 6,
                    ),
                  ),
                  child: Slider(
                    value: value,
                    max: maxMs <= 0 ? 1 : maxMs,
                    onChanged: maxMs <= 0 ? null : _seek,
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 8),
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Text(
                        formatMediaDuration(_position),
                        style: theme.textTheme.labelSmall,
                      ),
                      Text(
                        formatMediaDuration(_duration),
                        style: theme.textTheme.labelSmall,
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
