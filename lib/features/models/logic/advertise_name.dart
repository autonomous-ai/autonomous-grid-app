/// Derives the `--advertise-as` name from a local GGUF filename by stripping the
/// `.gguf` extension and the trailing quantization tag, e.g.
/// `Qwen3.6-35B-A3B-UD-IQ3_S.gguf` → `Qwen3.6-35B-A3B`. Falls back to the bare
/// filename (sans extension) when there's nothing recognizable to strip.
String deriveAdvertiseName(String modelFile) {
  final base = modelFile.split('/').last.replaceFirst(
        RegExp(r'\.gguf$', caseSensitive: false),
        '',
      );
  final stripped = base.replaceFirst(_quantSuffix, '');
  return stripped.isEmpty ? base : stripped;
}

/// Trailing quantization tag: an optional `UD`/imatrix marker plus a quant code
/// like `IQ3_S`, `Q4_K_M`, `Q8_0`, `F16`. Anchored to the end of the name.
final _quantSuffix = RegExp(
  r'([._-](UD|i1|imat|imatrix))*[._-]((I?Q\d+(_\w+)*)|F16|F32|BF16|FP16|FP32)$',
  caseSensitive: false,
);
