import 'dart:async';

import 'package:dsh_app/state/managed_agents_state.dart';
import 'package:dsh_client/dsh_client.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('uncertain creation reuses operation id; success allows a new session', () async {
    final operations = ManagedCreationOperations();
    final ids = <String>[];
    await expectLater(
      operations.run(
        'owner-host',
        'ws',
        'codex',
        check: () {},
        action: (id) async {
          ids.add(id);
          throw const DshClosedException('response lost');
        },
      ),
      throwsA(isA<DshClosedException>()),
    );
    for (var i = 0; i < 2; i++) {
      await operations.run(
        'owner-host',
        'ws',
        'codex',
        check: () {},
        action: (id) async {
          ids.add(id);
          return 'session';
        },
      );
    }
    expect(ids[0], ids[1]);
    expect(ids[2], isNot(ids[1]));
    expect(ids.first, matches(RegExp(r'^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$')));
  });

  test('account switch rejects old response and never reuses another owner operation', () async {
    final operations = ManagedCreationOperations();
    var owner = 'account-A-host';
    final reply = Completer<String>();
    String? oldId;
    final old = operations.run(
      owner,
      'ws',
      'claude',
      check: () {
        if (owner != 'account-A-host') throw const DshClosedException('changed');
      },
      action: (id) {
        oldId = id;
        return reply.future;
      },
    );
    final rejected = expectLater(old, throwsA(isA<DshClosedException>()));
    owner = 'account-B-host';
    String? newId;
    await operations.run(
      owner,
      'ws',
      'claude',
      check: () {},
      action: (id) async {
        newId = id;
        return 'B-session';
      },
    );
    reply.complete('A-session');
    await rejected;
    expect(newId, isNot(oldId));
    owner = 'account-A-host';
    await operations.run(
      owner,
      'ws',
      'claude',
      check: () {},
      action: (id) async {
        expect(id, oldId, reason: 'retry of the ambiguous old request still uses its own ID');
        return 'A-session';
      },
    );
  });

  test('double tap does not duplicate dispatch and stale context does not dispatch', () async {
    final operations = ManagedCreationOperations();
    final reply = Completer<String>();
    var sends = 0;
    final first = operations.run(
      'owner',
      'ws',
      'codex',
      check: () {},
      action: (_) {
        sends++;
        return reply.future;
      },
    );
    await expectLater(
      operations.run(
        'owner',
        'ws',
        'codex',
        check: () {},
        action: (_) async {
          sends++;
          return 'duplicate';
        },
      ),
      throwsA(isA<DshClosedException>()),
    );
    await expectLater(
      operations.run(
        'owner',
        'ws-other',
        'codex',
        check: () {
          throw const DshClosedException('stale workspace');
        },
        action: (_) async {
          sends++;
          return 'stale';
        },
      ),
      throwsA(isA<DshClosedException>()),
    );
    expect(sends, 1);
    reply.complete('created');
    expect(await first, 'created');
  });
}
