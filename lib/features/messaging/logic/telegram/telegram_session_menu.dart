part of 'telegram_sessions.dart';

/// The newest this many chats of a place are listed; older ones stay in Grid's
/// own sidebar.
const int _kListedChats = 50;

const String _kPlacesText =
    '<b>Where do you want to work?</b>\n'
    'A project, or the chats that belong to none.';

const _Place _kPlainChats = (projectId: null, name: 'Chats (no project)');

/// `/sessions` and `/new`: pick a project or the plain chats, then a chat.
mixin _SessionMenu on _MenuBase {
  /// `/sessions`: where to work — a project, or the plain chats.
  Future<void> sessions(int chatId) async {
    if (turns.busy(chatId)) return _busy(chatId, 'switch chats');
    await _ref.read(chatSessionsProvider.notifier).restored;
    final id = _nextMenu++;
    final messageId = await _open(
      chatId,
      _kPlacesText,
      _placeRows(id, chatId, 0),
    );
    _menus[chatId] = _Places(id, messageId, _places());
  }

  /// `/new`: a new chat where the current one is — its project, or none.
  Future<void> fresh(int chatId) async {
    final place = _placeOf(chatId);
    await _threads.startNew(chatId, projectId: place.projectId);
    await _api.sendMessage(
      chatId,
      '<b>New chat ready</b> in ${telegramEscape(place.name)}. It starts with '
      'your next message — /sessions to pick another project.',
      html: true,
    );
  }

  Future<void> _onPlacesTap(int chatId, _Places menu, TelegramMenuTap tap) =>
      switch (tap) {
        TelegramPickTap(:final index) when index < menu.places.length =>
          _showChats(chatId, menu.messageId, menu.places[index], 0),
        TelegramPageTap(:final page) => _showPlaces(
          chatId,
          menu.messageId,
          page,
        ),
        _ => Future.value(),
      };

  Future<void> _onChatsTap(int chatId, _Chats menu, TelegramMenuTap tap) async {
    switch (tap) {
      case TelegramPickTap(:final index) when index < menu.chats.length:
        final picked = menu.chats[index];
        await _threads.point(chatId, picked);
        return _finish(
          chatId,
          menu,
          '<b>Switched chat.</b>\n\n${_info(picked)}',
        );
      case TelegramNewHereTap():
        await _threads.startNew(chatId, projectId: menu.place.projectId);
        return _finish(
          chatId,
          menu,
          '<b>New chat ready</b> in ${telegramEscape(menu.place.name)}. It '
          'starts with your next message.',
        );
      case TelegramPageTap(:final page):
        return _showChats(chatId, menu.messageId, menu.place, page);
      case TelegramBackTap():
        return _showPlaces(chatId, menu.messageId, 0);
      default:
        return;
    }
  }

  List<_Place> _places() => [
    _kPlainChats,
    for (final project in _ref.read(sortedProjectsProvider))
      (projectId: project.id, name: project.name),
  ];

  Future<void> _showPlaces(int chatId, int messageId, int page) {
    final id = _nextMenu++;
    return _redraw(
      chatId,
      _Places(id, messageId, _places()),
      _kPlacesText,
      _placeRows(id, chatId, page),
    );
  }

  /// One row per place — `📂` on the one this Telegram chat is in — with how
  /// many chats it holds.
  TelegramKeyboard _placeRows(int menu, int chatId, int page) {
    final here = _placeOf(chatId).projectId;
    String mark(_Place place) => place.projectId == null
        ? '💬'
        : (place.projectId == here ? '📂' : '📁');
    return telegramMenuRows(
      menu: menu,
      page: page,
      items: [
        for (final place in _places())
          (
            label:
                '${mark(place)} ${telegramTrim(place.name, 28)} · '
                '${_chatsIn(place.projectId).length}',
            value: place.projectId ?? '',
          ),
      ],
    );
  }

  Future<void> _showChats(int chatId, int messageId, _Place place, int page) {
    final chats = _chatsIn(place.projectId);
    final current = _threads.current(chatId);
    final now = DateTime.now();
    final id = _nextMenu++;
    TelegramButton button(String label, TelegramMenuTap tap) =>
        (label: label, data: encodeTelegramMenuTap(tap));
    final rows = telegramMenuRows(
      menu: id,
      page: page,
      items: [
        for (final chat in chats)
          (
            label: telegramSessionLabel(
              title: chat.title,
              updatedAt: chat.updatedAt,
              now: now,
              current: chat.id == current,
            ),
            value: chat.id,
          ),
      ],
      top: [
        [button('➕ New chat here', TelegramNewHereTap(id))],
      ],
      bottom: [
        [button('⬅️ All projects', TelegramBackTap(id))],
      ],
    );
    return _redraw(
      chatId,
      _Chats(id, messageId, place, [for (final chat in chats) chat.id]),
      '<b>${telegramEscape(place.name)}</b>\n'
      '${chats.isEmpty ? 'No chats here yet.' : 'Tap one to carry it on.'}',
      rows,
    );
  }

  /// Chats in [projectId] (null: outside every project) a phone can carry on,
  /// pinned first then newest — the sidebar's order.
  List<Conversation> _chatsIn(String? projectId) => [
    for (final chat in _ref.read(chatSessionsProvider).live)
      if (chat.projectId == projectId && telegramCanContinue(chat)) chat,
  ].take(_kListedChats).toList();

  /// Where Telegram chat [chatId] is working now.
  _Place _placeOf(int chatId) {
    final project = _ref.read(
      projectByIdProvider(_projectOf(_threads.current(chatId))),
    );
    if (project == null) return _kPlainChats;
    return (projectId: project.id, name: project.name);
  }

  /// Chat [id] as a switch confirms it: its title, where it lives, and what
  /// answers it.
  String _info(String id) {
    final project = _ref.read(projectByIdProvider(_projectOf(id)));
    return '<b>${telegramEscape(_chat(id)?.title ?? 'Chat')}</b>\n'
        'Project: ${telegramEscape(project?.name ?? 'none')}\n'
        'Assistant: ${_agentOf(id).name}\n'
        'Model: <code>${telegramEscape(_modelOf(id))}</code>';
  }
}
