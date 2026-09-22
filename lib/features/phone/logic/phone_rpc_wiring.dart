/// The seam where a phone's call reaches the running app.
///
/// [MobileRpcService] stays Flutter-free so it can be read and reasoned about on
/// its own, which means somebody has to hand it the parts that only exist inside
/// a window: which grid is open, which chat is streaming, what happens when a
/// message arrives. That is this file, and it is deliberately nothing else —
/// every closure here is one line delegating to the feature that owns the
/// answer.
library;

import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/grid_paths.dart';
import '../../../infrastructure/pairing_host/mobile_rpc_service.dart';
import '../../../infrastructure/pairing_host/mobile_upload_store.dart';
import '../../auth/logic/session_controller.dart';
import 'phone_chat_options.dart';
import 'phone_grid_overview.dart';
import 'phone_projects.dart';
import 'phone_turns.dart';

/// The service that answers a paired phone, wired to this app.
MobileRpcService buildPhoneRpcService(Ref ref, {required String appVersion}) =>
    MobileRpcService(
      hostName: Platform.localHostname,
      appVersion: appVersion,
      // Which grid the computer is actually working in.
      gridIsCurrent: (gridId) =>
          ref.read(selectedNetworkProvider)?.networkId == gridId,
      // The grid's live state, fetched here because the token that authorises
      // it lives on this side and must stay here.
      readOverview: (gridId) => phoneGridOverview(ref, gridId),
      sendToChat: (chatId, text, files) =>
          startPhoneTurn(ref, chatId: chatId, text: text, files: files),
      chatIsBusy: (chatId) => phoneChatIsBusy(ref, chatId),
      chatStreaming: (chatId) => phoneChatStreaming(ref, chatId),
      readOptions: (chatId) => phoneChatOptions(ref, chatId),
      setOption: (chatId, field, value) =>
          setPhoneChatOption(ref, chatId: chatId, field: field, value: value),
      createProject: (name) => createPhoneProject(ref, name),
      createChat: (text, projectId, files) =>
          startPhoneChat(ref, text: text, projectId: projectId, files: files),
      // Under the grid home, beside the other app-owned state, so it is cleared
      // by the same hand that clears everything else.
      uploads: MobileUploadStore(
        directory: Directory('${GridPaths.home.path}/app/phone-uploads'),
      ),
    );
