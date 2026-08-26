import 'dart:convert';
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/grid_paths.dart';

/// What the user chose on first-run onboarding, back when their grid had no
/// model to chat with yet — and back when onboarding asked at all.
///
/// The screen that wrote this is gone (2026-08-26), so nothing produces a value
/// any more; what's on disk from before still decides whether the background
/// download may run. See `localModelChosenProvider`, which carries the TODO(BE)
/// for resolving that. Kept a full enum rather than a bool because the file on
/// disk holds all three names and must still read back as what it says.
enum OnboardingDecision {
  /// Run a model on this computer — install the engine, then the model
  /// downloads in the background and shares itself on the grid.
  local,

  /// Serve a hosted provider's model (e.g. OpenAI) with the user's own API key.
  openai,

  /// Skip for now and go into the app; set a model up later.
  later,
}

/// Persists the [OnboardingDecision] as `~/.grid/app/onboarding.json`. App-owned
/// (the CLI never touches it) and lenient like the other app stores: a missing,
/// corrupt, or unrecognised file reads as "not decided yet" (null) rather than
/// throwing. The file is overridable so tests never read or write a real grid
/// home.
class OnboardingStore {
  OnboardingStore({File? file}) : _file = file ?? GridPaths.onboardingFile;

  final File _file;

  /// The saved decision, or null when the user hasn't chosen yet (or the file is
  /// unreadable / hand-edited to a value we don't recognise).
  OnboardingDecision? load() {
    try {
      if (!_file.existsSync()) return null;
      final decoded = jsonDecode(_file.readAsStringSync());
      if (decoded is! Map) return null;
      final raw = decoded['decision'];
      for (final decision in OnboardingDecision.values) {
        if (decision.name == raw) return decision;
      }
      return null;
    } on Object {
      return null;
    }
  }

  /// Write [decision] to disk, creating the `app/` directory on first use.
  void save(OnboardingDecision decision) {
    _file.parent.createSync(recursive: true);
    _file.writeAsStringSync(
      const JsonEncoder.withIndent('  ').convert({'decision': decision.name}),
      flush: true,
    );
  }
}

/// The store, overridden in tests with a temp-file-backed instance.
final onboardingStoreProvider = Provider<OnboardingStore>(
  (ref) => OnboardingStore(),
);

/// The user's first-run onboarding decision, or null until they make one.
/// Loaded once on start; [OnboardingController.decide] persists and updates it,
/// so the choice survives a restart and the choice screen isn't shown again.
final onboardingDecisionProvider =
    NotifierProvider<OnboardingController, OnboardingDecision?>(
      OnboardingController.new,
    );

class OnboardingController extends Notifier<OnboardingDecision?> {
  @override
  OnboardingDecision? build() => ref.read(onboardingStoreProvider).load();

  /// Record the path the user chose and persist it. Choosing the same thing
  /// twice is a no-op write.
  void decide(OnboardingDecision decision) {
    if (state == decision) return;
    state = decision;
    ref.read(onboardingStoreProvider).save(decision);
  }
}
