/// Grid on a phone.
///
/// A remote control, deliberately: it runs no engines, drives no CLI and holds
/// no grid credentials. Everything it shows, it asked the computer for over an
/// end-to-end encrypted channel that the relay in the middle cannot read.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'presentation/link_screen.dart';

void main() => runApp(const ProviderScope(child: GridMobileApp()));

/// The app.
class GridMobileApp extends StatelessWidget {
  const GridMobileApp({super.key});

  @override
  Widget build(BuildContext context) => MaterialApp(
    title: 'Grid',
    debugShowCheckedModeBanner: false,
    theme: ThemeData(
      useMaterial3: true,
      colorScheme: ColorScheme.fromSeed(
        seedColor: const Color(0xFF4C6FFF),
        brightness: Brightness.dark,
      ),
    ),
    home: const LinkScreen(),
  );
}
