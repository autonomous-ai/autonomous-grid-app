import 'package:flutter_test/flutter_test.dart';
import 'package:grid_app/features/network/logic/member_display.dart';

void main() {
  group('memberHandle', () {
    test('an address reads as the handle the rest of the user\'s tools show '
        '— the domain is what every row on a work grid repeats', () {
      expect(memberHandle('dee@autonomous.ai'), '@dee');
      expect(memberHandle('phamngochuy.1989@gmail.com'), '@phamngochuy.1989');
    });

    test('a bare name still gets a handle, so a roster row the control plane '
        'accepted without an address still names someone', () {
      expect(memberHandle('dee'), '@dee');
      expect(memberHandle('  dee  '), '@dee');
    });

    test('the sign is never doubled — memberLocalPart hands back the whole '
        'string when nothing precedes the @, and @@ reads as a bug', () {
      expect(memberHandle('@autonomous.ai'), '@autonomous.ai');
    });

    test('an empty row is a lone sign rather than a crash, because the panel '
        'draws whatever the roster holds', () {
      expect(memberHandle(''), '@');
    });
  });
}
