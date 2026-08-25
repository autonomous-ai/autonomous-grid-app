import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:grid_app/features/network/logic/change_grid_type_controller.dart';
import 'package:grid_app/infrastructure/api/models/managed_network.dart';

ChangeGridTypeController _controller(ProviderContainer container) =>
    container.read(changeGridTypeControllerProvider.notifier);

void main() {
  late ProviderContainer container;

  setUp(() => container = ProviderContainer());
  tearDown(() => container.dispose());

  group('picking a rule before confirming', () {
    test('a different rule asks to confirm, and names what was picked', () {
      _controller(container).select(
        target: ManagedNetworkType.restricted,
        current: ManagedNetworkType.anyone,
      );

      final state = container.read(changeGridTypeControllerProvider);
      expect(state, isA<ChangeGridTypeConfirming>());
      expect(
        (state as ChangeGridTypeConfirming).target,
        ManagedNetworkType.restricted,
      );
    });

    test(
      'picking the rule the grid is already on backs out of a pending one',
      () {
        // The bug this pins: the field shows the PENDING pick, so choosing the
        // saved rule again is how you change your mind. It used to return early
        // and leave the field stuck on the rule the owner had just abandoned —
        // with no way back except closing the dialog.
        final controller = _controller(container);
        controller.select(
          target: ManagedNetworkType.restricted,
          current: ManagedNetworkType.anyone,
        );
        expect(
          container.read(changeGridTypeControllerProvider),
          isA<ChangeGridTypeConfirming>(),
        );

        controller.select(
          target: ManagedNetworkType.anyone,
          current: ManagedNetworkType.anyone,
        );

        expect(
          container.read(changeGridTypeControllerProvider),
          isA<ChangeGridTypeIdle>(),
        );
      },
    );

    test(
      'switching between two other rules re-targets rather than stacking',
      () {
        final controller = _controller(container);
        controller.select(
          target: ManagedNetworkType.restricted,
          current: ManagedNetworkType.anyone,
        );
        controller.select(
          target: ManagedNetworkType.domain,
          current: ManagedNetworkType.anyone,
        );

        final state = container.read(changeGridTypeControllerProvider);
        expect(
          (state as ChangeGridTypeConfirming).target,
          ManagedNetworkType.domain,
        );
      },
    );

    test('cancel returns to idle so the field shows the saved rule again', () {
      final controller = _controller(container);
      controller.select(
        target: ManagedNetworkType.domain,
        current: ManagedNetworkType.restricted,
      );

      controller.cancel();

      expect(
        container.read(changeGridTypeControllerProvider),
        isA<ChangeGridTypeIdle>(),
      );
    });

    test('selecting sends no request — confirming is a separate step', () {
      var called = 0;
      final probe = ProviderContainer(
        overrides: [
          setNetworkTypeFnProvider.overrideWithValue(({
            required apiUrl,
            required sessionToken,
            required networkId,
            required type,
          }) async {
            called++;
            return (true, null);
          }),
        ],
      );
      addTearDown(probe.dispose);

      probe
          .read(changeGridTypeControllerProvider.notifier)
          .select(
            target: ManagedNetworkType.restricted,
            current: ManagedNetworkType.anyone,
          );

      expect(called, 0);
    });
  });
}
