import 'dart:async';

import 'backend_types.dart';
import 'mobile_chat_backend.dart';
/// A scripted, no-network [MobileChatBackend] for contract and widget tests.
///
/// It honours the contract: `watch` emits snapshot → batch (cursor, itemId)
/// → end; `send` on a non-writable row throws `notWritable`; any operation
/// whose capability is absent throws `notSupported`.
class FakeMobileChatBackend implements MobileChatBackend {
  FakeMobileChatBackend({
    this.capabilities = const {},
    this.rows = const [],
    this.scripted = false,
  });

  final Set<ChatCapability> capabilities;
  final List<ConversationSummary> rows;

  /// When true, `watch` emits the full scripted snapshot→batch→end sequence.
  final bool scripted;

  final _signals = StreamController<ConnectionSignal>.broadcast();
  int _fence = 0;

  @override
  Stream<ConnectionSignal> get connectionState => _signals.stream;

  /// Pushes a connection signal onto [connectionState] (test helper).
  void emitSignal(ConnectionSignalKind kind, {String? detail}) {
    if (!_signals.isClosed) _signals.add(ConnectionSignal(kind, detail: detail));
  }

  ConversationSummary? _row(String id) {
    for (final r in rows) {
      if (r.id == id) return r;
    }
    return null;
  }

  void _requireCap(ChatCapability cap) {
    if (!capabilities.contains(cap)) {
      throw MobileBackendException('notSupported', '${cap.name} is not supported');
    }
  }

  void _require(String id, ChatCapability cap) {
    // Writability outranks capability: a read-only row refuses even a
    // supported operation.
    final row = _row(id);
    if (row != null && !row.writable) {
      throw MobileBackendException('notWritable', '$id is a read-only history row');
    }
    _requireCap(cap);
  }

  @override
  Future<List<ConversationSummary>> listConversations() async => List.unmodifiable(rows);

  @override
  Future<ConversationSummary> openConversation(String id) async {
    final row = _row(id);
    if (row == null) throw MobileBackendException('notFound', '$id');
    return row;
  }

  @override
  Future<ChatHistoryPage> history(String id, {required int throughSeq, int? beforeSeq}) async {
    _require(id, ChatCapability.historyPaging);
    return const ChatHistoryPage([], false);
  }

  @override
  Stream<ChatEvent> watch(String id, {int? fromSeq}) {
    if (!scripted) {
      return const Stream<ChatEvent>.empty();
    }
    return Stream<ChatEvent>.fromIterable([
      const ChatEvent(ChatEventKind.snapshot, [
        ChatMessage(
          seq: 1,
          itemId: 'item-1',
          role: 'user',
          blocks: [ChatBlock.text('hello')],
        ),
      ]),
      ChatEvent(
        ChatEventKind.batch,
        [
          ChatMessage(
            seq: 2,
            itemId: 'item-2',
            role: 'assistant',
            blocks: [ChatBlock.text('hi')],
          ),
        ],
        cursor: 2,
      ),
      const ChatEvent(ChatEventKind.end, []),
    ]);
  }

  @override
  Future<({String sessionId, int fence})> createSession({
    required String agent,
    String? sessionId,
    String? worktreeId,
    String? firstMessage,
  }) async {
    _requireCap(ChatCapability.createWithFirstMessage);
    _fence++;
    return (sessionId: sessionId ?? 'fake-${_fence}', fence: _fence);
  }

  @override
  Future<void> send(String id, String text) async {
    _require(id, ChatCapability.send);
  }

  @override
  Future<void> cancel(String id) async => _require(id, ChatCapability.cancel);

  @override
  Future<void> queueAdd(String id, String text) async => _require(id, ChatCapability.queue);

  @override
  Future<void> queueAction(String id, String itemId, QueueAction action) async =>
      _require(id, ChatCapability.queue);

  @override
  Future<void> respondApproval(String id, String eventId, ApprovalDecision decision) async =>
      _require(id, ChatCapability.approval);

  @override
  Future<void> respondQuestion(String id, String eventId, String answer) async =>
      _require(id, ChatCapability.question);

  @override
  Future<List<ModelInfo>> modelCatalog() async {
    _requireCap(ChatCapability.modelCatalog);
    return const [ModelInfo(id: 'm1', label: 'Model 1')];
  }

  @override
  Future<String> setModel(String id, String modelId) async {
    _require(id, ChatCapability.setModel);
    return modelId;
  }

  @override
  Future<void> close() async {
    await _signals.close();
  }
}
