import 'dart:ffi' show Abi;

/// True when [abi] identifies a Mac — Apple Silicon or Intel. Pure and
/// injectable, so the host-gating policy can be unit-tested without depending on
/// the machine the tests happen to run on.
bool isMacAbi(Abi abi) => abi == Abi.macosArm64 || abi == Abi.macosX64;

/// Whether Grid can set this machine up as a host by itself.
///
/// llama.cpp publishes official macOS builds for both Apple Silicon and Intel,
/// and `grid engine install llama.cpp` downloads whichever one this Mac needs —
/// no Homebrew, no compiler, no admin rights. So the hands-off setup runs on any
/// Mac. (It was Apple-Silicon-only while the install went through Homebrew, and
/// an Intel Mac fell into the NVIDIA branch and failed.) Linux and Windows have
/// no pinned build yet, so they run as consumers and never auto-provision an
/// engine.
bool get supportsBuiltInEngine => isMacAbi(Abi.current());
