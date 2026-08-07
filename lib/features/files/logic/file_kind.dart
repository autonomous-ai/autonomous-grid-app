/// What a file *is*, as far as an icon is concerned.
///
/// Pure string work — no `dart:io`, no Flutter. The two halves of the answer are
/// deliberately separate: [FileGlyph] is what gets drawn and [FileAccent] is what
/// colour it carries, because a dozen languages share one glyph and a different
/// dozen share one hue. Keeping them apart is what stops this becoming an enum
/// with a value per file extension.
library;

/// The shape of the mark beside a name.
enum FileGlyph {
  /// Source in some language.
  code,

  /// Something meant to be run: a shell script, a batch file.
  script,

  /// Structured data — JSON, YAML, TOML. One glyph for all three: what tells
  /// them apart at a glance is the hue, not the shape.
  data,

  /// A spreadsheet, or the comma-separated stand-in for one.
  sheet,

  /// A page: HTML, and the templating languages that produce it.
  markup,

  /// A stylesheet.
  style,

  /// Prose — Markdown, a licence, a log.
  doc,

  image,
  video,
  audio,

  /// A compressed bundle.
  archive,

  /// A database file, or the SQL that talks to one.
  database,

  /// A dependency lock — generated, and not meant to be read.
  lock,

  /// Settings for a tool rather than code: dotfiles, `.ini`, `.env`.
  config,

  /// A manifest that says what the project is made of.
  package,

  /// Git's own bookkeeping.
  git,

  /// Compiled output, or anything else with no text in it.
  binary,

  /// No extension we recognise. Draws the plain page every file dialog uses.
  unknown,
}

/// The hue the glyph carries.
///
/// Named by colour rather than by language on purpose: the value each one takes
/// has to be tuned per theme (a yellow that reads on white is not the yellow
/// that reads on charcoal), and tuning nine hues is possible where tuning sixty
/// languages is not.
enum FileAccent { blue, cyan, green, amber, orange, red, purple, pink, neutral }

/// A file's glyph and its hue, together.
typedef FileMark = ({FileGlyph glyph, FileAccent accent});

/// How [path] should be marked. Takes a bare name or a whole path — only the
/// last segment decides.
///
/// Whole names win over extensions, so `package.json` is npm's manifest rather
/// than one more JSON file, and `Cargo.lock` is a lock rather than TOML.
FileMark fileMarkOf(String path) {
  final name = path.split(RegExp(r'[/\\]')).last.toLowerCase();
  if (name.isEmpty) return _unknown;

  final byName = _byName[name];
  if (byName != null) return byName;

  // `.env.local`, `.env.production` — the same file with a suffix saying when
  // it applies.
  if (name.startsWith('.env')) return _env;

  // `something.lock` beats whatever `something` looked like: a lock is a lock
  // whichever tool wrote it.
  if (name.endsWith('.lock')) return _lock;

  final dot = name.lastIndexOf('.');
  // A leading dot with nothing after it is a dotfile, not an extension:
  // `.eslintrc` and `.prettierrc` are settings for a tool.
  if (dot < 0) return _unknown;
  if (dot == 0) return _config;

  return _byExtension[name.substring(dot + 1)] ?? _unknown;
}

const FileMark _unknown = (
  glyph: FileGlyph.unknown,
  accent: FileAccent.neutral,
);
const FileMark _config = (glyph: FileGlyph.config, accent: FileAccent.neutral);
const FileMark _lock = (glyph: FileGlyph.lock, accent: FileAccent.neutral);
const FileMark _env = (glyph: FileGlyph.config, accent: FileAccent.amber);

