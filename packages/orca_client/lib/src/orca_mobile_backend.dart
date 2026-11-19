import 'dart:async';

import 'backend_types.dart';
import 'legacy_rpc_client.dart';
import 'mobile_chat_backend.dart';
import 'session_mutation.dart';

/// The Orca implementation of [MobileChatBackend] (spec §3.2/§5).
///
/// Wraps an [OrcaRpc] (the real [LegacyOrcaClient] in production, a scripted
/// rpc in tests) and owns the two bookkeeping layers the spec pins:
/// operation identity (a transport retry re-sends the same
/// `clientOperationId` + `payloadFingerprint`, spec §5.2) and the
/// disconnect-recovery state machine (itemId dedupe, fence bookkeeping,
/// spec §5.6).
class OrcaMobileBackend implements MobileChatBackend {
  OrcaMobileBackend({
    required Future<OrcaRpc> Function() connect,
    int retryBudget = 1,
  })  : _connect = connect,
        _retryBudget = retryBudget {
    unawaited(_connectRpc().catchError((Object e) {
      if (!_signals.isClosed) {
        _signals.add(ConnectionSignal(
            ConnectionSignalKind.disconnected, detail: e.toString()));
      }
      if (!_established.isCompleted) _established.completeError(e);
      throw e;
    }));
  }

  final Future<OrcaRpc> Function() _connect;
  final int _retryBudget;
  final _signals = StreamController<ConnectionSignal>.broadcast();
  final _fences = <String, int>{};
  final _delivered = <String, Set<String>>{};
  final _established = Completer<void>();
  OrcaRpc? _rpc;
  bool _closed = false;

  /// Completes when the transport has authenticated (or fails). Tests await
  /// this rather than racing a broadcast [connectionState] stream.
  Future<void> get established => _established.future;

  OrcaRpc get _ensureRpc {
    final rpc = _rpc;
    if (rpc == null || _closed) {
      throw MobileBackendException('transport', 'connection not established',
          retriable: true);
    }
    return rpc;
  }

