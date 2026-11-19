/// Xcodex managed Agent endpoints over the existing authenticated carrier.
library;

import 'errors.dart';
import 'json.dart';
import 'models.dart';
import 'session_api.dart';

class ManagedAgentDefinition {
  const ManagedAgentDefinition({
    required this.id,
    required this.name,
    required this.available,
    this.availability = 'unverified',
    this.icon,
    required this.capabilities,
  });

  factory ManagedAgentDefinition.fromJson(Object? json) {
    final map = asMapOrEmpty(json);
    final id = asString(map['id']) ?? '';
    return ManagedAgentDefinition(
      id: id,
      name: asString(map['name']) ?? id,
      available: map['available'] == true,
      availability: asString(map['availability']) ?? 'unverified',
      icon: asString(map['icon']),
      capabilities: ManagedAgentCapabilities.fromJson(map['capabilities']),
    );
  }

  final String id;
  final String name;

  /// Registration only; true does not prove the CLI is installed or authenticated.
  final bool available;
  final String availability;
  final String? icon;
  final ManagedAgentCapabilities capabilities;
}

extension ManagedAgentsApi on DshClient {
  /// Unsupported Host errors are intentionally preserved so the UI can keep
  /// native DSH creation without treating auth/network failures as unsupported.
  Future<List<ManagedAgentDefinition>> listManagedAgents() async {
    final value = asMapOrEmpty(await rpc.call('managedAgent/agents'));
    return asListOrEmpty(
      value['items'],
    ).map(ManagedAgentDefinition.fromJson).where((agent) => agent.id.isNotEmpty).toList(growable: false);
  }

  /// Caller retains [operationId] across uncertain/retried requests. Never
  /// fall back to session/create: that could create a different Agent session.
  Future<SessionCreated> createManagedSession({
    required String workspaceId,
    required String agentId,
    required String operationId,
  }) async {
    final value = asMapOrEmpty(
      await rpc.call('managedAgent/create', {
        'request': {'workspaceId': workspaceId, 'agentId': agentId, 'operationId': operationId},
      }),
    );
    final id = asString(value['sessionId']);
    if (id == null || id.isEmpty) {
      throw const DshProtocolException('managedAgent/create returned no sessionId');
    }
    return SessionCreated(id, null);
  }
}
