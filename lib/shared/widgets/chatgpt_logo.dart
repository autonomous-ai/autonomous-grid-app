import 'package:flutter/material.dart';

/// The OpenAI mark, drawn as vector paths so the ChatGPT sign-in button carries
/// the real logo at any size without an asset — the same approach as
/// [GoogleLogo], and for the same reason: an OAuth button people recognise.
///
/// One colour, [color] (the button's own label colour by default), because the
/// mark is monochrome by design and has to stay legible on both the white
/// light-mode pill and the charcoal dark-mode one.
///
/// Paths are the canonical 24×24 geometry, scaled to [size].
class ChatGptLogo extends StatelessWidget {
  const ChatGptLogo({super.key, this.size = 18, this.color});

  final double size;
  final Color? color;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: size,
      height: size,
      child: CustomPaint(
        painter: _OpenAiMarkPainter(
          color ?? DefaultTextStyle.of(context).style.color ?? Colors.black,
        ),
      ),
    );
  }
}

class _OpenAiMarkPainter extends CustomPainter {
  const _OpenAiMarkPainter(this.color);

  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    // Authored in the canonical 24-unit logo space; scale the canvas so callers
    // pick any dimension.
    canvas.scale(size.width / 24.0);
    canvas.drawPath(
      openAiMarkPath(),
      Paint()
        ..style = PaintingStyle.fill
        ..color = color,
    );
  }

  @override
  bool shouldRepaint(covariant _OpenAiMarkPainter oldDelegate) =>
      oldDelegate.color != color;
}

