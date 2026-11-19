import 'dart:async';
import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../secret_store.dart';
import '../../state/hosts_state.dart' show secretStoreProvider;

/// An Orca host: the pairing `endpoint` lives in SharedPreferences (it is a
/// dial address, not a credential), the `pairingCode` lives in the
/// [SecretStore] (it is a bearer credential). Equality is by [id].
class OrcaHostConfig {
  const OrcaHostConfig({
    required this.id,
    required this.endpoint,
    this.name,
    this.pairingCode,
  });

  final String id;
  final String endpoint;
  final String? name;

  /// Only present when [OrcaHostsController.load] has merged the secret back in.
  final String? pairingCode;

  Map<String, Object?> toJson() => {
        'id': id,
        'endpoint': endpoint,
        if (name != null) 'name': name,
      };

  static OrcaHostConfig? fromJson(Object? json) {
    if (json is! Map) return null;
    final id = json['id'];
    final endpoint = json['endpoint'];
    if (id is! String || endpoint is! String || id.isEmpty) return null;
    final name = json['name'];
    return OrcaHostConfig(id: id, endpoint: endpoint, name: name is String ? name : null);
  }

  static const prefsKey = 'remote_orca_hosts';

  static String pairingCodeKey(String id) => 'remote.orca_pairing.$id';

  @override
  bool operator ==(Object other) => other is OrcaHostConfig && other.id == id;

  @override
  int get hashCode => id.hashCode;

  @override
  String toString() => 'OrcaHostConfig($id)';
}

/// Saved Orca hosts: configs in SharedPreferences, pairing codes in the
/// [SecretStore] (never in prefs, never in the repo).
class OrcaHostsController extends Notifier<List<OrcaHostConfig>> {
  late Future<void> _loaded;

  SecretStore get _secrets => ref.read(secretStoreProvider);

  @override
  List<OrcaHostConfig> build() {
    _loaded = _load();
    return const [];
  }

  /// Completes once the saved list has been read.
  Future<void> get ready => _loaded;

  Future<void> _load() async {
    var hosts = const <OrcaHostConfig>[];
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(OrcaHostConfig.prefsKey);
      if (raw != null) {
        final list = jsonDecode(raw);
        if (list is List) hosts = list.map(OrcaHostConfig.fromJson).whereType<OrcaHostConfig>().toList();
      }
    } catch (_) {
      // No preferences backend (tests) or a corrupt entry: start empty.
    }
    state = hosts;
  }

  Future<void> _persist(List<OrcaHostConfig> hosts) async {
    state = List.unmodifiable(hosts);
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(OrcaHostConfig.prefsKey, jsonEncode([for (final h in hosts) h.toJson()]));
    } catch (_) {}
  }

  /// Adds or replaces [config]. With [pairingCode], stores it in the
  /// [SecretStore]; deleting it (null) removes the secret.
  Future<void> save(OrcaHostConfig config, {String? pairingCode}) async {
    await _loaded;
    final key = OrcaHostConfig.pairingCodeKey(config.id);
    try {
      if (pairingCode == null || pairingCode.isEmpty) {
        await _secrets.delete(key);
      } else {
        await _secrets.write(key, pairingCode);
      }
    } catch (_) {}
    final hosts = [...state];
    final index = hosts.indexWhere((h) => h.id == config.id);
    if (index >= 0) {
      hosts[index] = config;
    } else {
      hosts.add(config);
    }
    await _persist(hosts);
  }

  /// Returns the saved host merged with its stored pairing code, or null.
  Future<OrcaHostConfig?> load(String id) async {
    await _loaded;
    final host = state.where((h) => h.id == id).cast<OrcaHostConfig?>().firstOrNull;
    if (host == null) return null;
    String? code;
    try {
      code = await _secrets.read(OrcaHostConfig.pairingCodeKey(id));
    } catch (_) {}
    return OrcaHostConfig(id: host.id, endpoint: host.endpoint, name: host.name, pairingCode: code);
  }

  /// Removes the host and its pairing code.
  Future<void> remove(String id) async {
    await _loaded;
    await _persist([...state.where((h) => h.id != id)]);
    try {
      await _secrets.delete(OrcaHostConfig.pairingCodeKey(id));
    } catch (_) {}
  }
}

final orcaHostsProvider = NotifierProvider<OrcaHostsController, List<OrcaHostConfig>>(
  OrcaHostsController.new,
);
