import 'package:flutter/material.dart';
import 'package:re_highlight/languages/all.dart';
import 'package:re_highlight/re_highlight.dart';
import 'package:re_highlight/styles/atom-one-dark.dart';
import 'package:re_highlight/styles/atom-one-light.dart';

/// Syntax colouring for source the app shows: fenced code blocks in a
/// transcript, the lines of a diff, a file open in the Files panel.
///
/// `re_highlight` is the highlight.js grammar set ported to Dart — ~197
/// languages, which is what a coding agent actually emits. The TextMate-based
/// alternative (`syntax_highlight`) matches VS Code's colours more closely but
/// ships grammars for only five languages — dart, json, sql, yaml and
/// serverpod — with no python, javascript, bash or go, so it can't colour most
/// of what lands in this transcript.
abstract final class CodeHighlight {
  static final Highlight _engine = Highlight()
    ..registerLanguages(builtinAllLanguages);

  /// Whether [language] (a fence's info string) is one we can colour.
  static bool supports(String language) =>
      builtinAllLanguages.containsKey(_normalise(language));

  /// Highlights [code], falling back to a single-colour span when the language
  /// is unknown or the grammar throws.
  ///
  /// [base] carries the mono face and size; the theme only contributes colour,
  /// so the block keeps the app's type regardless of which palette is active.
  ///
  /// **Answers already given are remembered** — see [_memo]. The spans are
  /// immutable, so handing the same one back is free and safe.
  static TextSpan? spans({
    required String code,
    required String language,
    required TextStyle base,
    required Brightness brightness,
  }) {
    final name = _normalise(language);
    if (!builtinAllLanguages.containsKey(name)) return null;

    final key = _Key(code, name, brightness, base);
    final remembered = _memo[key];
    if (remembered != null) return remembered.span;

    try {
      final result = _engine.highlight(code: code, language: name);
      final renderer = TextSpanRenderer(
        base,
        brightness == Brightness.dark ? atomOneDarkTheme : atomOneLightTheme,
      );
      result.render(renderer);
      return _remember(key, renderer.span);
    } catch (_) {
      // A grammar that chokes on a fragment mid-stream must not take the
      // transcript down with it — the caller renders plain text instead. The
      // failure is remembered too, so a line that can't be coloured isn't
      // re-parsed on every frame it's on screen.
      return _remember(key, null);
    }
  }

  /// What has already been coloured, newest last.
  ///
  /// Measured before it existed: one line of Dart costs ~170µs to tokenise, and
  /// a diff draws its lines one at a time — a screenful is ~8ms of the 16ms a
  /// frame has, spent again on every rebuild and every scroll. That is the
  /// difference between a diff that scrolls and one that stutters.
  ///
  /// Keyed by the text *and* how it would be drawn: the same line in another
  /// language, or under the other theme, is a different answer.
  static final Map<_Key, _Spans> _memo = {};

  /// Roughly a few large files' worth of lines. Above this the oldest entries
  /// go: the cache is for what is on screen and what was just scrolled past,
  /// not a record of everything the app has ever drawn.
  static const int _memoLimit = 4000;

  static TextSpan? _remember(_Key key, TextSpan? span) {
    if (_memo.length >= _memoLimit) {
      // Dart maps keep insertion order, so the first key is the oldest.
      _memo.remove(_memo.keys.first);
    }
    _memo[key] = _Spans(span);
    return span;
  }

  /// Drops what has been remembered. For tests that measure the cost of a
  /// parse — nothing in the app needs it, since a stale entry is impossible:
  /// every input that decides the answer is part of the key.
  @visibleForTesting
  static void forgetHighlights() => _memo.clear();

  /// Fence info strings arrive in whatever form the model wrote them.
  static String _normalise(String language) {
    final name = language.trim().toLowerCase();
    return switch (name) {
      'js' || 'jsx' || 'node' => 'javascript',
      'ts' || 'tsx' => 'typescript',
      'py' || 'python3' => 'python',
      'sh' || 'shell' || 'zsh' || 'console' => 'bash',
      'yml' => 'yaml',
      'md' => 'markdown',
      'c++' => 'cpp',
      'rs' => 'rust',
      'golang' => 'go',
      _ => name,
    };
  }
}

/// The highlighter's name for the language of [path], or '' when its extension
/// isn't one we have a grammar for.
///
/// Extension only. A shebang would name the language of the handful of files
/// that have no extension, but reading one means reading the file — and the
/// callers here already hold nothing but a path.
String languageForPath(String path) {
  final name = path.split(RegExp(r'[/\\]')).last;
  final dot = name.lastIndexOf('.');
  if (dot <= 0 || dot == name.length - 1) return '';
  final extension = name.substring(dot + 1);
  return CodeHighlight.supports(extension) ? extension : '';
}

/// What a highlighted line was asked for: the text, the grammar, and the two
/// things that decide its colours.
///
/// [base] is part of it because it carries the size and face the spans were
/// built with — the code font is a user setting, and a cached span built at the
/// old size would ignore a change the user just made.
@immutable
class _Key {
  const _Key(this.code, this.language, this.brightness, this.base);

  final String code;
  final String language;
  final Brightness brightness;
  final TextStyle base;

  @override
  bool operator ==(Object other) =>
      other is _Key &&
      other.code == code &&
      other.language == language &&
      other.brightness == brightness &&
      other.base == base;

  @override
  int get hashCode => Object.hash(code, language, brightness, base);
}

/// A remembered answer. Wrapped so that "we tried and it wouldn't colour" is a
/// cache hit rather than a miss that re-parses every frame.
class _Spans {
  const _Spans(this.span);

  final TextSpan? span;
}
