/// The encrypted channel between Grid on a computer and Grid on a phone.
///
/// Read `src/e2ee_frame.dart` first: the frame layout is where the design is,
/// and everything else exists to produce the four values it needs.
library;

export 'src/channel_messages.dart';
export 'src/e2ee_bytes.dart';
export 'src/e2ee_frame.dart';
export 'src/e2ee_handshake.dart';
export 'src/e2ee_key_schedule.dart';
export 'src/e2ee_keys.dart';
export 'src/e2ee_session.dart';
export 'src/e2ee_suite.dart';
export 'src/e2ee_transcript.dart';
export 'src/e2ee_wire.dart';
export 'src/mobile_rpc.dart';
export 'src/pairing_offer.dart';
export 'src/relay_host_proof.dart';
