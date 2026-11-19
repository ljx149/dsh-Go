import 'package:dsh_client/dsh_client.dart';
import 'package:test/test.dart';

class _Carrier extends DshCarrier {
  final calls = <(String, Map<String, Object?>)>[];
  RpcResult result = const RpcOk(null);
  @override
  String get kind => 'memory';
  @override
  DshTracer? get tracer => null;
  @override
  Future<RpcResult> call(String endpoint, Map<String, Object?> args, {Duration? timeout}) async {
    calls.add((endpoint, args));
    return result;
  }

  @override
  Future<DshMuxLink> openLink(MuxOptions options) => throw UnimplementedError();
  @override
  Future<void> close() async {}
}

void main() {
  late _Carrier carrier;
  late DshClient client;
  setUp(() {
    carrier = _Carrier();
    client = DshClient.withCarrier(carrier);
  });
  tearDown(() => client.close());

  test('discovery distinguishes registered from runnable and defaults conservatively', () async {
    carrier.result = const RpcOk({
      'items': [
        {'id': 'codex', 'name': 'Codex', 'available': true},
        {
          'id': 'claude',
          'available': true,
          'capabilities': {'archive': true, 'imagePrompts': false},
        },
      ],
    });
    final agents = await client.listManagedAgents();
    expect(carrier.calls.single.$1, 'managedAgent/agents');
    expect(carrier.calls.single.$2, isEmpty);
    expect(agents.first.availability, 'unverified');
    expect(agents.first.capabilities.textPrompts, isTrue);
    expect(agents.first.capabilities.queueWhileBusy, isFalse);
    expect(agents.first.capabilities.archive, isFalse);
    expect(agents.last.capabilities.archive, isTrue);
  });

  test('create preserves caller operation id and workspace across retries', () async {
    carrier.result = const RpcOk({'sessionId': 'managed-1'});
    for (var i = 0; i < 2; i++) {
      final created = await client.createManagedSession(
        workspaceId: 'ws-1',
        agentId: 'codex',
        operationId: 'same-operation',
      );
      expect(created.sessionId, 'managed-1');
    }
    expect(carrier.calls, hasLength(2));
    for (final call in carrier.calls) {
      expect(call.$1, 'managedAgent/create');
      expect(call.$2, {
        'request': {'workspaceId': 'ws-1', 'agentId': 'codex', 'operationId': 'same-operation'},
      });
    }
  });

  test('failed creation never falls back to native create', () async {
    carrier.result = const RpcError(DshRemoteException('managed-agent/rejected', 'unavailable'));
    await expectLater(
      client.createManagedSession(workspaceId: 'ws-1', agentId: 'codex', operationId: 'op'),
      throwsA(isA<DshRemoteException>()),
    );
    expect(carrier.calls.map((c) => c.$1), ['managedAgent/create']);
    carrier.result = const RpcOk({});
    await expectLater(
      client.createManagedSession(workspaceId: 'ws-1', agentId: 'codex', operationId: 'op'),
      throwsA(isA<DshProtocolException>()),
    );
  });

  test('discovery preserves unavailable endpoint and authentication errors', () async {
    for (final code in ['gateway/not-found', 'AUTH_INVALID']) {
      carrier.result = RpcError(DshRemoteException(code, code));
      await expectLater(
        client.listManagedAgents(),
        throwsA(isA<DshRemoteException>().having((e) => e.code, 'code', code)),
      );
    }
  });

  test('scoped model lookup sends session while native lookup stays unchanged', () async {
    carrier.result = const RpcOk({'groups': [], 'routableProviders': []});
    await client.listModels(sessionId: 'managed-1');
    await client.listModels();
    expect(carrier.calls, hasLength(2));
    expect(carrier.calls.map((call) => call.$1), ['session/modelCatalog', 'session/modelCatalog']);
    expect(carrier.calls.first.$2, {
      'request': {'sessionId': 'managed-1'},
    });
    expect(carrier.calls.last.$2, isEmpty);
  });

  test('identity uses managed projection only, never model or raw agent id', () {
    final native = SessionSummary.fromJson({
      'agentId': 'codex',
      'projections': {
        'values': {
          'modelSelection': {
            'next': {'provider': 'codex', 'model': 'gpt-5'},
          },
        },
      },
    });
    expect(native.isManagedAgent, isFalse);
    expect(native.managedAgentCapabilities, isNull);
    final managed = SessionSummary.fromJson({
      'projections': {
        'values': {
          'managedAgent': {
            'agentId': 'codex',
            'capabilities': {'reasoningEffort': true, 'queueWhileBusy': false},
          },
        },
      },
    });
    expect(managed.managedAgentId, 'codex');
    expect(managed.copyWith(running: true).managedAgentId, 'codex');
    expect(managed.managedAgentCapabilities!.reasoningEffort, isTrue);
    expect(managed.managedAgentCapabilities!.queueWhileBusy, isFalse);
    expect(managed.managedAgentCapabilities!.delete, isFalse);
  });
}
