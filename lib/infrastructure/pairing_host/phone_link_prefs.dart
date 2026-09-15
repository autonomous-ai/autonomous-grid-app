/// Whether this computer is sharing with a phone, remembered across launches.
///
/// It was not, and that is what "Can't reach your computer" meant on a phone
/// standing next to an open Grid: the relay had no session for this machine,
/// because the link went back to off every time the app started and only a
/// click on Settings ▸ Phone turned it on again. From the phone there was
/// nothing to distinguish that from a computer that was actually asleep.
///
/// **Restoring a choice, not making one.** Nothing here ever turns the link on
/// by itself: the file does not exist until somebody connects, and a computer
/// that has never shared with a phone still announces nothing on launch.
library;

import 'dart:convert';
import 'dart:io';

import '../../core/grid_paths.dart';
import '../../core/owner_only_file.dart';

const _fileVersion = 1;

/// What was on, and where.
typedef PhoneLinkChoice = ({bool on, String cellUrl});

/// Reads and writes the one remembered choice.
class PhoneLinkPrefs {
  const PhoneLinkPrefs({File? file}) : _file = file;

  final File? _file;

  File get _target => _file ?? GridPaths.phoneLinkFile;

  /// What this computer was doing when it last ran, or null when it has never
  /// shared with a phone.
  ///
  /// An unreadable or unrecognised file reads as null rather than throwing: the
  /// worst case has to be "does not come back on by itself", never "the app
  /// will not start".
  Future<PhoneLinkChoice?> read() async {
    final file = _target;
    if (!file.existsSync()) return null;
    final Object? value;
    try {
      value = jsonDecode(await file.readAsString());
    } on Object {
      return null;
    }
    if (value is! Map<String, Object?> || value['v'] != _fileVersion) {
      return null;
    }
    final cellUrl = value['cellUrl'];
    if (cellUrl is! String || cellUrl.isEmpty) return null;
    return (on: value['on'] == true, cellUrl: cellUrl);
  }

  /// Remembers that this computer is sharing, and with which relay.
  Future<void> writeOn(String cellUrl) => _write(on: true, cellUrl: cellUrl);

  /// Remembers that somebody turned it off — which must survive a restart just
  /// as firmly as turning it on.
  Future<void> writeOff(String cellUrl) => _write(on: false, cellUrl: cellUrl);

  Future<void> _write({required bool on, required String cellUrl}) async {
    final file = _target;
    await file.parent.create(recursive: true);
    await file.writeAsString(
      const JsonEncoder.withIndent(
        '  ',
      ).convert({'v': _fileVersion, 'on': on, 'cellUrl': cellUrl}),
    );
    // Not a secret — it holds a relay address and a boolean — but it decides
    // whether this machine answers a phone, so it is not something another
    // account on this computer should be able to flip.
    await restrictToOwner(file);
  }
}
