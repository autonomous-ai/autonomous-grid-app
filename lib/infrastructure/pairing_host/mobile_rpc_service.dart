/// What a paired phone is allowed to ask this computer, and what it gets back.
///
/// **Every reply is a projection, and the projection is built by reading only
/// the fields it may send.** `~/.grid/credentials.toml` holds `access_token`
/// and `refresh_token` for every grid — bearer credentials for the whole thing.
/// The app's own [GridHomeStore] parses the file completely, which is right for
/// the app and wrong here: a value this code never holds is a value it cannot
/// leak through a logging change or a careless `toJson`. So this reads the four
/// fields a phone needs and stops.
///
/// That also keeps this class free of Flutter, which is what lets it be read,
/// reasoned about and tested without a window behind it — everything it needs
/// from the running app arrives as a closure (`phone_rpc_wiring.dart`).
library;

import 'dart:io';

import 'package:grid_pairing/grid_pairing.dart';
import 'package:toml/toml.dart';

import '../../core/grid_paths.dart';
import 'mobile_chat_reader.dart';
import 'mobile_chat_rpc.dart';
import 'mobile_grid_reader.dart';
import 'mobile_upload_store.dart';

/// One grid, as much of it as a phone is shown.
typedef GridSummary = ({String id, String name, String type, String email});

/// Answers the phone's calls.
class MobileRpcService {
  MobileRpcService({
    required this.hostName,
    required this.appVersion,
    List<GridSummary> Function()? readGrids,
    List<GridEngine> Function(String gridId)? readEngines,
    bool Function(String gridId)? gridIsCurrent,
    Future<Map<String, Object?>?> Function(String gridId)? readOverview,
    List<ChatHeader> Function()? readChats,
    List<ProjectSummary> Function()? readProjects,
    ChatPage? Function(String id, {int? limit, int? offset})? readChat,
    Future<String?> Function(
      String chatId,
      String text,
      List<PhoneAttachment> files,
    )?
    sendToChat,
    bool Function(String chatId)? chatIsBusy,
    String Function(String chatId)? chatStreaming,
    Future<Map<String, Object?>> Function(String chatId)? readOptions,
    Future<String?> Function(String chatId, String field, String value)?
    setOption,
    Future<({String? id, String? problem})> Function(
      String text,
      String? projectId,
      List<PhoneAttachment> files,
    )?
    createChat,
    ({String? id, String? problem}) Function(String name)? createProject,
    MobileUploadStore? uploads,
  }) : _readGrids = readGrids ?? readGridSummaries,
       _readEngines = readEngines ?? readGridEngines,
       _gridIsCurrent = gridIsCurrent,
       _chats = MobileChatRpc(
         readChats: readChats,
         readProjects: readProjects,
         readChat: readChat,
         sendToChat: sendToChat,
         chatIsBusy: chatIsBusy,
         chatStreaming: chatStreaming,
         readOptions: readOptions,
         setOption: setOption,
         createChat: createChat,
         createProject: createProject,
         uploads: uploads,
       ),
       _readOverview = readOverview;

  /// What this computer calls itself on the phone's screen.
  final String hostName;

  /// So the phone can say "update Grid on your computer" rather than failing
  /// at a method the desktop is too old to have.
  final String appVersion;

  final List<GridSummary> Function() _readGrids;
  final List<GridEngine> Function(String gridId) _readEngines;

  /// Whether a grid is the one the computer is working in, or null on a host
  /// with no window behind it to ask.
  final bool Function(String gridId)? _gridIsCurrent;

  /// The grid's live state from its relay — models, machines, pooled hardware —
  /// already projected to what a phone may see, or null on a host that cannot
  /// ask (no window behind it) or a relay that would not answer.
  ///
  /// A closure for the same reason [_gridIsCurrent] is: the call needs that
  /// grid's access token and the app's HTTP client, and this class holds
  /// neither. It reads four fields of `credentials.toml` and stops, which is
  /// what keeps a token it never holds out of anything it sends.
  final Future<Map<String, Object?>?> Function(String gridId)? _readOverview;
  final MobileChatRpc _chats;

