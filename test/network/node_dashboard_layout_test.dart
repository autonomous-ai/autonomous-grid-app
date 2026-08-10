import 'package:flutter_test/flutter_test.dart';
import 'package:grid_app/features/network/logic/node_dashboard_layout.dart';

void main() {
  test('a window fits as many cards as its width allows', () {
    // 340 + 14 gap per column: two need 694, three need 1048.
    expect(dashboardColumns(694), 2);
    expect(dashboardColumns(1048), 3);
    expect(dashboardColumns(1136), 3); // the dialog's own inner width
  });

  test('one pixel short of a column does not claim it', () {
    // The card would be squeezed under its target rather than the row simply
    // stretching the columns it does have.
    expect(dashboardColumns(693), 1);
    expect(dashboardColumns(1047), 2);
  });

  test('a narrow or unmeasured width still yields a usable column count', () {
    // The caller divides by this. Zero arrives on the first layout pass, before
    // constraints are known, and a 0 here would take the arithmetic with it.
    expect(dashboardColumns(0), 1);
    expect(dashboardColumns(-1), 1);
    expect(dashboardColumns(120), 1);
  });
}
