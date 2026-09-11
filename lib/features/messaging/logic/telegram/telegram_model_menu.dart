part of 'telegram_sessions.dart';

/// `/model`: see what the current chat answers with, and change it.
mixin _ModelMenu on _MenuBase {
  /// The models this chat's assistant can answer with, the current one ticked.
  Future<void> model(int chatId) async {
    if (turns.busy(chatId)) return _busy(chatId, 'change the model');
    final target = _threads.current(chatId);
    final items = _modelItems(target);
    if (items.isEmpty) {
      await _api.sendMessage(
        chatId,
        'No models are available on this grid now.',
      );
      return;
    }
    final id = _nextMenu++;
    final messageId = await _open(
      chatId,
      _modelText(target),
      telegramMenuRows(menu: id, items: items, page: 0),
    );
    _menus[chatId] = _Models(id, messageId, target, items);
  }

  Future<void> _onModelsTap(
    int chatId,
    _Models menu,
    TelegramMenuTap tap,
  ) async {
    switch (tap) {
      case TelegramPickTap(:final index) when index < menu.items.length:
        final model = menu.items[index].value;
        await _setModel(chatId, menu.target, model);
        return _finish(
          chatId,
          menu,
          '<b>Model set to</b> <code>${telegramEscape(model)}</code> — your '
          'next message in this chat uses it.',
        );
      case TelegramPageTap(:final page):
        return _redraw(
          chatId,
          menu,
          _modelText(menu.target),
          telegramMenuRows(menu: menu.id, items: menu.items, page: page),
        );
      default:
        return;
    }
  }

  String _modelText(String? target) =>
      '<b>Current model:</b> <code>${telegramEscape(_modelOf(target))}</code>'
      '\n\nPick the model this chat answers with:';

  /// The text models [target]'s assistant can use — the Chat composer's own
  /// list, less what that assistant can't take (see [agentSupportsModel]).
  List<TelegramMenuItem> _modelItems(String? target) {
    final agent = _agentOf(target);
    final current = _modelOf(target);
    return [
      for (final option in chatModelOptions(
        _ref.read(playgroundModelsProvider),
        agentInstalled: _ref.read(anyAgentInstalledProvider),
      ))
        if (option.modality == PlaygroundModality.text &&
            agentSupportsModel(agent, option.id))
          (
            label: '${option.label}${option.id == current ? ' ✓' : ''}',
            value: option.id,
          ),
    ];
  }

  /// Point [target] at [model]: the Grid chat itself once it has started,
  /// else its draft — and a Telegram chat with no chat yet gets a new one.
  Future<void> _setModel(int chatId, String? target, String model) async {
    if (target == null) {
      await _threads.startNew(chatId, model: model);
      return;
    }
    if (_chat(target) == null) return _threads.setDraftModel(target, model);
    _ref.read(chatSessionsProvider.notifier).setChatModel(target, model);
  }
}
