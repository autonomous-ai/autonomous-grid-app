import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:grid_app/features/playground/logic/chat_message.dart';
import 'package:grid_app/features/playground/presentation/chat_bubble.dart';
import 'package:grid_app/shared/theme/app_theme.dart';

/// A markdown table in a reply. Two things the custom table builder has to keep
/// doing, both of which were bugs the first time round:
///
/// - cells hold markdown of their own (bold, links), so rendering the raw
///   string leaves `**Agoda**` and `[url](url)` on screen;
/// - a cell holding a long URL must not drag the table past the pane.
void main() {
  Future<void> pumpTable(WidgetTester tester, String markdown) async {
    tester.view.physicalSize = const Size(1400, 900);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(
        theme: buildAppTheme(),
        home: Scaffold(
          body: Center(
            child: SizedBox(
              width: 760, // proseWidth
              child: SingleChildScrollView(
                child: ChatBubble(
                  message: ChatMessage(
                    role: ChatRole.assistant,
                    text: markdown,
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('bold inside a cell renders, not its asterisks', (tester) async {
    await pumpTable(
      tester,
      '| Nền tảng | Giá |\n|---|---|\n| **Agoda** | 1tr |',
    );
    expect(find.textContaining('**Agoda**'), findsNothing);
    expect(find.textContaining('Agoda'), findsWidgets);
  });

  testWidgets('a long url in a cell does not overflow the table', (
    tester,
  ) async {
    await pumpTable(
      tester,
      '| Nền tảng | Link |\n|---|---|\n'
      '| Agoda | https://www.agoda.com/hanoi-hotel-deals/hotels-in-hanoi-vn.html'
      '?checkIn=2026-07-25&checkOut=2026-07-27&rooms=1&adults=2 |',
    );
    expect(tester.takeException(), isNull);
    final table = tester.getRect(find.byType(Table).first);
    expect(
      table.width,
      lessThanOrEqualTo(760.0),
      reason: 'table ran past the prose column',
    );
  });

  testWidgets('a table uses the full column while prose keeps its measure', (
    tester,
  ) async {
    // The whole reason the transcript column is 1000 wide while proseWidth is
    // 760: a five-column table needs the room, body copy does not. They travel
    // together in one text segment, so the split has to happen per block.
    tester.view.physicalSize = const Size(1600, 1200);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    const src = '''
Một đoạn văn xuôi đứng trước bảng, đủ dài để chạm mép nếu nó không bị giới hạn.

| # | Tên khách sạn | Khu vực | Giá | Điểm nổi bật |
|---|---|---|---|---|
| 1 | **Sofitel Legend Metropole** | French Quarter | 8–12tr | Lịch sử từ 1901, bar trên mái, spa |
''';
    await tester.pumpWidget(
      MaterialApp(
        theme: buildAppTheme(),
        home: Scaffold(
          body: Center(
            child: SizedBox(
              width: 1000, // the transcript column
              child: SingleChildScrollView(
                child: ChatBubble(
                  message: ChatMessage(role: ChatRole.assistant, text: src),
                ),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(tester.getRect(find.byType(Table).first).width, 1000.0);
    expect(
      tester.getRect(find.textContaining('Một đoạn văn xuôi').first).width,
      lessThanOrEqualTo(760.0),
      reason: 'prose escaped its measure',
    );
  });
}
