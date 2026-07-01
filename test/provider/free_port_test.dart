import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:grid_app/features/provider_node/logic/free_port.dart';

void main() {
  test('findFreePort returns a released, bindable loopback port', () async {
    final port = await findFreePort();
    expect(port, inInclusiveRange(1, 65535));

    // The socket was closed before returning, so we can bind the port
    // ourselves — proving it's actually free for the engine to take.
    final socket = await ServerSocket.bind(InternetAddress.loopbackIPv4, port);
    addTearDown(socket.close);
    expect(socket.port, port);
  });
}
