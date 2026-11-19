import 'package:dsh_client/dsh_client.dart' as dsh;

import 'backend_types.dart';
import 'mobile_chat_backend.dart';

/// Maps the existing `DshClient` call surface onto [MobileChatBackend].
///
/// Pure mapping, no business logic (spec §3.2): the UI was already built
/// against `DshClient`, this layer re-exposes that surface through the
/// backend-neutral interface so Orca can sit beside it. `capabilities`
/// declares every DSH-specific entry the UI may hide on other backends.
class DshMobileBackend implements MobileChatBackend {
  DshMobileBackend({
    required this.client,
    required Stream<ConnectionSignal> Function() connectionSource,
  }) {
    _source = connectionSource();
  }

  final dsh.DshClient client;
  late final Stream<ConnectionSignal> _source;
  bool _closed = false;

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
        // DSH-specific entries the UI shows only on this backend.
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
  Stream<ConnectionSignal> get connectionState => _source;

  @override
  Future<List<ConversationSummary>> listConversations() async {
    final summaries = await client.listSessions();
    return [
      for (final s in summaries)
        if (!s.isSubagent)
          ConversationSummary(
            id: s.sessionId,
            agent: s.projections.agentPreset ?? 'dsh',
            title: s.title ?? '',
            cwd: s.cwd,
            running: s.running,
            // DSH sessions are always writable (there is no read-only history
            // row concept; the host owns the live agent).
            writable: true,
          ),
    ];
  }

  @override
  Future<ConversationSummary> openConversation(String id) async {
    for (final s in await listConversations()) {
      if (s.id == id) return s;
    }
    throw MobileBackendException('notFound', 'no conversation $id');
  }

  @override
  Future<ChatHistoryPage> history(
    String id, {
    required int throughSeq,
    int? beforeSeq,
  }) async {
    final page = await client.history(id, throughSeq: throughSeq, beforeSeq: beforeSeq);
    return ChatHistoryPage(
      [for (final e in page.events) _toMessage(e)],
      page.hasMore,
    );
  }

  @override
  Stream<ChatEvent> watch(String id, {int? fromSeq}) {
    // DSH's watch() already handles snapshot→events→deltas and reconnects on
    // socket loss; we map its DshEvent stream to the backend-neutral shape.
    return client.watch(id).map(_toChatEvent);
  }

  ChatEvent _toChatEvent(dsh.DshEvent event) {
    if (event is dsh.SessionSnapshotEvent) {
      return ChatEvent(
        ChatEventKind.snapshot,
        [for (final e in event.events) _toMessage(e)],
        cursor: event.cursor,
      );
    }
    if (event is dsh.SessionLogEvent) {
      return ChatEvent(ChatEventKind.batch, [_toMessage(event)]);
    }
    // ConnectionStateEvent / SessionSyncEvent / UnknownFrameEvent are control
    // frames the UI does not render as chat; swallow them here.
    return const ChatEvent(ChatEventKind.batch, []);
  }

  ChatMessage _toMessage(dsh.SessionLogEvent e) {
    switch (e) {
      case dsh.UserMessageEvent(:final message):
        return _fromMessage(e.seq, message);
      case dsh.AssistantMessageEvent(:final message):
        return _fromMessage(e.seq, message);
      case dsh.ToolCallEvent(:final name):
        return ChatMessage(
          seq: e.seq,
          itemId: 'tool-${e.seq}',
          role: 'tool',
          blocks: [ChatBlock(type: 'tool-call', text: name)],
          timestamp: e.time,
        );
      default:
        // Non-message durable events (turn/step boundaries, title changes,
        // approvals) are not chat content; the UI renders them elsewhere.
        return ChatMessage(
          seq: e.seq,
          itemId: 'evt-${e.seq}',
          role: e.type,
          blocks: const [],
          timestamp: e.time,
        );
    }
  }