  /// The reply to [request].
  ///
  /// Which phone is asking comes from the channel, never from the request: a
  /// caller that could name itself could name somebody else. Nothing here needs
  /// that name any more — what it needs is the one thing the channel decides.
  ///
  /// [mayAct] is asked only by the methods that make this computer do
  /// something, and asked *per call* rather than once per session: revoking a
  /// phone's permission at the computer has to reach a phone that is connected
  /// right now, not the next time it dials in.
  ///
  /// Null means no, which is what makes the default safe. A caller that has not
  /// thought about the question has not granted anything.
  Future<MobileRpcResponse> handle(
    MobileRpcRequest request, {
    Future<bool> Function()? mayAct,
  }) async {
    // Checked before the method is looked at, so an unknown name and a
    // known-but-forbidden one are answered identically.
    if (!kMobileRpcMethods.contains(request.method)) {
      return MobileRpcFailed(
        request.id,
        code: 'forbidden',
        message: 'This phone cannot call ${request.method}.',
      );
    }
    try {
      return switch (request.method) {
        'status.get' => MobileRpcOk(request.id, _status()),
        'grids.list' => MobileRpcOk(request.id, _grids()),
        'grids.get' => await _grid(request),
        'projects.list' => MobileRpcOk(request.id, _chats.projects()),
        'chats.list' => MobileRpcOk(request.id, _chats.list()),
        'chats.get' => _chats.page(request),
        'chats.head' => _chats.head(request),
        'chats.media' => _chats.media(request),
        'chats.send' => await _chats.send(request, mayAct),
        'chats.options' => await _chats.options(request),
        'chats.set' => await _chats.set(request, mayAct),
        'chats.create' => await _chats.create(request, mayAct),
        'projects.create' => await _chats.newProject(request, mayAct),
        'uploads.begin' => await _chats.beginUpload(request, mayAct),
        'uploads.chunk' => await _chats.uploadChunk(request, mayAct),
        _ => MobileRpcFailed(
          request.id,
          code: 'bad_request',
          message: 'Unknown method.',
        ),
      };
    } on Object catch (error) {
      // The phone gets a sentence; the detail stays here. A remote peer should
      // never be handed this computer's exception text.
      stderr.writeln('[pairing-host] ${request.method} failed: $error');
      return MobileRpcFailed(
        request.id,
        code: 'failed',
        message: 'Grid on the computer could not answer that.',
      );
    }
  }

  Map<String, Object?> _status() => {
    'hostName': hostName,
    'platform': Platform.operatingSystem,
    'appVersion': appVersion,
    'gridCount': _readGrids().length,
  };

  /// One grid, and what this computer is doing on it.
  ///
  /// A read, so no switch: it says nothing the list does not already say plus
  /// what is being served, and a phone that could list grids but not open one
  /// is a list of dead rows.
  ///
  /// Two halves, and only one of them can fail. The grid and its engines come
  /// off this computer's disk; the live overview is a call to that grid's relay,
  /// bounded by the client's own deadline and dropped from the reply when it
  /// does not answer.
  Future<MobileRpcResponse> _grid(MobileRpcRequest request) async {
    final id = request.params['id'];
    if (id is! String || id.isEmpty) {
      return MobileRpcFailed(
        request.id,
        code: 'bad_request',
        message: 'Which grid?',
      );
    }
    final grid = _readGrids().where((row) => row.id == id).firstOrNull;
    // Not an empty grid: a phone shown a blank detail for a grid this computer
    // has left would be reading a screen about nothing.
    if (grid == null) {
      return MobileRpcFailed(
        request.id,
        code: 'not_found',
        message: 'Your computer is not signed in to that grid any more.',
      );
    }
    // Omitted rather than sent empty when the relay is unreachable: everything
    // else here is read off this computer's disk and is still true, and the
    // phone draws the live half only when there is one.
    final overview = await _readOverview?.call(grid.id);
    return MobileRpcOk(request.id, {
      'id': grid.id,
      'name': grid.name,
      'type': grid.type,
      'email': grid.email,
      'current': _gridIsCurrent?.call(grid.id) ?? false,
      'engines': [
        for (final engine in _readEngines(grid.id))
          {'id': engine.id, 'models': engine.models, 'running': engine.running},
      ],
      'overview': ?overview,
    });
  }

  Map<String, Object?> _grids() => {
    'grids': [
      for (final grid in _readGrids())
        {
          'id': grid.id,
          'name': grid.name,
          'type': grid.type,
          'email': grid.email,
        },
    ],
  };
}

/// The grids in `~/.grid/credentials.toml`, four fields each.
///
/// An unreadable or absent file reads as no grids rather than throwing: a
/// signed-out computer is a normal state, and the phone's empty list already
/// says so.
List<GridSummary> readGridSummaries() {
  final file = GridPaths.credentialsFile;
  if (!file.existsSync()) return const [];
  final Map<String, dynamic> document;
  try {
    document = TomlDocument.parse(file.readAsStringSync()).toMap();
  } on Object {
    return const [];
  }
  final networks = document['networks'];
  if (networks is! List) return const [];
  return [
    for (final network in networks)
      if (network is Map)
        (
          id: '${network['network_id'] ?? ''}',
          name: '${network['name'] ?? ''}',
          type: '${network['network_type'] ?? ''}',
          email: '${network['email'] ?? ''}',
        ),
  ];
}
