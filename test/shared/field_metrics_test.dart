import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:grid_app/shared/theme/app_theme.dart';

/// A text field stands at [AppControl.heightField]. Material disagrees: its
/// default field is built for a phone, and between `contentPadding` and the 48px
/// touch target it hands a `prefixIcon`, the grid list's search box rendered 48
/// tall.
///
/// A metrics test, not a taste test: it catches a Material default quietly
/// reasserting itself on an SDK bump.
///
/// It pins the field against the *token*, not against whatever button happens to
/// sit beside it. Both of this test's earlier versions got that wrong in the
/// same way — first by comparing the field to the grid header's button (which is
/// deliberately [AppControl.heightSmall], because that row is tight), then by
/// holding it to [AppControl.height], a push button's size. A field is typed in,
/// not clicked, and has its own token.
void main() {
  testWidgets('a search field stands at field height', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: buildAppTheme(brightness: Brightness.light),
        home: Scaffold(
          body: Row(
            children: [
              SizedBox(
                width: 200,
                child: TextField(
                  style: kFieldTextStyle,
                  decoration: const InputDecoration(
                    hintText: 'Search…',
                    prefixIcon: Icon(Icons.search, size: kFieldIconSize),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    final field = tester.getSize(find.byType(TextField)).height;
    expect(
      field,
      closeTo(AppControl.heightField, 1.0),
      reason:
          'the search field is ${field}px — a field is '
          '${AppControl.heightField}px, and Material\'s phone-sized default is '
          'what this exists to hold back',
    );
  });
}
