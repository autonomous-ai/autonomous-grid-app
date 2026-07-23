import 'package:flutter/material.dart';
import 'package:re_highlight/languages/all.dart';
import 'package:re_highlight/re_highlight.dart';
import 'package:re_highlight/styles/atom-one-dark.dart';
import 'package:re_highlight/styles/atom-one-light.dart';

/// Syntax colouring for fenced code blocks.
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
  static TextSpan? spans({
    required String code,
    required String language,
    required TextStyle base,
    required Brightness brightness,
  }) {
    final name = _normalise(language);
    if (!builtinAllLanguages.containsKey(name)) return null;
    try {
      final result = _engine.highlight(code: code, language: name);
      final renderer = TextSpanRenderer(
        base,
        brightness == Brightness.dark ? atomOneDarkTheme : atomOneLightTheme,
      );
      result.render(renderer);
      return renderer.span;
    } catch (_) {
      // A grammar that chokes on a fragment mid-stream must not take the
      // transcript down with it — the caller renders plain text instead.
      return null;
    }
  }

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
