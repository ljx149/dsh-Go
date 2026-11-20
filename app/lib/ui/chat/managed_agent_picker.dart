import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../l10n/l10n.dart';
import '../../state/managed_agents_state.dart';
import '../../state/hosts_state.dart';
import '../../state/sessions_state.dart';
import '../../state/read_list_identity.dart';
import '../../state/workspaces_state.dart';
import 'managed_agent_logo.dart';

/// Native DSH remains available with old Hosts. Managed creation never falls
/// back to a native conversation or to another workspace.
Future<void> showNewAgentSession(
  BuildContext context,
  WidgetRef ref,
  VoidCallback nativeNewChat,
  VoidCallback closeDrawer,
) async {
  if (ref.read(activeHostProvider).kind != HostKind.relay) {
    nativeNewChat();
    return;
  }
  await showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    builder: (_) => _NewAgentSession(nativeNewChat: nativeNewChat, closeDrawer: closeDrawer),
  );
}

class _NewAgentSession extends ConsumerStatefulWidget {
  const _NewAgentSession({required this.nativeNewChat, required this.closeDrawer});
  final VoidCallback nativeNewChat, closeDrawer;
  @override
  ConsumerState<_NewAgentSession> createState() => _NewAgentSessionState();
}

class _NewAgentSessionState extends ConsumerState<_NewAgentSession> {
  String? _workspaceId;
  bool _initialized = false, _busy = false;
  String? _error;
  Object? _owner;
  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final workspaces = ref.watch(workspacesProvider);
    final owner = ref.watch(readListIdentityProvider);
    if (!_initialized && owner != null) {
      _initialized = true;
      _owner = owner;
      _workspaceId =
          ref.read(selectedWorkspaceProvider)?.workspaceId ?? ref.read(recentWorkspaceForNewChatProvider)?.workspaceId;
      if (_workspaceId == null && workspaces.workspaces.length == 1) {
        _workspaceId = workspaces.workspaces.single.workspaceId;
      }
    }
    final validOwner = owner != null && owner == _owner;
    final agents = ref.watch(managedAgentsProvider);
    final shownAgents = agents.isLoading || agents.hasError ? const [] : agents.value ?? const [];
    return SafeArea(
      child: SingleChildScrollView(
        child: Padding(
          padding: const EdgeInsets.all(20),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(l10n.managedChooseAgent, style: Theme.of(context).textTheme.titleLarge),
              ListTile(
                title: const Text('DSH'),
                enabled: !_busy && validOwner,
                onTap: () {
                  Navigator.pop(context);
                  widget.nativeNewChat();
                },
              ),
              if (workspaces.workspaces.isNotEmpty)
                DropdownButton<String>(
                  isExpanded: true,
                  value: workspaces.byId(_workspaceId)?.workspaceId,
                  hint: Text(l10n.managedChooseWorkspace),
                  items: [
                    for (final workspace in workspaces.workspaces)
                      DropdownMenuItem(
                        value: workspace.workspaceId,
                        child: Text(workspace.path, overflow: TextOverflow.ellipsis),
                      ),
                  ],
                  onChanged: _busy || !validOwner ? null : (value) => setState(() => _workspaceId = value),
                ),
              if (!workspaces.ready || workspaces.byId(_workspaceId) == null) Text(l10n.managedChooseWorkspace),
              if (agents.isLoading || _busy) const LinearProgressIndicator(),
              if (agents.hasError)
                TextButton(
                  onPressed: _busy ? null : () => ref.invalidate(managedAgentsProvider),
                  child: Text(l10n.managedDiscoveryRetry),
                ),
              for (final agent in shownAgents)
                ListTile(
                  leading: ManagedAgentLogo(agentId: agent.id),
                  title: Text(agent.name),
                  subtitle: Text(l10n.managedUsesComputerConfig),
                  enabled:
                      validOwner &&
                      !_busy &&
                      agent.available &&
                      workspaces.ready &&
                      workspaces.byId(_workspaceId) != null,
                  onTap: () => _create(agent.id),
                ),
              if (_error != null) Text(_error!, style: TextStyle(color: Theme.of(context).colorScheme.error)),
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _create(String agentId) async {
    final workspace = _workspaceId;
    if (workspace == null || _busy) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await ref
          .read(managedCreationProvider)
          .create(ref, workspace, agentId, isCurrent: () => mounted && _owner == ref.read(readListIdentityProvider));
      if (!mounted) return;
      Navigator.pop(context);
      widget.closeDrawer();
    } catch (_) {
      if (mounted) setState(() => _error = context.l10n.managedCreateFailed);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }
}