/// The mark's geometry in its canonical 24×24 box, as a [Path].
///
/// Converted from the published SVG. One trap worth recording: SVG's arc
/// sweep-flag maps to the **opposite** of Flutter's `clockwise`, so a
/// straight-across conversion draws every curve bulging the wrong way — the
/// paths below already have it inverted.
///
/// Named (rather than inlined in the painter) so its shape can be checked
/// without rendering a widget: a mis-converted arc shows up as a path whose
/// bounds have escaped the logo box.
Path openAiMarkPath() {
  return Path()
    ..moveTo(22.2819, 9.8211)
    ..arcToPoint(
      const Offset(21.7662, 4.9103),
      radius: const Radius.elliptical(5.9847, 5.9847),
      rotation: 0.0000,
      largeArc: false,
      clockwise: true,
    )
    ..arcToPoint(
      const Offset(15.2564, 2.0103),
      radius: const Radius.elliptical(6.0462, 6.0462),
      rotation: 0.0000,
      largeArc: false,
      clockwise: true,
    )
    ..arcToPoint(
      const Offset(4.9807, 4.1818),
      radius: const Radius.elliptical(6.0651, 6.0651),
      rotation: 0.0000,
      largeArc: false,
      clockwise: true,
    )
    ..arcToPoint(
      const Offset(0.9830, 7.0818),
      radius: const Radius.elliptical(5.9847, 5.9847),
      rotation: 0.0000,
      largeArc: false,
      clockwise: true,
    )
    ..arcToPoint(
      const Offset(1.7257, 14.1784),
      radius: const Radius.elliptical(6.0462, 6.0462),
      rotation: 0.0000,
      largeArc: false,
      clockwise: true,
    )
    ..arcToPoint(
      const Offset(2.2367, 19.0891),
      radius: const Radius.elliptical(5.9800, 5.9800),
      rotation: 0.0000,
      largeArc: false,
      clockwise: true,
    )
    ..arcToPoint(
      const Offset(8.7513, 21.9892),
      radius: const Radius.elliptical(6.0510, 6.0510),
      rotation: 0.0000,
      largeArc: false,
      clockwise: true,
    )
    ..arcToPoint(
      const Offset(13.2599, 24.0000),
      radius: const Radius.elliptical(5.9847, 5.9847),
      rotation: 0.0000,
      largeArc: false,
      clockwise: true,
    )
    ..arcToPoint(
      const Offset(19.0317, 19.7942),
      radius: const Radius.elliptical(6.0557, 6.0557),
      rotation: 0.0000,
      largeArc: false,
      clockwise: true,
    )
    ..arcToPoint(
      const Offset(23.0294, 16.8941),
      radius: const Radius.elliptical(5.9894, 5.9894),
      rotation: 0.0000,
      largeArc: false,
      clockwise: true,
    )
    ..arcToPoint(
      const Offset(22.2819, 9.8212),
      radius: const Radius.elliptical(6.0557, 6.0557),
      rotation: 0.0000,
      largeArc: false,
      clockwise: true,
    )
    ..close()
    ..moveTo(13.2599, 22.4292)
    ..arcToPoint(
      const Offset(10.3835, 21.3884),
      radius: const Radius.elliptical(4.4755, 4.4755),
      rotation: 0.0000,
      largeArc: false,
      clockwise: false,
    )
    ..lineTo(10.5254, 21.3080)
    ..lineTo(15.3037, 18.5498)
    ..arcToPoint(
      const Offset(15.6964, 17.8685),
      radius: const Radius.elliptical(0.7948, 0.7948),
      rotation: 0.0000,
      largeArc: false,
      clockwise: true,
    )
    ..lineTo(15.6964, 11.1316)
    ..lineTo(17.7164, 12.3002)
    ..arcToPoint(
      const Offset(17.7544, 12.3522),
      radius: const Radius.elliptical(0.0710, 0.0710),
      rotation: 0.0000,
      largeArc: false,
      clockwise: false,
    )
    ..lineTo(17.7544, 17.9348)
    ..arcToPoint(
      const Offset(13.2599, 22.4292),
      radius: const Radius.elliptical(4.5040, 4.5040),
      rotation: 0.0000,
      largeArc: false,
      clockwise: false,
    )
    ..close()
    ..moveTo(3.5992, 18.3038)
    ..arcToPoint(
      const Offset(3.0646, 15.2901),
      radius: const Radius.elliptical(4.4708, 4.4708),
      rotation: 0.0000,
      largeArc: false,
      clockwise: false,
    )
    ..lineTo(3.2066, 15.3753)
    ..lineTo(7.9896, 18.1335)
    ..arcToPoint(
      const Offset(8.7702, 18.1335),
      radius: const Radius.elliptical(0.7712, 0.7712),
      rotation: 0.0000,
      largeArc: false,
      clockwise: true,
    )
    ..lineTo(14.6130, 14.7650)
    ..lineTo(14.6130, 17.0974)
    ..arcToPoint(
      const Offset(14.5798, 17.1589),
      radius: const Radius.elliptical(0.0804, 0.0804),
      rotation: 0.0000,
      largeArc: false,
      clockwise: false,
    )
    ..lineTo(9.7400, 19.9502)
    ..arcToPoint(
      const Offset(3.5992, 18.3038),
      radius: const Radius.elliptical(4.4992, 4.4992),
      rotation: 0.0000,
      largeArc: false,
      clockwise: false,
    )
    ..close()
    ..moveTo(2.3408, 7.8956)
    ..arcToPoint(
      const Offset(4.7063, 5.9228),
      radius: const Radius.elliptical(4.4850, 4.4850),
      rotation: 0.0000,
      largeArc: false,
      clockwise: false,
    )
    ..lineTo(4.7063, 11.6000)
    ..arcToPoint(
      const Offset(5.0942, 12.2765),
      radius: const Radius.elliptical(0.7664, 0.7664),
      rotation: 0.0000,
      largeArc: false,
      clockwise: true,
    )
    ..lineTo(10.9086, 15.6308)
    ..lineTo(8.8885, 16.7993)
    ..arcToPoint(
      const Offset(8.8175, 16.7993),
      radius: const Radius.elliptical(0.0757, 0.0757),
      rotation: 0.0000,
      largeArc: false,
      clockwise: false,
    )
    ..lineTo(3.9872, 14.0128)
    ..arcToPoint(
      const Offset(2.3408, 7.8720),
      radius: const Radius.elliptical(4.5040, 4.5040),
      rotation: 0.0000,
      largeArc: false,
      clockwise: false,
    )
    ..close()
    ..moveTo(18.9371, 11.7514)
    ..lineTo(13.1038, 8.3640)
    ..lineTo(15.1192, 7.2000)
    ..arcToPoint(
      const Offset(15.1902, 7.2000),
      radius: const Radius.elliptical(0.0757, 0.0757),
      rotation: 0.0000,
      largeArc: false,
      clockwise: false,
    )
    ..lineTo(20.0205, 9.9913)
    ..arcToPoint(
      const Offset(19.3440, 18.0955),
      radius: const Radius.elliptical(4.4944, 4.4944),
      rotation: 0.0000,
      largeArc: false,
      clockwise: false,
    )
    ..lineTo(19.3440, 12.4183)
    ..arcToPoint(
      const Offset(18.9370, 11.7513),
      radius: const Radius.elliptical(0.7900, 0.7900),
      rotation: 0.0000,
      largeArc: false,
      clockwise: true,
    )
    ..close()
    ..moveTo(20.9478, 8.7283)
    ..lineTo(20.8058, 8.6431)
    ..lineTo(16.0323, 5.8613)
    ..arcToPoint(
      const Offset(15.2469, 5.8613),
      radius: const Radius.elliptical(0.7759, 0.7759),
      rotation: 0.0000,
      largeArc: false,
      clockwise: true,
    )
    ..lineTo(9.4090, 9.2297)
    ..lineTo(9.4090, 6.8974)
    ..arcToPoint(
      const Offset(9.4374, 6.8359),
      radius: const Radius.elliptical(0.0662, 0.0662),
      rotation: 0.0000,
      largeArc: false,
      clockwise: false,
    )
    ..lineTo(14.2677, 4.0493)
    ..arcToPoint(
      const Offset(20.9479, 8.7093),
      radius: const Radius.elliptical(4.4992, 4.4992),
      rotation: 0.0000,
      largeArc: false,
      clockwise: false,
    )
    ..close()
    ..moveTo(8.3065, 12.8630)
    ..lineTo(6.2865, 11.6992)
    ..arcToPoint(
      const Offset(6.2485, 11.6425),
      radius: const Radius.elliptical(0.0804, 0.0804),
      rotation: 0.0000,
      largeArc: false,
      clockwise: false,
    )
    ..lineTo(6.2485, 6.0742)
    ..arcToPoint(
      const Offset(13.6242, 2.6205),
      radius: const Radius.elliptical(4.4992, 4.4992),
      rotation: 0.0000,
      largeArc: false,
      clockwise: false,
    )
    ..lineTo(13.4822, 2.7010)
    ..lineTo(8.7040, 5.4590)
    ..arcToPoint(
      const Offset(8.3113, 6.1403),
      radius: const Radius.elliptical(0.7948, 0.7948),
      rotation: 0.0000,
      largeArc: false,
      clockwise: true,
    )
    ..close()
    ..moveTo(9.4041, 10.4976)
    ..lineTo(12.0061, 8.9978)
    ..lineTo(14.6130, 10.4976)
    ..lineTo(14.6130, 13.4970)
    ..lineTo(12.0156, 14.9967)
    ..lineTo(9.4089, 13.4970)
    ..close();
}
