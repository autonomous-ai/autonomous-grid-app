/// Minimal slug → LobeHub icon id map.
/// Only includes slugs that actually exist in LobeHub CDN.
const _slugIconMap = <String, String>{
  'openai': 'OpenAI',
  'anthropic': 'Anthropic',
  'google': 'Google',
  'gemini': 'Google',
  'deepseek': 'DeepSeek',
  'meta': 'Meta',
  'llama': 'Meta',
  'mistral': 'Mistral',
  'perplexity': 'Perplexity',
  'cohere': 'Cohere',
  'zhipu': 'Zhipu',
  'bytedance': 'ByteDance',
  'qwen': 'Qwen',
};

/// Default icon when slug is unknown or not in LobeHub.
const _defaultSlug = 'huggingface';

/// Generates a CDN URL for a LobeHub icon.
String _cdnUrl({required String iconId, bool isDarkMode = false}) {
  final slug = iconId.toLowerCase();
  final darkPath = isDarkMode ? 'dark' : 'light';
  return 'https://raw.githubusercontent.com/lobehub/lobe-icons/refs/heads/master/packages/static-png/$darkPath/$slug-color.png';
}

/// Extract icon slug from repo_id.
///
/// Takes the part after `/`, splits by `-`/`_`, returns the first segment
/// with trailing digits stripped, lowercased. E.g.:
///   "Qwen/Qwen2.5-3B-Instruct-GGUF" → "qwen"
///   "unsloth/Ornith-1.0-35B-GGUF"    → "ornith"
///   "meta-llama/Llama-3.1-8B-GGUF"  → "llama"
String _iconSlugFromRepoId(String repoId) {
  if (repoId.isEmpty) return '';
  final slashIdx = repoId.indexOf('/');
  final tail = slashIdx >= 0 ? repoId.substring(slashIdx + 1) : repoId;
  final firstSegment = tail
      .split(RegExp(r'[-_]'))
      .firstWhere((w) => w.isNotEmpty, orElse: () => '');
  final m = RegExp(r'^([a-zA-Z]+)').firstMatch(firstSegment);
  return m?.group(1)?.toLowerCase() ?? '';
}

/// Get the CDN URL for a model's provider icon based on repo_id.
/// Falls back to HuggingFace icon when slug is unknown.
String? urlForModel(String repoId, {bool isDarkMode = false}) {
  if (repoId.isEmpty) return null;
  final slug = _iconSlugFromRepoId(repoId);
  final iconId = _slugIconMap[slug] ?? _defaultSlug;
  return _cdnUrl(iconId: iconId, isDarkMode: isDarkMode);
}
