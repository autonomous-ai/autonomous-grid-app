import 'package:flutter_test/flutter_test.dart';
import 'package:grid_app/features/provider_node/logic/node_name.dart';

void main() {
  test('strips the .local mDNS suffix', () {
    expect(deriveNodeName('Jacobs-MacBook-Pro.local'), 'Jacobs-MacBook-Pro');
  });

  test('passes an already-clean host name through', () {
    expect(deriveNodeName('mac-mini'), 'mac-mini');
  });

  test('sanitises spaces and punctuation into a filesystem-safe id', () {
    expect(deriveNodeName("Jacob's MacBook"), 'Jacob-s-MacBook');
  });

  test('collapses repeats and trims leading/trailing separators', () {
    expect(deriveNodeName('  --Foo   Bar--  '), 'Foo-Bar');
  });

  test('falls back to grid-app when nothing usable remains', () {
    expect(deriveNodeName(''), fallbackNodeName);
    expect(deriveNodeName('   '), fallbackNodeName);
    expect(deriveNodeName('...'), fallbackNodeName);
  });
}
