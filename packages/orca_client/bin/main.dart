import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:orca_client/orca_client.dart';

Future<void> main(List<String> args) async {
  if (args.length < 4) {
    stderr.writeln('usage: <wsEndpoint> <pairingCode> <agent> <worktree> '
        '[--session <existingOrcaSessionId>] [--prompt <text>]');
    exitCode = 2;
    return;
  }
  String? existingSession;
  var prompt = 'Reply with the single word: pong';
  for (var index = 4; index < args.length; index += 2) {
    if (index + 1 >= args.length ||
        !['--session', '--prompt'].contains(args[index])) {
      stderr.writeln('Expected --session <id> or --prompt <text>');
      exitCode = 2;
      return;
    }
    if (args[index] == '--session') existingSession = args[index + 1];
    if (args[index] == '--prompt') prompt = args[index + 1];
  }

  LegacyOrcaClient? client;
  StreamSubscription<Map<String, dynamic>>? subscription;
  try {
    final connection = await LegacyOrcaClient.connect(Uri.parse(args[0]), args[1]);
    client = connection;
    final sessionId = existingSession ?? newClientId();
    int? fence;
    if (existingSession == null) {
      final request = createSessionRequest(
        sessionId: sessionId,
        worktree: args[3],
        agent: args[2],
        firstMessage: prompt,
      );
      final value = requireMutationValue(
        await connection.request('agentSession.create', request),
      );
      fence = value['fence'] as int?;
      print('[create] sessionId=$sessionId fence=$fence');
    } else {
      // Reopen the Orca record; the fence the host reports there is what the send must carry.
      final reopened = await connection.request('agentSession.history', {
        'sessionId': sessionId, 'direction': 'tail', 'limit': 1,
      });
      fence = reopened['page']?['fence'] as int?;
      print('[reopen] sessionId=$sessionId fence=$fence');
    }

    final opened = Completer<void>();
    final events = <Map<String, dynamic>>[];
    subscription = connection.subscribe(sessionId).listen((event) {
      events.add(event);
      if (!opened.isCompleted) opened.complete();
      print('[event] ${jsonEncode(event)}');
    }, onError: (Object error, StackTrace stack) {
      if (!opened.isCompleted) opened.completeError(error, stack);
      stderr.writeln('[subscription] $error');
      exitCode = 1;
    }, onDone: () {
      if (!opened.isCompleted) {
        opened.completeError(StateError('Subscription ended before its first frame'));
      }
    });
    await opened.future.timeout(const Duration(seconds: 30));

    // A fresh create already queued its prompt; only an explicit continuation sends again.
    if (existingSession != null) {
      final result = await connection.request('agentSession.send', sendSessionRequest(
        sessionId: sessionId, text: prompt, fence: fence,
      ));
      print('[send] ${jsonEncode(requireMutationValue(result))}');
    }
    await Future<void>.delayed(const Duration(seconds: 15));
    final history = await connection.request('agentSession.history', {
      'sessionId': sessionId, 'direction': 'tail', 'limit': 50,
    });
    print('[history] ${jsonEncode(history)}');
    print('[summary] sessionId=$sessionId eventCount=${events.length}');
  } catch (error) {
    stderr.writeln('[error] $error');
    exitCode = 1;
  } finally {
    await subscription?.cancel();
    await client?.close();
  }
}
