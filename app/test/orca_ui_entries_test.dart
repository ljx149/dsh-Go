import 'package:dsh_app/remote/orca/orca_backend_selection.dart';
import 'package:dsh_app/state/connection_state.dart';
import 'package:dsh_app/state/hosts_state.dart';
import 'package:dsh_app/state/sessions_state.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:orca_client/orca_client.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_platform_interface.dart';

import 'chat/support/harness.dart' show fakeConnection;

class _Host extends ActiveHostController {
  _Host(this.initial);
  final HostRef initial;

  @override
  HostRef build() => initial;

  @override
  void select(HostRef host) {
    final changed = host != state;
    state = host;
    if (changed) ref.read(currentSessionProvider.notifier).select(null);
  }
}

class _OrcaBackend implements MobileChatBackend {
  @override
  Set<ChatCapability> get capabilities => const {
        ChatCapability.send,
        ChatCapability.historyPaging,
      };

  @override
  Stream<ConnectionSignal> get connectionState => const Stream<ConnectionSignal>.empty();

  @override
  Future<List<ConversationSummary>> listConversations() async => const [];

  @override
  Future<ConversationSummary> openConversation(String id) async =>
      throw MobileBackendException('notFound', id);

  @override
  Future<ChatHistoryPage> history(String id, {required int throughSeq, int? beforeSeq}) async =>
      const ChatHistoryPage([], false);

  @override
  Stream<ChatEvent> watch(String id, {int? fromSeq}) => const Stream<ChatEvent>.empty();

  @override
  Future<({String sessionId, int fence})> createSession({
    required String agent,
    String? sessionId,
    String? worktreeId,
    String? firstMessage,
  }) async => (sessionId: 'x', fence: 0);

  @override
  Future<void> send(String id, String text) async {}
  @override
  Future<void> cancel(String id) async {}
  @override
  Future<void> queueAdd(String id, String text) async {}
  @override
  Future<void> queueAction(String id, String itemId, QueueAction action) async {}
  @override
  Future<void> respondApproval(String id, String eventId, ApprovalDecision decision) async {}
  @override
  Future<void> respondQuestion(String id, String eventId, String answer) async {}
  @override
  Future<List<ModelInfo>> modelCatalog() async => const [];
  @override
  Future<String> setModel(String id, String modelId) async => modelId;
  @override
  Future<void> close() async {}
}

/// A stand-in for the Orca transport (the [OrcaRpc] the connect factory yields).
class _OrcaRpc implements OrcaRpc {
  @override
  Future<Map<String, dynamic>> request(String method, Map<String, dynamic> params) async =>
      {'ok': true, 'value': <String, dynamic>{}};

  @override
  Stream<Map<String, dynamic>> subscribe(String sessionId, {Map<String, dynamic>? cursor}) =>
      const Stream<Map<String, dynamic>>.empty();

  @override
  Future<void> close() async {}
}

void main() {
  late SharedPreferencesStorePlatform previous;

  setUp(() {
    previous = SharedPreferencesStorePlatform.instance;
    SharedPreferencesStorePlatform.instance = InMemorySharedPreferencesStore.empty();
  });
  tearDown(() => SharedPreferencesStorePlatform.instance = previous);

  test('切换主机时聊天回到“新对话”，不串会话', () {
    final container = ProviderContainer(overrides: [
      activeHostProvider.overrideWith(() => _Host(HostRef.local)),
      activeConnectionProvider.overrideWithValue(AsyncData<HostConnection?>(fakeConnection)),
    ]);
    addTearDown(container.dispose);
    // Open a session on 本机.
    container.read(currentSessionProvider.notifier).select('s-old-host');
    expect(container.read(currentSessionProvider), 's-old-host');
    // Switch to orca: the open conversation belongs to the old host.
    container.read(activeHostProvider.notifier).select(HostRef.orca('o1'));
    expect(container.read(currentSessionProvider), isNull);
  });

  test('orca 主机的会话列表为空态，不残留 DSH 会话', () {
    final container = ProviderContainer(overrides: [
      activeHostProvider.overrideWith(() => _Host(HostRef.orca('o1'))),
      orcaBackendConnectProvider.overrideWithValue(() async => _OrcaRpc()),
    ]);
    addTearDown(container.dispose);
    final backend = container.read(mobileChatBackendProvider);
    expect(backend, isA<OrcaMobileBackend>());
    // The orca backend owns the conversation list; on this host there are no
    // sessions yet, so the drawer shows the orca empty state, not the DSH one.
    expect(backend.capabilities, isNot(contains(ChatCapability.mux)));
    expect(backend.capabilities, isNot(contains(ChatCapability.subagentRouting)));
  });
}
