import 'dart:convert';
import 'dart:io';

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter_svg/flutter_svg.dart';

import '../../../../shared/theme/app_theme.dart';
import '../../../../shared/widgets/extension_tile_surface.dart';

/// The service's own logo, or the glyph badge when there isn't one.
///
/// Same 30px well as [ExtensionIconBadge] so the icon column stays a column
/// whichever kind of row is in it. The image is a fact about the service, not
/// live state, so it never takes the accent tint.
///
/// Every failure path lands on the glyph: no URL, a URL that won't load, a
/// user offline. A blank square in the icon column reads as a broken row.
class ConnectorMark extends StatelessWidget {
  const ConnectorMark({
    super.key,
    required this.imageUrl,
    required this.fallbackIcon,
    this.size = 30,
  });

  final String imageUrl;
  final IconData fallbackIcon;

  /// The plate's edge, both dimensions. 30 is the list's icon column; the detail
  /// dialog draws the same mark larger, where it is the subject rather than a
  /// column to scan.
  final double size;

  @override
  Widget build(BuildContext context) {
    AppTheme.watch(context); // follow theme flips — reads AppPalette tokens.
    if (imageUrl.isEmpty) {
      return ExtensionIconBadge(icon: fallbackIcon, size: size);
    }
    return Container(
      width: size,
      height: size,
      clipBehavior: Clip.antiAlias,
      decoration: BoxDecoration(
        // A white plate under every logo: these are the services' own marks,
        // each with its own backdrop, and half of them are dark-on-transparent
        // — on the dark card fill they would disappear.
        color: Colors.white,
        borderRadius: BorderRadius.circular(10),
      ),
      child: Padding(padding: const EdgeInsets.all(4), child: _image()),
    );
  }

  /// The logo, decoded by whatever can read this format.
  ///
  /// Flutter's image codecs handle bitmaps and nothing else — an SVG loads
  /// fine over the network and then fails to decode, which sent Figma's mark to
  /// the fallback glyph while the request itself was a clean 200. The backend
  /// picks the format per connector and can change it without telling us, so
  /// the choice is made from the URL rather than from a list of connectors.
  Widget _image() {
    final glyph = Icon(fallbackIcon, size: 16, color: AppPalette.textSecondary);

    if (_isSvg(imageUrl)) return _SvgMark(url: imageUrl, fallback: glyph);

    return CachedNetworkImage(
      imageUrl: imageUrl,
      fit: BoxFit.contain,
      // Favicons come in whatever size the host publishes — measured
      // 2026-07-30: 128px from notion.com, 48 from linear.app, 32 from
      // github.com, and 16 from supabase.com no matter what is asked for.
      // `medium` is bilinear: it keeps a 128px mark crisp when it comes *down*
      // to 22, and blurs a 16px one less badly than `high` when it goes up.
      // Neither can make a 16px source sharp — nothing can — but this stops it
      // looking smeared as well as small.
      filterQuality: FilterQuality.medium,
      // No spinner while it loads: the plate is already the right shape,
      // and a spinner per row turns a quiet list into a flicker.
      placeholder: (_, _) => const SizedBox.shrink(),
      errorWidget: (_, _, _) => glyph,
    );
  }

  /// Reads the extension off the path, ignoring any `?v=2` the CDN appends —
  /// matching on the whole URL would miss every versioned one.
  static bool _isSvg(String url) {
    final path = Uri.tryParse(url)?.path ?? url;
    return path.toLowerCase().endsWith('.svg');
  }
}

/// An SVG logo, fetched and repaired before it is drawn.
///
/// `SvgPicture.network` would be the obvious choice and it renders these marks
/// as a solid black block. The reason is CSS: the CDN's logos put every colour
/// in a `<style>` sheet and reference it by class —
///
/// ```svg
/// <style>.st0{fill:#0acf83}</style>
/// <path class="st0" d="…"/>
/// ```
///
/// — and the SVG parser behind `flutter_svg` implements presentation attributes
/// rather than a CSS cascade. Unmatched classes leave every path at the default
/// fill, black, so the five pieces of the Figma mark stack into one silhouette.
/// Nothing errors; it just draws the wrong thing, which is why this needed a
/// look at the file rather than at the exception.
///
/// So the sheet is inlined here — each `class="stN"` rewritten to the `fill` it
/// stood for — and the result handed to `SvgPicture.string`. Anything the
/// rewrite can't make sense of is passed through untouched: a logo that already
/// uses plain `fill` attributes is the common case and must not be disturbed.
class _SvgMark extends StatefulWidget {
  const _SvgMark({required this.url, required this.fallback});