/// Files known by their whole name. Lowercased keys — the lookup lowercases too,
/// so `Dockerfile` and `dockerfile` land in the same place.
const Map<String, FileMark> _byName = {
  'dockerfile': (glyph: FileGlyph.package, accent: FileAccent.blue),
  'docker-compose.yml': (glyph: FileGlyph.package, accent: FileAccent.blue),
  'docker-compose.yaml': (glyph: FileGlyph.package, accent: FileAccent.blue),
  'makefile': (glyph: FileGlyph.config, accent: FileAccent.orange),
  'cmakelists.txt': (glyph: FileGlyph.config, accent: FileAccent.orange),
  'package.json': (glyph: FileGlyph.package, accent: FileAccent.red),
  'pubspec.yaml': (glyph: FileGlyph.package, accent: FileAccent.cyan),
  'go.mod': (glyph: FileGlyph.package, accent: FileAccent.cyan),
  'go.sum': (glyph: FileGlyph.lock, accent: FileAccent.cyan),
  'cargo.toml': (glyph: FileGlyph.package, accent: FileAccent.orange),
  'pyproject.toml': (glyph: FileGlyph.package, accent: FileAccent.blue),
  'requirements.txt': (glyph: FileGlyph.package, accent: FileAccent.blue),
  'gemfile': (glyph: FileGlyph.package, accent: FileAccent.red),
  'readme': (glyph: FileGlyph.doc, accent: FileAccent.blue),
  'license': (glyph: FileGlyph.doc, accent: FileAccent.neutral),
  'licence': (glyph: FileGlyph.doc, accent: FileAccent.neutral),
  'notice': (glyph: FileGlyph.doc, accent: FileAccent.neutral),
  '.gitignore': (glyph: FileGlyph.git, accent: FileAccent.orange),
  '.gitattributes': (glyph: FileGlyph.git, accent: FileAccent.orange),
  '.gitmodules': (glyph: FileGlyph.git, accent: FileAccent.orange),
  '.gitkeep': (glyph: FileGlyph.git, accent: FileAccent.neutral),
  '.ds_store': (glyph: FileGlyph.binary, accent: FileAccent.neutral),
};

