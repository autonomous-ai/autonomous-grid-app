/// `grid://pair?code=...` arriving from outside the app.
///
/// Two ways in, and both matter: the link can launch the app cold (the code
/// is then the route the engine started with) or arrive while it is already
/// open (the engine pushes it). Handle only one and pairing works exactly half
/// the time, in a way nobody reports because they retry and it works.
library;

import 'dart:ui';

import 'package:flutter/services.dart';

const _scheme = 'grid://';

/// Delivers pairing links.
abstract final class PairingLinks {
  /// The link this app was launched with, if it was.
  static String? initial() {
    final route = PlatformDispatcher.instance.defaultRouteName;
    return route.startsWith(_scheme) ? route : null;
  }

  /// Calls [onLink] for every pairing link that arrives while running.
  ///
  /// This replaces the framework's own handler for the navigation channel.
  /// That is safe *here* and would not be in a bigger app: Grid on a phone is
  /// one screen with no named routes, so nothing else is listening. Add a
  /// second screen and this has to become a real Router.
  static void listen(void Function(String link) onLink) {
    SystemChannels.navigation.setMethodCallHandler((call) async {
      final link = _linkIn(call);
      if (link != null && link.startsWith(_scheme)) onLink(link);
      return null;
    });
  }

  static String? _linkIn(MethodCall call) {
    final arguments = call.arguments;
    return switch (call.method) {
      'pushRoute' => arguments is String ? arguments : null,
      'pushRouteInformation' when arguments is Map =>
        arguments['location'] as String?,
      _ => null,
    };
  }
}
