import 'dart:io';
import 'dart:typed_data';

import 'package:dsh_app/state/attachments.dart';
import 'package:dsh_app/state/chat_state.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support/session_sync_host.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    final previous = HttpOverrides.current;
    HttpOverrides.global = RealSyncHttp();
    addTearDown(() => HttpOverrides.global = previous);
  });

  test('managed unsupported attachments and running sends never cross the wire', () async {
    final h = await SyncHarness.start(initialSnapshot: false);
    addTearDown(h.close);
    final snapshot = syncSnapshot(1);
    final projection = snapshot['projections']! as Map<String, Object?>;
    projection['values'] = {
      'managedAgent': {'agentId': 'codex'},
    };
    h.follows.last.socket.item(h.follows.last.id, snapshot);
    await waitSync(() => h.state.controlReady && h.chat.projections.isManagedAgent, 'managed snapshot');
    expect(h.state.running, isTrue);
    final callsBefore = h.host.rpcCalls.length;
    final file = DraftAttachment(name: 'private.txt', bytes: Uint8List.fromList([1, 2, 3]));
    final image = DraftAttachment(name: 'private.png', bytes: Uint8List.fromList([4]), mediaType: 'image/png');
    for (final attachment in [file, image]) {
      expect(await h.chat.send('draft', attachments: [attachment]), isFalse);
      expect(h.state.pending, isEmpty);
    }
    for (final mode in SendMode.values) {
      expect(await h.chat.send('keep draft', mode: mode), isFalse);
      expect(h.state.pending, isEmpty);
    }
    expect(h.host.rpcCalls.length, callsBefore, reason: 'No upload, cancel, queue or prompt side effects');
    expect(h.cancelledBackendRuns, isEmpty);
  });
}
