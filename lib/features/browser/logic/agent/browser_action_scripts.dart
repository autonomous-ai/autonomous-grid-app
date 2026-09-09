/// The scripts that *act* on a page, as opposed to reading it.
///
/// Each is built around a `ref` from the last snapshot, looked up in the
/// `window.__gridRefs` map that snapshot left behind. A ref the map has never
/// heard of — because the page navigated, or because the agent invented one —
/// comes back as a refusal telling it to snapshot again, rather than as a click
/// on whatever is in that slot now.
library;

import 'dart:convert';

/// The preamble every action shares: find the element, or say why not.
///
/// `JSON.stringify` on the way out for the same reason the snapshot does it —
/// a string is the one shape every engine marshals back unchanged.
const String _lookup = '''
  const refs = window.__gridRefs;
  const el = refs && refs.get(REF);
  if (!el) {
    return JSON.stringify({
      ok: false,
      error: 'No element called "' + REF + '" on this page. Take a fresh '
        + 'browser_snapshot — refs belong to the page they were read from.'
    });
  }
  if (!el.isConnected) {
    return JSON.stringify({
      ok: false,
      error: 'That element has since left the page. Take a fresh snapshot.'
    });
  }
''';

/// Click the element [ref] names.
///
/// Scrolled into view first, because a click on something off screen is a click
/// a real user could not have made — and some pages check.
String browserClickScript(String ref) =>
    '''
(() => {
${_lookup.replaceAll('REF', jsonEncode(ref))}
  el.scrollIntoView({ block: 'center', inline: 'center' });
  el.click();
  return JSON.stringify({
    ok: true,
    what: (el.innerText || el.value || el.getAttribute('aria-label') || '')
      .replace(/\\s+/g, ' ').trim().slice(0, 80)
  });
})()
''';

/// Put [text] into the input [ref] names, optionally pressing Enter after.
///
/// The value is set through the prototype's own setter rather than by assigning
/// `el.value`. React installs a value setter of its own on the element, and an
/// assignment goes to that instead of the DOM — the box shows the text, React's
/// state never hears about it, and the form submits empty. This is the standard
/// way around it, and most pages worth typing into are React.
String browserTypeScript(
  String ref, {
  required String text,
  required bool submit,
}) =>
    '''
(() => {
${_lookup.replaceAll('REF', jsonEncode(ref))}
  const value = ${jsonEncode(text)};
  el.scrollIntoView({ block: 'center', inline: 'center' });
  el.focus();
  const proto = el instanceof HTMLTextAreaElement
    ? HTMLTextAreaElement.prototype
    : HTMLInputElement.prototype;
  const setter = Object.getOwnPropertyDescriptor(proto, 'value');
  if (setter && setter.set && 'value' in el) {
    setter.set.call(el, value);
  } else if (el.isContentEditable) {
    el.textContent = value;
  } else {
    el.value = value;
  }
  el.dispatchEvent(new Event('input', { bubbles: true }));
  el.dispatchEvent(new Event('change', { bubbles: true }));

  let submitted = false;
  if (${submit ? 'true' : 'false'}) {
    const key = { key: 'Enter', code: 'Enter', keyCode: 13, which: 13,
      bubbles: true, cancelable: true };
    const down = new KeyboardEvent('keydown', key);
    const prevented = !el.dispatchEvent(down);
    el.dispatchEvent(new KeyboardEvent('keyup', key));
    // Only when the page didn't take the key itself: a search box that handles
    // Enter and a form that submits on it would otherwise both fire, which
    // sends the query twice.
    if (!prevented && el.form && el.form.requestSubmit) {
      el.form.requestSubmit();
    }
    submitted = true;
  }
  return JSON.stringify({ ok: true, submitted: submitted });
})()
''';
