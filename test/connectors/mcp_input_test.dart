import 'package:flutter_test/flutter_test.dart';
import 'package:grid_app/features/connectors/logic/mcp_input.dart';

void main() {
  group('parseArgLines', () {
    test('one argument per line, dropping blank lines', () {
      expect(parseArgLines('-y\n\nserver-notion\n'), ['-y', 'server-notion']);
    });

    test('empty text is no args', () {
      expect(parseArgLines('   '), isEmpty);
    });
  });

  group('parseEnvLines', () {
    test(
      'splits KEY=value on the first =, keeping later ones in the value',
      () {
        expect(parseEnvLines('TOKEN=a=b\nHOST=x'), {
          'TOKEN': 'a=b',
          'HOST': 'x',
        });
      },
    );

    test('skips a line with no = or a blank key', () {
      expect(parseEnvLines('novalue\n=orphan\nOK=1'), {'OK': '1'});
    });
  });

  group('parseHeaderLines', () {
    test('splits Name: value on the first colon and trims', () {
      expect(parseHeaderLines('Authorization:  Bearer x '), {
        'Authorization': 'Bearer x',
      });
    });

    test('skips malformed lines', () {
      expect(parseHeaderLines('nope\nContent-Type: application/json'), {
        'Content-Type': 'application/json',
      });
    });
  });
}
