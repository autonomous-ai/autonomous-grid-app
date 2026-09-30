/// How a conversation is drawn in Grid, on a computer and on a phone.
library;

/// One run of an answer's Markdown, and whether its last fence is still open.
export 'src/chat_markdown.dart';

/// Syntax colour for a block of code, and the language a file's name implies.
export 'src/code_highlight.dart';

/// Holds a code surface at the user's code size, out of the UI scale.
export 'src/code_text_scope.dart';

/// The fenced code block: language label, copy, fold.
export 'src/markdown_code_block.dart';

/// The stylesheet an answer's Markdown is drawn with.
export 'src/markdown_style.dart';

/// The words an agent's permission question is put in.
export 'src/permission_words.dart';
