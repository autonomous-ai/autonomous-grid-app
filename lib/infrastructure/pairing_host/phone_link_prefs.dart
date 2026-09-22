/// Whether this computer shares with a phone, remembered across launches.
///
/// It once was not, and that is what "Can't reach your computer" meant on a
/// phone standing next to an open Grid: sharing went back to off every time the
/// app started, and only a click in Settings turned it on again. From the phone
/// there was nothing to distinguish that from a computer that was asleep.
///
/// **Restoring a choice, not making one.** Nothing here ever turns sharing on by
/// itself: the file does not exist until somebody switches it on, so a computer
/// that has never shared with a phone opens no port and publishes no address,
/// however many times it is launched.
///
/// One boolean is all it holds. The address used to be here too, back when a
/// person typed one; now it is a tunnel's, it is different every time, and the
/// only place it belongs is the locator.
library;

import 'dart:convert';
import 'dart:io';

import '../../core/grid_paths.dart';
import '../../core/owner_only_file.dart';

/// The shape written today. Version 1 held `{on, cellUrl}` and is still read:
/// the address in it is ignored, but somebody who had sharing switched on
/// should not have it silently switched off by updating Grid.
const _fileVersion = 2;

/// Reads and writes the one remembered choice.
class PhoneLinkPrefs {
  const PhoneLinkPrefs({File? file}) : _file = file;

  final File? _file;

  File get _target => _file ?? GridPaths.phoneLinkFile;

  /// Whether sharing was on when this computer last ran.
  ///
  /// An unreadable or unrecognised file reads as off rather than throwing: the
  /// worst case has to be "does not come back by itself", never "the app will
  /// not start".
  Future<bool> isOn() async {
    final file = _target;
    if (!file.existsSync()) return false;
    final Object? value;
    try {
      value = jsonDecode(await file.readAsString());
    } on Object {
      return false;
    }
    if (value is! Map<String, Object?>) return false;
    final version = value['v'];
    if (version != _fileVersion && version != 1) return false;
    return value['on'] == true;
  }

  /// Remembers that sharing is on, or that somebody turned it off — which has
  /// to survive a restart just as firmly.
  Future<void> write({required bool on}) async {
    final file = _target;
    await file.parent.create(recursive: true);
    await file.writeAsString(
      const JsonEncoder.withIndent('  ').convert({'v': _fileVersion, 'on': on}),
    );
    // Not a secret — it is one boolean — but it decides whether this machine
    // answers a phone, so it is not something another account on this computer
    // should be able to flip.
    await restrictToOwner(file);
  }
}