/// Files known by their extension, lowercased and without the dot.
const Map<String, FileMark> _byExtension = {
  // Languages, hued the way their own communities colour them — a Go file is
  // the cyan of the Go gopher, a Rust file is rust.
  'dart': (glyph: FileGlyph.code, accent: FileAccent.cyan),
  'go': (glyph: FileGlyph.code, accent: FileAccent.cyan),
  'elm': (glyph: FileGlyph.code, accent: FileAccent.cyan),
  'ts': (glyph: FileGlyph.code, accent: FileAccent.blue),
  'tsx': (glyph: FileGlyph.code, accent: FileAccent.blue),
  'mts': (glyph: FileGlyph.code, accent: FileAccent.blue),
  'cts': (glyph: FileGlyph.code, accent: FileAccent.blue),
  'js': (glyph: FileGlyph.code, accent: FileAccent.amber),
  'jsx': (glyph: FileGlyph.code, accent: FileAccent.amber),
  'mjs': (glyph: FileGlyph.code, accent: FileAccent.amber),
  'cjs': (glyph: FileGlyph.code, accent: FileAccent.amber),
  'py': (glyph: FileGlyph.code, accent: FileAccent.blue),
  'pyi': (glyph: FileGlyph.code, accent: FileAccent.blue),
  'ipynb': (glyph: FileGlyph.code, accent: FileAccent.orange),
  'rb': (glyph: FileGlyph.code, accent: FileAccent.red),
  'rs': (glyph: FileGlyph.code, accent: FileAccent.orange),
  'swift': (glyph: FileGlyph.code, accent: FileAccent.orange),
  'zig': (glyph: FileGlyph.code, accent: FileAccent.orange),
  'java': (glyph: FileGlyph.code, accent: FileAccent.red),
  'kt': (glyph: FileGlyph.code, accent: FileAccent.purple),
  'kts': (glyph: FileGlyph.code, accent: FileAccent.purple),
  'scala': (glyph: FileGlyph.code, accent: FileAccent.red),
  'c': (glyph: FileGlyph.code, accent: FileAccent.blue),
  'h': (glyph: FileGlyph.code, accent: FileAccent.purple),
  'cc': (glyph: FileGlyph.code, accent: FileAccent.blue),
  'cpp': (glyph: FileGlyph.code, accent: FileAccent.blue),
  'cxx': (glyph: FileGlyph.code, accent: FileAccent.blue),
  'hpp': (glyph: FileGlyph.code, accent: FileAccent.purple),
  'm': (glyph: FileGlyph.code, accent: FileAccent.blue),
  'mm': (glyph: FileGlyph.code, accent: FileAccent.blue),
  'cs': (glyph: FileGlyph.code, accent: FileAccent.green),
  'php': (glyph: FileGlyph.code, accent: FileAccent.purple),
  'lua': (glyph: FileGlyph.code, accent: FileAccent.blue),
  'pl': (glyph: FileGlyph.code, accent: FileAccent.blue),
  'r': (glyph: FileGlyph.code, accent: FileAccent.blue),
  'hs': (glyph: FileGlyph.code, accent: FileAccent.purple),
  'ex': (glyph: FileGlyph.code, accent: FileAccent.purple),
  'exs': (glyph: FileGlyph.code, accent: FileAccent.purple),
  'clj': (glyph: FileGlyph.code, accent: FileAccent.green),
  'sol': (glyph: FileGlyph.code, accent: FileAccent.neutral),
  'proto': (glyph: FileGlyph.code, accent: FileAccent.blue),
  'gradle': (glyph: FileGlyph.code, accent: FileAccent.cyan),
  'vue': (glyph: FileGlyph.code, accent: FileAccent.green),
  'svelte': (glyph: FileGlyph.code, accent: FileAccent.orange),

  // Things you run.
  'sh': (glyph: FileGlyph.script, accent: FileAccent.green),
  'bash': (glyph: FileGlyph.script, accent: FileAccent.green),
  'zsh': (glyph: FileGlyph.script, accent: FileAccent.green),
  'fish': (glyph: FileGlyph.script, accent: FileAccent.green),
  'ps1': (glyph: FileGlyph.script, accent: FileAccent.blue),
  'bat': (glyph: FileGlyph.script, accent: FileAccent.neutral),
  'cmd': (glyph: FileGlyph.script, accent: FileAccent.neutral),

  // Data and settings.
  'json': (glyph: FileGlyph.data, accent: FileAccent.amber),
  'jsonc': (glyph: FileGlyph.data, accent: FileAccent.amber),
  'json5': (glyph: FileGlyph.data, accent: FileAccent.amber),
  'yaml': (glyph: FileGlyph.data, accent: FileAccent.red),
  'yml': (glyph: FileGlyph.data, accent: FileAccent.red),
  'toml': (glyph: FileGlyph.data, accent: FileAccent.orange),
  'xml': (glyph: FileGlyph.markup, accent: FileAccent.orange),
  'plist': (glyph: FileGlyph.markup, accent: FileAccent.neutral),
  'ini': (glyph: FileGlyph.config, accent: FileAccent.neutral),
  'cfg': (glyph: FileGlyph.config, accent: FileAccent.neutral),
  'conf': (glyph: FileGlyph.config, accent: FileAccent.neutral),
  'properties': (glyph: FileGlyph.config, accent: FileAccent.neutral),
  'env': (glyph: FileGlyph.config, accent: FileAccent.amber),
  'csv': (glyph: FileGlyph.sheet, accent: FileAccent.green),
  'tsv': (glyph: FileGlyph.sheet, accent: FileAccent.green),
  'xlsx': (glyph: FileGlyph.sheet, accent: FileAccent.green),

  // Pages and their styling.
  'html': (glyph: FileGlyph.markup, accent: FileAccent.orange),
  'htm': (glyph: FileGlyph.markup, accent: FileAccent.orange),
  'css': (glyph: FileGlyph.style, accent: FileAccent.blue),
  'scss': (glyph: FileGlyph.style, accent: FileAccent.pink),
  'sass': (glyph: FileGlyph.style, accent: FileAccent.pink),
  'less': (glyph: FileGlyph.style, accent: FileAccent.pink),
  'styl': (glyph: FileGlyph.style, accent: FileAccent.pink),

  // Prose.
  'md': (glyph: FileGlyph.doc, accent: FileAccent.blue),
  'mdx': (glyph: FileGlyph.doc, accent: FileAccent.blue),
  'markdown': (glyph: FileGlyph.doc, accent: FileAccent.blue),
  'rst': (glyph: FileGlyph.doc, accent: FileAccent.blue),
  'txt': (glyph: FileGlyph.doc, accent: FileAccent.neutral),
  'log': (glyph: FileGlyph.doc, accent: FileAccent.neutral),
  'pdf': (glyph: FileGlyph.doc, accent: FileAccent.red),

  // Media.
  'png': (glyph: FileGlyph.image, accent: FileAccent.purple),
  'jpg': (glyph: FileGlyph.image, accent: FileAccent.purple),
  'jpeg': (glyph: FileGlyph.image, accent: FileAccent.purple),
  'gif': (glyph: FileGlyph.image, accent: FileAccent.purple),
  'webp': (glyph: FileGlyph.image, accent: FileAccent.purple),
  'avif': (glyph: FileGlyph.image, accent: FileAccent.purple),
  'bmp': (glyph: FileGlyph.image, accent: FileAccent.purple),
  'tiff': (glyph: FileGlyph.image, accent: FileAccent.purple),
  'ico': (glyph: FileGlyph.image, accent: FileAccent.purple),
  'icns': (glyph: FileGlyph.image, accent: FileAccent.purple),
  'svg': (glyph: FileGlyph.image, accent: FileAccent.orange),
  'mp4': (glyph: FileGlyph.video, accent: FileAccent.pink),
  'mov': (glyph: FileGlyph.video, accent: FileAccent.pink),
  'webm': (glyph: FileGlyph.video, accent: FileAccent.pink),
  'mkv': (glyph: FileGlyph.video, accent: FileAccent.pink),
  'avi': (glyph: FileGlyph.video, accent: FileAccent.pink),
  'mp3': (glyph: FileGlyph.audio, accent: FileAccent.pink),
  'wav': (glyph: FileGlyph.audio, accent: FileAccent.pink),
  'flac': (glyph: FileGlyph.audio, accent: FileAccent.pink),
  'aac': (glyph: FileGlyph.audio, accent: FileAccent.pink),
  'ogg': (glyph: FileGlyph.audio, accent: FileAccent.pink),
  'm4a': (glyph: FileGlyph.audio, accent: FileAccent.pink),
  'ttf': (glyph: FileGlyph.binary, accent: FileAccent.purple),
  'otf': (glyph: FileGlyph.binary, accent: FileAccent.purple),
  'woff': (glyph: FileGlyph.binary, accent: FileAccent.purple),
  'woff2': (glyph: FileGlyph.binary, accent: FileAccent.purple),

  // Bundles and output.
  'zip': (glyph: FileGlyph.archive, accent: FileAccent.neutral),
  'tar': (glyph: FileGlyph.archive, accent: FileAccent.neutral),
  'gz': (glyph: FileGlyph.archive, accent: FileAccent.neutral),
  'tgz': (glyph: FileGlyph.archive, accent: FileAccent.neutral),
  'bz2': (glyph: FileGlyph.archive, accent: FileAccent.neutral),
  'xz': (glyph: FileGlyph.archive, accent: FileAccent.neutral),
  'rar': (glyph: FileGlyph.archive, accent: FileAccent.neutral),
  '7z': (glyph: FileGlyph.archive, accent: FileAccent.neutral),
  'dmg': (glyph: FileGlyph.archive, accent: FileAccent.neutral),
  'exe': (glyph: FileGlyph.binary, accent: FileAccent.neutral),
  'dll': (glyph: FileGlyph.binary, accent: FileAccent.neutral),
  'so': (glyph: FileGlyph.binary, accent: FileAccent.neutral),
  'dylib': (glyph: FileGlyph.binary, accent: FileAccent.neutral),
  'wasm': (glyph: FileGlyph.binary, accent: FileAccent.purple),
  'bin': (glyph: FileGlyph.binary, accent: FileAccent.neutral),
  'o': (glyph: FileGlyph.binary, accent: FileAccent.neutral),

  // Databases.
  'sql': (glyph: FileGlyph.database, accent: FileAccent.amber),
  'db': (glyph: FileGlyph.database, accent: FileAccent.neutral),
  'sqlite': (glyph: FileGlyph.database, accent: FileAccent.neutral),
  'sqlite3': (glyph: FileGlyph.database, accent: FileAccent.neutral),
};
