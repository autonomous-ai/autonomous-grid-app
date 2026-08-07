import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:grid_app/features/chat/logic/chat_store.dart';
import 'package:grid_app/features/chat/logic/conversation.dart';
import 'package:grid_app/features/chat/presentation/chat_header.dart';
import 'package:grid_app/features/playground/logic/chat_message.dart';
import 'package:grid_app/shared/layouts/widgets/app_top_bar.dart';
import 'package:grid_app/shared/layouts/widgets/grid_power_pill.dart';

/// Geometry only. The chat title and the grid pill share one row now, and the
/// bug that put them there was a flex split — an `Expanded` header next to a
/// `Spacer`, both taking flex: 1, parking the pill mid-row. Reading the code
/// made that look correct twice, so these assert measured rects instead.
void main() {
  late Directory tmp;

  setUp(() => tmp = Directory.systemTemp.createTempSync('top_bar_layout'));
  tearDown(() => tmp.deleteSync(recursive: true));

  const width = 1200.0;

  Widget host({required bool headerVisible}) {
    final store = ChatStore(directory: tmp);
    store.save(
      Conversation(
        id: 'c1',
        title: 'Recap News webs',
        model: 'm',
        createdAt: DateTime(2026, 1, 1),
        updatedAt: DateTime(2026, 1, 1),
        messages: const [ChatMessage(role: ChatRole.user, text: 'hello')],
      ),
    );
    return ProviderScope(
      overrides: [chatStoreProvider.overrideWithValue(store)],
      child: MaterialApp(
        home: Scaffold(
          body: Column(
            children: [
              _SeedHeaderVisible(visible: headerVisible),
              const AppTopBar(),
            ],
          ),
        ),
      ),
    );
  }

  testWidgets('the grid pill sits against the right edge, not mid-row', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(width, 800);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(host(headerVisible: true));
    await tester.pumpAndSettle();

    _expectPackedRight(tester, width);
  });

  testWidgets('the chat header stays left while the pill stays right', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(width, 800);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(host(headerVisible: true));
    await tester.pumpAndSettle();

    final header = tester.getRect(find.byType(ChatHeader));
    final pill = tester.getRect(find.byType(GridPowerPill));

    expect(header.left, moreOrLessEquals(16, epsilon: 0.5));
    // They share a row: same vertical centre, no overlap.
    expect(header.center.dy, moreOrLessEquals(pill.center.dy, epsilon: 0.5));
    expect(header.right, lessThan(pill.left));
  });

  testWidgets('with no chat header the pill is still hard right', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(width, 800);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(host(headerVisible: false));
    await tester.pumpAndSettle();

    expect(find.byType(ChatHeader), findsNothing);
    _expectPackedRight(tester, width);
  });
}

/// The right-hand group ends on the bar's own 18px padding, with the grid pill
/// hard against it.
///
/// The pill stopped being the last thing in the row when the panel toggles
/// arrived after it, so pinning the *pill* to the window edge would now be
/// pinning the wrong thing. What the original bug did was park the pill in the
/// middle of the row, and that is what these two assertions still catch.
void _expectPackedRight(WidgetTester tester, double width) {
  final pill = tester.getRect(find.byType(GridPowerPill));
  final toggle = tester.getRect(find.byTooltip('Show preview panel'));

  expect(toggle.right, moreOrLessEquals(width - 18, epsilon: 0.5));
  expect(pill.right, lessThanOrEqualTo(toggle.left + 0.5));
  expect(pill.right, greaterThan(width / 2));
}

/// Flips [chatHeaderVisibleProvider] the way the chat view does, so the bar
/// under test sees a real "a conversation is open" signal.
class _SeedHeaderVisible extends ConsumerStatefulWidget {
  const _SeedHeaderVisible({required this.visible});

  final bool visible;

  @override
  ConsumerState<_SeedHeaderVisible> createState() => _SeedHeaderVisibleState();
}

class _SeedHeaderVisibleState extends ConsumerState<_SeedHeaderVisible> {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      ref.read(chatHeaderVisibleProvider.notifier).set(widget.visible);
    });
  }

  @override
  Widget build(BuildContext context) => const SizedBox.shrink();
}
