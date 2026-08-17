/// The handful of XML lookups every part of the docx reader needs.
///
/// All of them ignore namespaces and match on the local name. That is not
/// laziness: a `.docx` writes `w:p` and a `.pptx` writes `a:p` for the same idea,
/// Word's own files disagree about which prefix binds to which URI across parts,
/// and a reader that insisted on the prefix would refuse files Word opens
/// happily. The prefix still matters when *writing*, which is why
/// `docx_edit.dart` takes it from the element it is replacing.
library;

import 'package:xml/xml.dart';

/// The first child element called [local], or null.
XmlElement? childNamed(XmlElement? parent, String local) {
  if (parent == null) return null;
  for (final child in parent.childElements) {
    if (child.name.local == local) return child;
  }
  return null;
}

/// Every child element called [local], in order.
Iterable<XmlElement> childrenNamed(XmlElement? parent, String local) {
  if (parent == null) return const [];
  return parent.childElements.where((c) => c.name.local == local);
}

/// The first descendant called [local] anywhere below [parent].
XmlElement? descendantNamed(XmlElement? parent, String local) {
  if (parent == null) return null;
  for (final node in parent.descendantElements) {
    if (node.name.local == local) return node;
  }
  return null;
}

/// The value of the attribute whose local name is [local].
String? attr(XmlElement? element, String local) {
  if (element == null) return null;
  for (final attribute in element.attributes) {
    if (attribute.name.local == local) return attribute.value;
  }
  return null;
}

/// The `w:val` of a child element — the shape most OOXML properties take.
String? valOf(XmlElement? parent, String local) =>
    attr(childNamed(parent, local), 'val');

int? intAttr(XmlElement? element, String local) {
  final raw = attr(element, local);
  return raw == null ? null : int.tryParse(raw.trim());
}

int? intVal(XmlElement? parent, String local) {
  final raw = valOf(parent, local);
  return raw == null ? null : int.tryParse(raw.trim());
}

/// An OOXML on/off property, which has three states and only two of them are
/// written down.
///
/// `<w:b/>` with no attribute is **on** — that is the common case, and reading it
/// as "unset" is how a bold heading loses its bold. `w:val="0"`/`"false"`/`"off"`
/// is a real **off**, which a style-bearing run needs to be able to say. A missing
/// element is neither, and comes back null so the cascade below it can answer.
bool? onOff(XmlElement? parent, String local) {
  final element = childNamed(parent, local);
  if (element == null) return null;
  final raw = attr(element, 'val');
  if (raw == null) return true;
  return switch (raw.trim().toLowerCase()) {
    '0' || 'false' || 'off' => false,
    _ => true,
  };
}

/// A colour that means something. Word writes `auto` for "you decide", which is
/// what null already says, and an empty value for nothing at all.
String? colorVal(String? raw) {
  if (raw == null) return null;
  final value = raw.trim();
  if (value.isEmpty || value.toLowerCase() == 'auto') return null;
  return value.startsWith('#') ? value.substring(1) : value;
}

/// `w:sz` on a border is in **eighths of a point**, unlike `w:sz` on a run
/// (half-points) — the same attribute name for two different units, in one file
/// format. A point is 4/3 of a pixel, so eighths land on sz/6.
double borderWidthPx(int? eighthsOfPoint) => (eighthsOfPoint ?? 0) / 6;
