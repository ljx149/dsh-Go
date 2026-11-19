import 'dart:async';

import 'package:dsh_app/remote/orca/orca_backend_selection.dart';
import 'package:dsh_app/state/connection_state.dart';
import 'package:dsh_app/state/hosts_state.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:orca_client/orca_client.dart';

import 'chat/support/harness.dart' show fakeConnection;

class _OrcaHost extends ActiveHostController {
  @override
  HostRef build() => HostRef.orca('o1');

  @override
  void select(HostRef host) => state = host;
}

class _LocalHost extends ActiveHostController {
  @override
  HostRef build() => HostRef.local;

  @override
  void select(HostRef host) => state = host;
}

class _ScriptedRpc implements OrcaRpc {
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
  final scripted = _ScriptedRpc();

  test('activeHost 为 orca 时给出 OrcaMobileBackend，capabilities 不含 DSH 特有能力', () {
    final container = ProviderContainer(overrides: [
      activeHostProvider.overrideWith(_OrcaHost.new),
      orcaBackendConnectProvider.overrideWithValue(() async => scripted),
    ]);
    addTearDown(container.dispose);
    final backend = container.read(mobileChatBackendProvider);
    expect(backend, isA<OrcaMobileBackend>());
    expect(backend.capabilities, isNot(contains(ChatCapability.mux)));
    expect(backend.capabilities, isNot(contains(ChatCapability.subagentRouting)));
  });

  test('activeHost 为本机时给出 DshMobileBackend，capabilities 含 DSH 特有能力', () {
    final container = ProviderContainer(overrides: [
      activeHostProvider.overrideWith(_LocalHost.new),
      activeConnectionProvider.overrideWithValue(AsyncData<HostConnection?>(fakeConnection)),
    ]);
    addTearDown(container.dispose);
    final backend = container.read(mobileChatBackendProvider);
    expect(backend, isA<DshMobileBackend>());
    expect(backend.capabilities, contains(ChatCapability.mux));
    expect(backend.capabilities, contains(ChatCapability.subagentRouting));
  });
}
