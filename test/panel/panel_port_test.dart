import 'package:flutter_test/flutter_test.dart';
import 'package:grid_app/infrastructure/panel/panel_port.dart';

/// A trimmed but otherwise verbatim `ioreg -r -c IOUSBHostDevice -l` dump from a
/// Mac with a panel plugged into a hub, alongside a second serial device.
///
/// Kept as real output rather than a tidy invention: the shape that breaks a
/// naive reader is exactly what a hand-written fixture would smooth over — the
/// ids sit on one node and the device path two nodes below it, the order of the
/// properties inside a node is arbitrary, and there is a second serial port in
/// the tree that must never be picked.
const _ioreg = '''
+-o USB2.0 Hub@14200000  <class IOUSBHostDevice, id 0x10000058d>
  | {
  |   "idVendor" = 8457
  |   "idProduct" = 10261
  | }
  |
  | +-o CH343@14240000  <class IOUSBHostDevice, id 0x100026e10>
  | | {
  | |   "idProduct" = 21971
  | |   "idVendor" = 6790
  | | }
  | |
  | | +-o IOSerialBSDClient  <class IOSerialBSDClient, id 0x100026e11>
  | |     {
  | |       "IOTTYDevice" = "usbserial-14240"
  | |       "IOCalloutDevice" = "/dev/cu.usbserial-14240"
  | |     }
  | |
  | +-o USB JTAG/serial debug unit@14230000  <class IOUSBHostDevice, id 0x1e3e>
  |   | {
  |   |   "idProduct" = 4097
  |   |   "iManufacturer" = 1
  |   |   "idVendor" = 12346
  |   | }
  |   |
  |   | +-o AppleUSBACMData  <class AppleUSBACMData, id 0x100026e4c>
  |   |   | {
  |   |   |   "IOTTYBaseName" = "usbmodem"
  |   |   |   "idProduct" = 4097
  |   |   |   "idVendor" = 12346
  |   |   | }
  |   |   |
  |   |   +-o IOSerialBSDClient  <class IOSerialBSDClient, id 0x100026e4d>
  |   |       {
  |   |         "IOTTYDevice" = "usbmodem142301"
  |   |         "IOCalloutDevice" = "/dev/cu.usbmodem142301"
  |   |         "IODialinDevice" = "/dev/tty.usbmodem142301"
  |   |       }
''';

void main() {
  group('finding the panel among everything else on the USB tree', () {
    test('the native USB port is found by its ids, not by its name', () {
      expect(panelPortIn(_ioreg), '/dev/cu.usbmodem142301');
    });

    test('a second serial device is never mistaken for the panel', () {
      // The board itself enumerates twice, and the other port carries the
      // console: picking it gives a link that opens and then only ever delivers
      // log text, which reads as a device that never speaks.
      expect(panelPortIn(_ioreg), isNot(contains('usbserial')));
    });

    test('a different Espressif board is not this one', () {
      // Same vendor, different product — an ESP32 dev board on the same desk
      // must not be answered as the panel.
      expect(panelPortIn(_ioreg, productId: 0x1002), isNull);
    });

    test('an unplugged panel reads as absent, not as an error', () {
      expect(panelPortIn(''), isNull);
      expect(panelPortIn('+-o Root  <class IOUSBHostDevice>\n'), isNull);
    });

    test('ids from two different devices are never paired up', () {
      // The vendor is on one node and the product on its sibling. A flat scan
      // of the dump matches both and returns the wrong port; nesting is the
      // only thing that says they belong to different devices.
      const split = '''
+-o Something@1  <class IOUSBHostDevice, id 0x1>
  | {
  |   "idVendor" = 12346
  |   "idProduct" = 2
  | }
  |
+-o SomethingElse@2  <class IOUSBHostDevice, id 0x2>
  | {
  |   "idVendor" = 1
  |   "idProduct" = 4097
  | }
  |
  | +-o IOSerialBSDClient  <class IOSerialBSDClient, id 0x3>
  | |   {
  | |     "IOCalloutDevice" = "/dev/cu.usbmodemWRONG"
  | |   }
''';
      expect(panelPortIn(split), isNull);
    });
  });
}
