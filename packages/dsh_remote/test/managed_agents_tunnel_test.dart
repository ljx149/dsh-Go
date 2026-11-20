import 'package:dsh_remote/dsh_remote.dart';
import 'package:test/test.dart';

import 'support/fake_remote.dart';

void main() {
  test('managed discovery, idempotent creation and scoped models traverse authenticated tunnel', () async {
    final server = await FakeRemoteServer.start();
    final host = await FakeRemoteHost.start(server);
    final account = RemoteAccount(secrets: MemorySecretStore(), serverUrl: server.url);
    addTearDown(() async {
      await account.close();
      await host.close();
      await server.close();
    });
    host.handlers['managedAgent/agents'] = (_) => {
      'ok': true,
      'value': {
        'items': [
          {'id': 'codex', 'name': 'Codex', 'available': true, 'availability': 'unverified'},
        ],
      },
    };
    final operations = <String>[];
    host.handlers['managedAgent/create'] = (args) {
      final request = args['request']! as Map;
      expect(request['workspaceId'], 'ws-current');
      expect(request['agentId'], 'codex');
      expect(request.containsKey('cwd'), isFalse);
      operations.add(request['operationId']! as String);
      return {
        'ok': true,
        'value': {'sessionId': 'managed-1'},
      };
    };
    host.handlers['session/modelCatalog'] = (args) {
      expect(args, {
        'request': {'sessionId': 'managed-1'},
      });
      return {
        'ok': true,
        'value': {'groups': [], 'routableProviders': []},
      };
    };
    await account.loginWithPassword(FakeRemoteServer.account, FakeRemoteServer.password);
    final client = await account.connectHost(
      (await account.listHosts()).single,
      muxOptions: const MuxOptions(readyTimeout: Duration(seconds: 3)),
    );
    expect(client.supportsEndpoint('managedAgent/agents'), isTrue);
    expect(client.supportsEndpoint('managedAgent/create'), isTrue);
    expect(client.supportsEndpoint('session/modelCatalog'), isTrue);
    expect(client.supportsEndpoint('managedAgent/deleteAll'), isFalse);
    expect((await client.listManagedAgents()).single.id, 'codex');
    for (var i = 0; i < 2; i++) {
      expect(
        (await client.createManagedSession(
          workspaceId: 'ws-current',
          agentId: 'codex',
          operationId: 'stable-create',
        )).sessionId,
        'managed-1',
      );
    }
    expect(operations, ['stable-create', 'stable-create']);
    await client.listModels(sessionId: 'managed-1');
    host.handlers['managedAgent/agents'] = (_) => {
      'ok': false,
      'error': {'code': 'gateway/not-found', 'message': 'old Host', 'details': <String, Object?>{}},
    };
    await expectLater(
      client.listManagedAgents(),
      throwsA(isA<DshRemoteException>().having((e) => e.code, 'code', 'gateway/not-found')),
    );
    expect(server.protocolErrors, isEmpty);
  });
}
