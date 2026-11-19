import 'backend_types.dart';

/// The backend-neutral contract for mobile chat (spec §3.2). DSH and Orca
/// each implement it; the UI consumes only this surface.
abstract interface class MobileChatBackend {
  Set<ChatCapability> get capabilities;

  Stream<ConnectionSignal> get connectionState;

  Future<List<ConversationSummary>> listConversations();

  /// Opens [id] and returns its row, so the UI immediately knows writability
  /// and agent identity (spec §3.3).
  Future<ConversationSummary> openConversation(String id);

  Future<ChatHistoryPage> history(String id, {required int throughSeq, int? beforeSeq});

  /// snapshot → batch (cursor) → end (spec §5.1).
  Stream<ChatEvent> watch(String id, {int? fromSeq});

  /// The host assigns the fence; `null` fence on create (spec §5.2/§6).
  ///
  /// When [sessionId] is null the implementation mints one; callers that need
  /// to address the session before the response (e.g. to open it) pass their
  /// own id.
  Future<({String sessionId, int fence})> createSession({
    required String agent,
    String? sessionId,
    String? worktreeId,
    String? firstMessage,
  });

  /// Operation identity is managed by the implementation; callers never see
  /// it (spec §5.2).
  Future<void> send(String id, String text);

  Future<void> cancel(String id);

  Future<void> queueAdd(String id, String text);

  Future<void> queueAction(String id, String itemId, QueueAction action);

  Future<void> respondApproval(String id, String eventId, ApprovalDecision decision);

  Future<void> respondQuestion(String id, String eventId, String answer);

  Future<List<ModelInfo>> modelCatalog();

  /// Returns the host-read-back value actually in effect (spec §5.5).
  Future<String> setModel(String id, String modelId);

  Future<void> close();
}
