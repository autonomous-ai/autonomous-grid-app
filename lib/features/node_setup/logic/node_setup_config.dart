/// Feature flags for the node auto-setup flow.
///
/// Media (ComfyUI) setup is OFF for now — the first node only auto-provisions
/// text inference (llama.cpp + a model). Flipping [kMediaSetupEnabled] back to
/// true re-enables everything media: the `grid media status` probe during
/// detection, the `grid media install` step, and the image-bundle download.
/// No other code changes are needed.
const bool kMediaSetupEnabled = false;