  Future<OrcaRpc> _connectRpc() async {
    final rpc = await _connect();
    if (_closed) {
      unawaited(rpc.close());
      throw MobileBackendException('transport', 'backend closed', retriable: true);
    }
    _rpc = rpc;
    if (!_signals.isClosed) {
      _signals.add(const ConnectionSignal(ConnectionSignalKind.connected));
    }
    if (!_established.isCompleted) _established.complete();
    return rpc;
  }

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
        ChatCapability.worktreeList,
      };

  @override
  Stream<ConnectionSignal> get connectionState => _signals.stream;

  @override
  Future<List<ConversationSummary>> listConversations() async {
    final value = await _mutation('worktree.list', const {});
    final rows = value['rows'] is List
        ? (value['rows'] as List).cast<Map<String, dynamic>>()
        : const <Map<String, dynamic>>[];
    return [
      for (final row in rows)
        ConversationSummary(
          id: row['structuredSession'] is Map
              ? (row['structuredSession'] as Map)['sessionId']?.toString() ??
                  row['sessionId']?.toString() ??
                  ''
              : row['sessionId']?.toString() ??
                  '',
          agent: row['agent'] is String ? row['agent'] as String : 'unknown',
          title: row['title'] is String ? row['title'] as String : '',
          cwd: row['cwd'] is String ? row['cwd'] as String : null,
          branch: row['branch'] is String ? row['branch'] as String : null,
          model: row['model'] is String ? row['model'] as String : null,
          running: row['running'] == true,
          writable: row['structuredSession'] is Map,
        ),
    ];
  }

  @override
  Future<ConversationSummary> openConversation(String id) async {
    for (final r in await listConversations()) {
      if (r.id == id) return r;
    }
    throw MobileBackendException('notFound', 'no conversation $id');
  }

  @override
  Future<ChatHistoryPage> history(
    String id, {
    required int throughSeq,
    int? beforeSeq,
  }) async {
    final value = await _mutation('agentSession.history', {
      'sessionId': id,
      'throughSeq': throughSeq,
      if (beforeSeq != null) 'beforeSeq': beforeSeq,
    });
    final items = value['items'] is List
        ? (value['items'] as List).cast<Map<String, dynamic>>()
        : const <Map<String, dynamic>>[];
    return ChatHistoryPage(
      [for (final i in items) _toMessage(i)],
      value['hasMore'] == true,
    );
  }

  @override
  Stream<ChatEvent> watch(String id, {int? fromSeq}) {
    return _ensureRpc.subscribe(id, cursor: fromSeq != null ? {'seq': fromSeq} : null).map((raw) {
      final kind = switch (raw['type']) {
        'snapshot' => ChatEventKind.snapshot,
        'batch' => ChatEventKind.batch,
        'end' => ChatEventKind.end,
        _ => ChatEventKind.batch,
      };
      final batch = raw['batch'] is Map ? raw['batch'] as Map : raw;
      final items = batch['items'] is List
          ? (batch['items'] as List).cast<Map<String, dynamic>>()
          : const <Map<String, dynamic>>[];
      final messages = [
        for (final i in items)
          if (_markDelivered(id, i['id'] is String ? i['id'] as String : null)) _toMessage(i),
      ];
      return ChatEvent(kind, messages,
          cursor: raw['cursor'] is int ? raw['cursor'] as int : null);
    });
  }

  /// Records [itemId] as delivered for [id]; false when already seen (spec §5.6 dedupe).
  bool _markDelivered(String id, String? itemId) {
    if (itemId == null || itemId.isEmpty) return true;
    return _delivered.putIfAbsent(id, () => <String>{}).add(itemId);
  }

  @override
  Future<({String sessionId, int fence})> createSession({
    required String agent,
    String? sessionId,
    String? worktreeId,
    String? firstMessage,
  }) async {
    final id = sessionId ?? newClientId();
    final request = createSessionRequest(
      sessionId: id,
      worktree: worktreeId ?? '',
      agent: agent,
      firstMessage: firstMessage,
    );
    final value = await _mutation('agentSession.create', request);
    _fences[id] = value['fence'] is int ? value['fence'] as int : 0;
    return (sessionId: id, fence: _fences[id]!);
  }

  @override
  Future<void> send(String id, String text) async {
    // Operation identity is generated once; a transport retry re-sends this
    // exact frame (same clientOperationId + payloadFingerprint, spec §5.2).
    final request = sendSessionRequest(sessionId: id, text: text, fence: _fences[id] ?? 0);
    for (var attempt = 0; ; attempt++) {
      try {
        await _mutation('agentSession.send', request);
        return;
      } on OrcaTransportFailure {
        if (attempt >= _retryBudget) {
          throw MobileBackendException(
              'transport', 'send failed after $attempt retries', retriable: true);
        }
      }
    }
  }

  @override
  Future<void> cancel(String id) async =>
      _mutation('agentSession.cancel', {'sessionId': id});

  @override
  Future<void> queueAdd(String id, String text) async {
    await _mutation('agentSession.queue', {
      'sessionId': id,
      'body': textMessage(text),
    });
  }

  @override
  Future<void> queueAction(String id, String itemId, QueueAction action) async {
    await _mutation('agentSession.queueAction', {
      'sessionId': id,
      'itemId': itemId,
      'action': action.name,
    });
  }

  @override
  Future<void> respondApproval(String id, String eventId, ApprovalDecision decision) async {
    await _mutation('agentSession.respondToApproval', {
      'sessionId': id,
      'eventId': eventId,
      'decision': decision == ApprovalDecision.pass ? 'pass' : 'reject',
    });
  }

  @override
  Future<void> respondQuestion(String id, String eventId, String answer) async {
    await _mutation('agentSession.respondToQuestion', {
      'sessionId': id,
      'eventId': eventId,
      'answer': answer,
    });
  }

  @override
  Future<List<ModelInfo>> modelCatalog() async {
    final value = await _mutation('agentSession.modelCatalog', const {});
    final models = value['models'] is List
        ? (value['models'] as List).cast<Map<String, dynamic>>()
        : const <Map<String, dynamic>>[];
    return [
      for (final m in models)
        ModelInfo(
          id: m['id'] is String ? m['id'] as String : '',
          label: m['label'] is String ? m['label'] as String : '',
          vendor: m['vendor'] is String ? m['vendor'] as String : null,
        ),
    ];
  }

  @override
  Future<String> setModel(String id, String modelId) async {
    final value = await _mutation('agentSession.setOption', {
      'sessionId': id,
      'model': modelId,
    });
    // Read the host's effective value back; never trust the local echo (spec §5.5).
    return value['model'] is String ? value['model'] as String : modelId;
  }

  @override
  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    final rpc = _rpc;
    _rpc = null;
    if (rpc != null) await rpc.close().catchError((_) => null);
    if (!_established.isCompleted) {
      _established.completeError(const OrcaTransportFailure('backend closed'));
    }
    if (!_signals.isClosed) await _signals.close();
  }

  /// One sealed RPC through the host; resolves to the host's `value` map.
  Future<Map<String, dynamic>> _mutation(String method, Map<String, dynamic> params) async =>
      requireMutationValue(await _ensureRpc.request(method, params));

  ChatMessage _toMessage(Map<String, dynamic> i) {
    final body = i['body'] is Map ? i['body'] as Map : const <String, dynamic>{};
    final blocks = body['blocks'] is List
        ? (body['blocks'] as List).cast<Map<String, dynamic>>()
        : const <Map<String, dynamic>>[];
    return ChatMessage(
      seq: i['seq'] is int ? i['seq'] as int : 0,
      itemId: i['id'] is String ? i['id'] as String : '',
      role: body['role'] is String ? body['role'] as String : '',
      blocks: [
        for (final b in blocks)
          ChatBlock(
            type: b['type'] is String ? b['type'] as String : 'text',
            text: b['text'] is String ? b['text'] as String : null,
          ),
      ],
      timestamp: i['ts'] is int ? DateTime.fromMillisecondsSinceEpoch(i['ts'] as int) : null,
    );
  }
}
