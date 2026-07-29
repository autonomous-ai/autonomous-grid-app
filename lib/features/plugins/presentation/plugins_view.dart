import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../shared/widgets/error_box.dart';
import '../../../shared/widgets/extension_toolbar.dart';
import '../../agents/presentation/extension_screen.dart';
import '../logic/plugins_controller.dart';
import 'widgets/add_plugin_dialog.dart';
import 'widgets/plugin_list.dart';

/// The plugins the assistant can load — whole tool backends (a browser it can
/// drive, a search provider it can query), each with a switch. Read from what's
/// really installed, so nothing shows up here the assistant can't actually use.
class PluginsView extends ConsumerWidget {
  const PluginsView({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return ExtensionScreen(
      title: 'Plugins',
      subtitle:
          'Give the assistant new tools: shipped ones you switch on, or one '
          'pulled from a Git repository.',
      searchHint: 'Search plugins',
      createLabel: 'Add from Git',
      onCreate: showAddPluginDialog,
      onRefresh: () => ref.invalidate(pluginsProvider),
      listBuilder: (context, {required filtered, required matches}) {
        return switch (ref.watch(pluginsProvider)) {
          AsyncData(:final value) => PluginList(
            filtered: filtered,
            plugins: [
              for (final plugin in value)
                if (matches(plugin.name, plugin.description)) plugin,
            ],
          ),
          AsyncError(:final error) => ErrorBox(
            message: "Couldn't read the installed plugins: $error",
          ),
          _ => const ExtensionLoadingRows(),
        };
      },
    );
  }
}
