import 'package:markdown/markdown.dart' as md;

/// The most Telegram shows in one message.
const int kTelegramMessageLimit = 4096;

/// One message to send: Telegram HTML when [html], else plain text.
typedef TelegramChunk = ({String text, bool html});

/// An assistant's Markdown answer as the Telegram messages that carry it, in
/// order, each within [limit].
///
/// Split between blocks — never inside a code block, never mid-sentence — and
/// rendered block by block, so a long answer arrives as a few readable messages
/// rather than one cut off at 4096 characters. A single block too long for one
/// message (a big code listing) goes as plain text in pieces instead.
List<TelegramChunk> telegramChunks(
  String markdown, {
  int limit = kTelegramMessageLimit,
}) {
  final chunks = <TelegramChunk>[];
  final pending = StringBuffer();
  void flush() {
    if (pending.isEmpty) return;
    chunks.add((text: pending.toString(), html: true));
    pending.clear();
  }

  for (final block in markdownBlocks(markdown)) {
    final html = telegramHtml(block);
    if (html.isEmpty) continue;
    if (html.length > limit) {
      flush();
      chunks.addAll(_plainPieces(block, limit));
      continue;
    }
    if (pending.length + 2 + html.length > limit) flush();
    if (pending.isNotEmpty) pending.write('\n\n');
    pending.write(html);
  }
  flush();
  return chunks;
}

/// [markdown] cut at blank lines, keeping each fenced code block whole.
List<String> markdownBlocks(String markdown) {
  final blocks = <String>[];
  final current = <String>[];
  String? fence;
  void flush() {
    if (current.isNotEmpty) blocks.add(current.join('\n'));
    current.clear();
  }

  for (final line in markdown.split('\n')) {
    final trimmed = line.trimLeft();
    if (fence != null) {
      current.add(line);
      if (trimmed.startsWith(fence)) fence = null;
      continue;
    }
    fence = _fenceOpening(trimmed);
    if (fence == null && line.trim().isEmpty) {
      flush();
      continue;
    }
    current.add(line);
  }
  flush();
  return blocks;
}

/// [markdown] in the HTML subset Telegram accepts: bold, italic, strike,
/// code, pre, links and quotes. Lists become bullet lines and headings bold
/// lines, since Telegram has neither; raw HTML in the answer is shown as text.
String telegramHtml(String markdown) {
  final document = md.Document(
    extensionSet: md.ExtensionSet.gitHubFlavored,
    encodeHtml: false,
  );
  return _render(document.parseLines(markdown.split('\n')), 0).trim();
}

String _render(List<md.Node>? nodes, int depth) =>
    (nodes ?? const <md.Node>[]).map((node) => _node(node, depth)).join();

String _node(md.Node node, int depth) {
  if (node is! md.Element) return telegramEscape(node.textContent);
  String inner() => _render(node.children, depth);
  return switch (node.tag) {
    'p' => '${inner()}\n\n',
    'h1' || 'h2' || 'h3' || 'h4' || 'h5' || 'h6' => '<b>${inner()}</b>\n\n',
    'strong' => '<b>${inner()}</b>',
    'em' => '<i>${inner()}</i>',
    'del' => '<s>${inner()}</s>',
    'code' => '<code>${telegramEscape(node.textContent)}</code>',
    'pre' => _pre(node),
    'a' => _link(node, inner()),
    'blockquote' => '<blockquote>${inner().trim()}</blockquote>\n\n',
    'ul' || 'ol' => _list(node, depth),
    'br' => '\n',
    'hr' => '———\n\n',
    'img' => telegramEscape(node.attributes['alt'] ?? ''),
    'table' => '${_tableRows(node).join('\n')}\n\n',
    'input' => node.attributes.containsKey('checked') ? '☑ ' : '☐ ',
    _ => inner(),
  };
}

String _pre(md.Element pre) {
  final code = pre.children?.whereType<md.Element>().firstOrNull;
  final text = telegramEscape((code ?? pre).textContent.trimRight());
  final language = code?.attributes['class'] ?? '';
  if (!RegExp(r'^language-[\w+#-]+$').hasMatch(language)) {
    return '<pre>$text</pre>\n\n';
  }
  return '<pre><code class="$language">$text</code></pre>\n\n';
}

/// A link Telegram can open, or just its words for anything else — a
/// `javascript:` or `file:` link has no business being tappable on a phone.
String _link(md.Element link, String label) {
  final href = link.attributes['href'] ?? '';
  final scheme = Uri.tryParse(href)?.scheme ?? '';
  if (!const {'http', 'https', 'tg', 'mailto'}.contains(scheme)) return label;
  return '<a href="${telegramEscape(href).replaceAll('"', '&quot;')}">$label</a>';
}

String _list(md.Element list, int depth) {
  var number = int.tryParse(list.attributes['start'] ?? '') ?? 1;
  final indent = '   ' * depth;
  final lines = StringBuffer();
  for (final item
      in list.children?.whereType<md.Element>() ?? const <md.Element>[]) {
    final marker = list.tag == 'ol' ? '${number++}.' : '•';
    lines.write('$indent$marker ${_render(item.children, depth + 1).trim()}\n');
  }
  return depth == 0 ? '$lines\n' : '\n$lines';
}

List<String> _tableRows(md.Element node) => [
  for (final child
      in node.children?.whereType<md.Element>() ?? const <md.Element>[])
    if (child.tag == 'tr')
      [
        for (final cell
            in child.children?.whereType<md.Element>() ?? const <md.Element>[])
          _render(cell.children, 0).trim(),
      ].join(' | ')
    else
      ..._tableRows(child),
];

/// [text] made safe to put inside Telegram HTML.
String telegramEscape(String text) => text
    .replaceAll('&', '&amp;')
    .replaceAll('<', '&lt;')
    .replaceAll('>', '&gt;');

/// Telegram HTML back to the words it shows — for the rare message Telegram's
/// parser refuses, which is then sent plain rather than not at all.
String telegramPlainText(String html) => html
    .replaceAll(RegExp(r'<[^>]*>'), '')
    .replaceAll('&lt;', '<')
    .replaceAll('&gt;', '>')
    .replaceAll('&quot;', '"')
    .replaceAll('&amp;', '&');

/// The run of backticks or tildes opening a code fence, or null.
String? _fenceOpening(String line) =>
    RegExp(r'^(`{3,}|~{3,})').firstMatch(line)?.group(1);

/// [text] as plain messages of at most [limit], cut at a line break where one
/// is near.
List<TelegramChunk> _plainPieces(String text, int limit) {
  final pieces = <TelegramChunk>[];
  var rest = text;
  while (rest.length > limit) {
    final newline = rest.lastIndexOf('\n', limit);
    final cut = newline > limit ~/ 2 ? newline : limit;
    pieces.add((text: rest.substring(0, cut), html: false));
    rest = rest.substring(cut == newline ? cut + 1 : cut);
  }
  if (rest.trim().isNotEmpty) pieces.add((text: rest, html: false));
  return pieces;
}
