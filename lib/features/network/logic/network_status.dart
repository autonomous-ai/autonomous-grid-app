import '../../../infrastructure/state/models/network_credential.dart';

/// Connection status of a joined network, derived purely from token expiry.
enum NetworkConn { connected, expiringSoon, expired }

/// Maps a credential's `expires_at` to a coarse status the UI can color.
NetworkConn networkConn(NetworkCredential n, DateTime now) {
  final secondsLeft = n.expiresAt - now.millisecondsSinceEpoch ~/ 1000;
  if (secondsLeft <= 0) return NetworkConn.expired;
  if (secondsLeft < 24 * 3600) return NetworkConn.expiringSoon;
  return NetworkConn.connected;
}

/// Tailscale-style relative expiry, e.g. "in 5 months", "in 12 days", "expired".
String expiryLabel(int expiresAtSeconds, DateTime now) {
  final diff =
      DateTime.fromMillisecondsSinceEpoch(expiresAtSeconds * 1000).difference(now);
  if (diff.isNegative) return 'expired';
  final days = diff.inDays;
  if (days >= 60) return 'in ${(days / 30).round()} months';
  if (days >= 1) return 'in $days days';
  final hours = diff.inHours;
  if (hours >= 1) return 'in $hours hours';
  return 'in ${diff.inMinutes} minutes';
}

/// "permissioned-providers" → "Providers". Friendlier than the raw token.
String prettyNetworkType(String type) {
  final tail = type.contains('-') ? type.split('-').last : type;
  if (tail.isEmpty) return type;
  return tail[0].toUpperCase() + tail.substring(1);
}
