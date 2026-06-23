/// The URL + user code surfaced by `grid auth login --no-browser` (cli.py:361).
class DeviceLogin {
  const DeviceLogin({required this.url, required this.userCode});
  final String url;
  final String userCode;
}

/// Incrementally extracts the device-login URL and code from the CLI's stdout.
///
/// The CLI prints a label line, then the URL, then `Code: <code>`. We key off
/// shape (first `http…` line, any `Code:` line) rather than the exact label
/// wording, so a reworded prompt won't break login. See
/// CLI_Integration_Contract §7.
class DeviceLoginParser {
  String? _url;
  String? _code;

  void feed(String line) {
    final trimmed = line.trim();
    if (_url == null && trimmed.startsWith('http')) {
      _url = trimmed;
      return;
    }
    if (trimmed.startsWith('Code:')) {
      _code = trimmed.substring('Code:'.length).trim();
    }
  }

  DeviceLogin? get result => (_url != null && _code != null)
      ? DeviceLogin(url: _url!, userCode: _code!)
      : null;
}
