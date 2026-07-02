import 'dart:ffi' show Abi;

/// True when [abi] identifies an Apple Silicon (arm64) Mac. Pure and injectable,
/// so the host-gating policy can be unit-tested without depending on the machine
/// the tests happen to run on.
bool isAppleSiliconAbi(Abi abi) => abi == Abi.macosArm64;

/// Whether this machine is an Apple Silicon Mac.
///
/// The built-in engine (llama.cpp with Metal) is only supported on Apple
/// Silicon, so the hands-off node auto-setup is gated on this — Intel Macs,
/// Linux and Windows run as consumers and never auto-provision an engine. The
/// app ships as a universal2 binary, so on Apple Silicon hardware it runs the
/// arm64 slice and [Abi.current] reports [Abi.macosArm64].
bool get isAppleSiliconMac => isAppleSiliconAbi(Abi.current());