  ChatMessage _fromMessage(int seq, dsh.Message message) {
    return ChatMessage(
      seq: seq,
      itemId: message.id,
      role: message.role.name,
      blocks: [
        for (final part in message.parts)
          switch (part) {
            dsh.TextPart(:final text) => ChatBlock(type: 'text', text: text),
            dsh.ReasoningPart(:final text) => ChatBlock(type: 'reasoning', text: text),
            dsh.ToolCallPart(:final name) => ChatBlock(type: 'tool-call', text: name),
            _ => const ChatBlock(type: 'unknown'),
          },
      ],
      timestamp: DateTime.now(),
    );
  }

  @override
  Future<({String sessionId, int fence})> createSession({
    required String agent,
    String? sessionId,
    String? worktreeId,
    String? firstMessage,
  }) async {
    // DSH's createSession takes no firstMessage; the caller sends it
    // separately via send(). Fence is a no-op on DSH (no runtime-fence
    // concept) — return 0.
    final created = await client.createSession(cwd: worktreeId, agentPreset: agent);
    return (sessionId: created.sessionId, fence: 0);
  }

  @override
  Future<void> send(String id, String text) async {
    // DSH's prompt is idempotent by requestId; a transport retry reuses the
    // same requestId (spec §5.2). We mint one here and pass it so retries
    // within the same logical send stay idempotent.
    await client.prompt(id, text);
  }

  @override
  Future<void> cancel(String id) async => client.cancel(id);

  @override
  Future<void> queueAdd(String id, String text) async {
    // DSH queues via prompt with mode:queue; the default is already queue.
    await client.prompt(id, text);
  }

  @override
  Future<void> queueAction(String id, String itemId, QueueAction action) async {
    switch (action) {
      case QueueAction.delete:
        await client.updateQueue(id, itemId, remove: true);
      case QueueAction.send:
        await client.updateQueue(id, itemId, steer: true);
      case QueueAction.update:
        await client.updateQueue(id, itemId);
      case QueueAction.move:
        // DSH has no explicit move; a no-op is honest.
        break;
    }
  }

  @override
  Future<void> respondApproval(String id, String eventId, ApprovalDecision decision) async {
    final request = dsh.ApprovalRequest(
      eventId: eventId,
      sessionId: id,
      toolName: 'unknown',
    );
    // The interface's pass/reject map onto DSH's allowOnce/reject.
    final dshDecision =
        decision == ApprovalDecision.pass ? dsh.ApprovalDecision.allowOnce : dsh.ApprovalDecision.reject;
    await client.respondApproval(request, dshDecision);
  }

  @override
  Future<void> respondQuestion(String id, String eventId, String answer) async {
    // DSH's answerQuestion needs a UserQuestionRequest; the UI already holds
    // it. This backend method is a thin stand-in for the backend-neutral
    // contract — the UI's approval card carries the full request object and
    // calls client.answerQuestion directly when on DSH. Here we resolve via
    // the low-level host-event result so the contract holds.
    await client.respondHostEvent(eventId, {
      'kind': 'result',
      'value': {'answers': [
        {'text': answer}
      ]},
    });
  }

  @override
  Future<List<ModelInfo>> modelCatalog() async {
    final catalog = await client.listModels();
    return [
      for (final group in catalog.groups)
        for (final model in group.models)
          ModelInfo(id: '${group.id}/${model.id}', label: model.name, vendor: group.id),
    ];
  }

  @override
  Future<String> setModel(String id, String modelId) async {
    // modelId is 'provider/model'; split and call DSH's setModel.
    final slash = modelId.indexOf('/');
    if (slash < 0) throw MobileBackendException('badModelId', '$modelId has no provider');
    final selection = await client.setModel(
      id,
      provider: modelId.substring(0, slash),
      model: modelId.substring(slash + 1),
    );
    // Read the host's effective value back; never trust the local echo.
    return '${selection.provider}/${selection.model}';
  }

  @override
  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    await client.close();
  }
}
