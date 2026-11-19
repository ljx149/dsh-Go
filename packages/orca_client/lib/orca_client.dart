/// Minimal pure-Dart client for the Orca mobile link.
///
/// Reproduces, in Dart, the legacy pairing + E2EE + RPC + subscribe path that
/// the Node probes proved in P0 0.3. No Flutter dependency.
library;

export 'src/e2ee_legacy.dart';
export 'src/legacy_rpc_client.dart';
export 'src/session_mutation.dart';
export 'src/backend_types.dart';
export 'src/mobile_chat_backend.dart';
export 'src/fake_mobile_chat_backend.dart';
export 'src/orca_mobile_backend.dart';
export 'src/dsh_mobile_backend.dart';