  final String url;
  final Widget fallback;

  @override
  State<_SvgMark> createState() => _SvgMarkState();
}

class _SvgMarkState extends State<_SvgMark> {
  /// Shared across every row and every rebuild: the same handful of logos are
  /// re-requested each time the screen opens, and `SvgPicture.string` has no
  /// cache of its own the way `CachedNetworkImage` does.
  static final Map<String, String?> _cache = {};

  String? _svg;
  bool _failed = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void didUpdateWidget(_SvgMark old) {
    super.didUpdateWidget(old);
    if (old.url != widget.url) _load();
  }

  Future<void> _load() async {
    if (_cache.containsKey(widget.url)) {
      final cached = _cache[widget.url];
      setState(() {
        _svg = cached;
        _failed = cached == null;
      });
      return;
    }

    String? body;
    try {
      final client = HttpClient()
        ..connectionTimeout = const Duration(seconds: 10);
      try {
        final request = await client.getUrl(Uri.parse(widget.url));
        final response = await request.close().timeout(
          const Duration(seconds: 15),
        );
        if (response.statusCode == 200) {
          body = inlineSvgStyles(await utf8.decoder.bind(response).join());
        }
      } finally {
        client.close(force: true);
      }
    } on Object {
      // Offline, timed out, malformed — all the same answer to this widget:
      // draw the glyph. A logo is never worth an error message.
      body = null;
    }

    _cache[widget.url] = body;
    if (!mounted) return;
    setState(() {
      _svg = body;
      _failed = body == null;
    });
  }

  @override
  Widget build(BuildContext context) {
    if (_failed) return widget.fallback;
    final svg = _svg;
    // Nothing yet: the white plate is already the right shape, so an empty box
    // is quieter than a spinner in every row of a list.
    if (svg == null) return const SizedBox.shrink();
    return SvgPicture.string(
      svg,
      fit: BoxFit.contain,
      errorBuilder: (_, _, _) => widget.fallback,
    );
  }
}

/// Rewrite `<style>` class rules into the `fill` attributes the SVG parser
/// actually reads.
///
/// Handles the shape the CDN ships — single-class selectors carrying one
/// `fill` — and deliberately nothing more. A real cascade (specificity,
/// inheritance, media queries) is a rabbit hole for a 30px logo; anything this
/// doesn't recognise is left exactly as it was, so a file that never needed the
/// help is returned byte-for-byte.
///
/// Visible for the sake of being testable and readable in isolation.
String inlineSvgStyles(String svg) {
  final styles = RegExp(
    r'<style[^>]*>(.*?)</style>',
    dotAll: true,
    caseSensitive: false,
  ).allMatches(svg);
  if (styles.isEmpty) return svg;

  final fills = <String, String>{};
  for (final style in styles) {
    final rules = RegExp(
      r'\.([\w-]+)\s*\{([^}]*)\}',
    ).allMatches(style.group(1) ?? '');
    for (final rule in rules) {
      final fill = RegExp(
        r'fill\s*:\s*([^;}]+)',
      ).firstMatch(rule.group(2) ?? '');
      if (fill != null) fills[rule.group(1)!] = fill.group(1)!.trim();
    }
  }
  if (fills.isEmpty) return svg;

  return svg.replaceAllMapped(RegExp('class="([^"]*)"'), (match) {
    final names = match.group(1)!.split(RegExp(r'\s+'));
    // Last class wins, the way a stylesheet of equal-specificity rules would
    // resolve it. An element whose classes carry no fill keeps its own
    // attribute rather than gaining a wrong one.
    String? fill;
    for (final name in names) {
      if (fills.containsKey(name)) fill = fills[name];
    }
    return fill == null ? match.group(0)! : 'fill="$fill"';
  });
}
