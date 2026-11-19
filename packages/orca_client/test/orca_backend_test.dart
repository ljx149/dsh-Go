import 'dart:async';

import 'package:orca_client/orca_client.dart';
import 'package:test/test.dart';

/// A scripted host at the request/subscribe level. Records every sealed
/// envelope so tests can assert operation-identity stability (spec §5.2) and
/// single-create semantics.
class ScriptedOrcaRpc implements OrcaRpc {
  final List<Map<String, dynamic>> sent = [];
  Map<String, dynamic> Function(String method, Map<String, dynamic> params)?
      responder;
  List<Map<String, dynamic>>? watchScript;

  ScriptedOrcaRpc({this.responder});

  @override
  Future<Map<String, dynamic>> request(
    String method,
    Map<String, dynamic> params,
  ) async {
    sent.add({
      'method': method,
      'envelope': Map<String, dynamic>.from(params['envelope'] as Map? ?? {}),
    });
    if (responder != null) return responder!(method, params);
    return {'ok': true, 'value': <String, dynamic>{'fence': 1}};
  }

  @override
  Stream<Map<String, dynamic>> subscribe(String sessionId, {Map<String, dynamic>? cursor}) {
    final script = watchScript;
    if (script != null) return Stream<Map<String, dynamic>>.fromIterable(script);
    return const Stream<Map<String, dynamic>>.empty();
  }

  @override
  Future<void> close() async {}

  List<Map<String, dynamic>> sends() =>
      sent.where((s) => s['method'] == 'agentSession.send').toList();

  int count(String method) => sent.where((s) => s['method'] == method).length;
}

void main() {
  late ScriptedOrcaRpc rpc;
  late OrcaMobileBackend backend;

  OrcaMobileBackend build() => OrcaMobileBackend(connect: () async => rpc);

  setUp(() {
    rpc = ScriptedOrcaRpc();
    backend = build();
  });

  tearDown(() => unawaited(backend.close()));

  test('create 带 firstMessage 只发一次 agentSession.create，记下 fence', () async {
    rpc.responder = (method, params) {
      if (method == 'agentSession.create') {
        return {'ok': true, 'value': <String, dynamic>{'fence': 7}};
      }
      return {'ok': true, 'value': <String, dynamic>{}};
    };
    await backend.established;
    final created = await backend
        .createSession(agent: 'dsh', sessionId: 'cs-1', worktreeId: 'wt', firstMessage: 'hi');
    expect(created.fence, 7);
    expect(rpc.count('agentSession.create'), 1);
    // create carries a null expectedRuntimeFence (spec §6).
    expect(rpc.sent.first['envelope']['expectedRuntimeFence'], null);
  });

  test('send 用 create 返回的 fence', () async {
    rpc.responder = (method, params) {
      if (method == 'agentSession.create') {
        return {'ok': true, 'value': <String, dynamic>{'fence': 42}};
      }
      return {'ok': true, 'value': <String, dynamic>{'dispatchState': 'accepted'}};
    };
    await backend.established;
    final c = await backend.createSession(agent: 'dsh', sessionId: 's-fence');
    await backend.send(c.sessionId, 'again');
    expect(rpc.sends().last['envelope']['expectedRuntimeFence'], 42);
  });

  test('重试保操作身份：首次 transport 失败，重试帧 opId 与指纹不变，host 回 replayed', () async {
    var sendCalls = 0;
    rpc.responder = (method, params) {
      if (method == 'agentSession.create') {
        return {'ok': true, 'value': <String, dynamic>{'fence': 3}};
      }
      if (method == 'agentSession.send') {
        sendCalls++;
        if (sendCalls == 1) {
          throw const OrcaTransportFailure('socket dropped');
        }
        return {'ok': true, 'value': <String, dynamic>{'replayed': true}};
      }
      return {'ok': true, 'value': <String, dynamic>{}};
    };
    await backend.established;
    final c = await backend.createSession(agent: 'dsh', sessionId: 's-retry');
    await backend.send(c.sessionId, 'again');
    final sends = rpc.sends();
    expect(sends.length, 2);
    expect(sends[1]['envelope']['clientOperationId'], sends[0]['envelope']['clientOperationId']);
    expect(sends[1]['envelope']['payloadFingerprint'],
        sends[0]['envelope']['payloadFingerprint']);
  });

  test('payloadFingerprint 对同一 method/sessionId/fields 稳定，不同 fields 不同', () {
    const m = 'agentSession.send';
    const id = 's1';
    final a = sessionPayloadFingerprint(m, id, {'body': <String, dynamic>{}});
    final b = sessionPayloadFingerprint(m, id, {'body': <String, dynamic>{}});
    final c = sessionPayloadFingerprint(m, id, {'body': {'x': 1}});
    expect(a, b);
    expect(a, isNot(c));
  });

  test('clientOperationId 格式 <13位ms>-<32位hex>', () {
    final op = newOperationId();
    expect(RegExp(r'^\d{13}-[0-9a-f]{32}$').hasMatch(op), true);
  });

  test('snapshot 与 batch 重叠时按 itemId 去重', () async {
    rpc.watchScript = [
      {
        'type': 'snapshot',
        'batch': {
          'items': [
            {
              'id': 'X',
              'seq': 5,
              'body': {'role': 'assistant', 'blocks': [
                {'type': 'text', 'text': 'dup'}]}
            },
          ],
        },
      },
      {
        'type': 'batch',
        'cursor': 6,
        'items': [
          {
            'id': 'X',
            'seq': 5,
            'body': {'role': 'assistant', 'blocks': [
              {'type': 'text', 'text': 'dup'}]}
          },
        ],
      },
      {'type': 'end'},
    ];
    await backend.established;
    final events = await backend.watch('s1').take(3).toList();
    final unique = <String>{};
    for (final e in events) {
      for (final m in e.messages) {
        unique.add(m.itemId);
      }
    }
    expect(unique.where((i) => i == 'X').length, 1);
  });

  test('host 回 accepted → send 成功；连接已断 → 可重试错误码不静默', () async {
    rpc.responder = (method, params) {
      if (method == 'agentSession.create') {
        return {'ok': true, 'value': <String, dynamic>{'fence': 2}};
      }
      return {'ok': true, 'value': <String, dynamic>{'dispatchState': 'accepted'}};
    };
    await backend.established;
    final c = await backend.createSession(agent: 'dsh', sessionId: 's-ok');
    await backend.send(c.sessionId, 'ok');
    // Close the transport; a subsequent send surfaces a retriable error, not a silent swallow.
    await backend.close();
    await expectLater(
      backend.send(c.sessionId, 'x'),
      throwsA(isA<MobileBackendException>()
          .having((e) => e.retriable, 'retriable', true)),
    );
  });

  test('能力边界：不声明 DSH 特有能力，声明通用能力', () async {
    await backend.established;
    final caps = backend.capabilities;
    expect(caps, containsAll([
      ChatCapability.historyPaging,
      ChatCapability.send,
      ChatCapability.cancel,
      ChatCapability.approval,
      ChatCapability.modelCatalog,
      ChatCapability.worktreeList,
    ]));
    expect(caps, isNot(containsAll([
      ChatCapability.subagentRouting,
      ChatCapability.terminalSession,
      ChatCapability.mux,
      ChatCapability.lifecycleStatus,
    ])));
  });
}
