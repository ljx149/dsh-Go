import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../state/connection_state.dart';
import '../../state/hosts_state.dart';
import 'orca_host_config.dart';
import 'package:orca_client/orca_client.dart';

/// Builds the [OrcaRpc] for the active orca host: reads its saved endpoint +
/// pairing code, connects the legacy E2EE socket. Extracted so tests can
/// override it with a scripted rpc (no real socket, no prefs).
final orcaBackendConnectProvider = Provider<Future<OrcaRpc> Function()>((ref) {
  final host = ref.watch(activeHostProvider);
  return () async {
    final notifier = ref.read(orcaHostsProvider.notifier);
    await notifier.ready;
    final config = await notifier.load(host.id);
    if (config == null || config.pairingCode == null) {
      throw MobileBackendException('notFound', 'no orca host ${host.id}');
    }
    return LegacyOrcaClient.connect(Uri.parse(config.endpoint), config.pairingCode!);
  };
});

/// The UI's single entry to a chat backend (spec §3.2). The active host
/// decides which backend: an Orca host gets an [OrcaMobileBackend] that owns
/// its own socket (closed on switch); local/ssh/relay wrap the shared
/// [DshClient] in a [DshMobileBackend] that does not close the client — the
/// connection providers own that lifecycle. DSH connection state is surfaced
/// by the existing providers, not by the backend, so its [connectionState]
/// stream is empty.
final mobileChatBackendProvider = Provider<MobileChatBackend>((ref) {
  final host = ref.watch(activeHostProvider);
  if (host.kind == HostKind.orca) {
    final backend = OrcaMobileBackend(connect: ref.watch(orcaBackendConnectProvider));
    ref.onDispose(() => unawaited(backend.close()));
    return backend;
  }
  final connection = ref.watch(activeConnectionProvider).value;
  final client = connection?.client;
  if (client == null) return _PendingDshBackend();
  return DshMobileBackend(
    client: client,
    connectionSource: () => const Stream<ConnectionSignal>.empty(),
  );
});

/// A backend placeholder while the DSH connection is still loading; every
/// call throws `notReady` so the UI can't act on a half-connected session.
/// Its [capabilities] already advertise DSH's surface so the UI can show the
/// right affordances even before the socket is up.
class _PendingDshBackend implements MobileChatBackend {
  @override
  Set<ChatCapability> get capabilities => const {
        ChatCapability.historyPaging,
        ChatCapability.createWithFirstMessage,
        ChatCapability.send,
        ChatCapability.cancel,
        ChatCapability.queue,
        ChatCapability.approval,
        ChatCapability.question,
        ChatCapability.modelCatalog,
        ChatCapability.setModel,
        ChatCapability.rename,
        ChatCapability.archive,
        ChatCapability.worktreeList,
        ChatCapability.subagentRouting,
        ChatCapability.terminalSession,
        ChatCapability.mux,
        ChatCapability.pluginEvents,
        ChatCapability.lifecycleStatus,
        ChatCapability.logExport,
        ChatCapability.transcribe,
        ChatCapability.fileUpload,
        ChatCapability.bundleList,
      };

  @override
  Stream<ConnectionSignal> get connectionState => const Stream<ConnectionSignal>.empty();

  Future<T> _throw<T>() async =>
      throw MobileBackendException('notReady', 'DSH connection not ready');

  @override
  Future<List<ConversationSummary>> listConversations() => _throw();
  @override
  Future<ConversationSummary> openConversation(String id) => _throw();
  @override
  Future<ChatHistoryPage> history(String id, {required int throughSeq, int? beforeSeq}) =>
      _throw();
  @override
  Stream<ChatEvent> watch(String id, {int? fromSeq}) =>
      Stream.error(MobileBackendException('notReady', 'DSH connection not ready'));
  @override
  Future<({String sessionId, int fence})> createSession({
    required String agent,
    String? sessionId,
    String? worktreeId,
    String? firstMessage,
  }) => _throw();
  @override
  Future<void> send(String id, String text) => _throw();
  @override
  Future<void> cancel(String id) => _throw();
  @override
  Future<void> queueAdd(String id, String text) => _throw();
  @override
  Future<void> queueAction(String id, String itemId, QueueAction action) => _throw();
  @override
  Future<void> respondApproval(String id, String eventId, ApprovalDecision decision) => _throw();
  @override
  Future<void> respondQuestion(String id, String eventId, String answer) => _throw();
  @override
  Future<List<ModelInfo>> modelCatalog() => _throw();
  @override
  Future<String> setModel(String id, String modelId) => _throw();
  @override
  Future<void> close() async {}
}
