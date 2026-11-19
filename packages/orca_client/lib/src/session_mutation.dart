import 'dart:convert';
import 'dart:math';

import 'package:crypto/crypto.dart';

final _random = Random.secure();

String newClientId() => List.generate(
      16,
      (_) => _random.nextInt(256).toRadixString(16).padLeft(2, '0'),
    ).join();

String newOperationId() {
  final timestamp = DateTime.now().millisecondsSinceEpoch.toString();
  if (!RegExp(r'^\d{13}$').hasMatch(timestamp)) {
    throw StateError('Invalid operation timestamp');
  }
  return '$timestamp-${newClientId()}';
}

String canonicalSessionJson(Object? value) {
  if (value is List) {
    return '[${value.map(canonicalSessionJson).join(',')}]';
  }
  if (value is Map<String, dynamic>) {
    final keys = value.keys.toList()..sort();
    return '{${keys.map((key) => '${jsonEncode(key)}:${canonicalSessionJson(value[key])}').join(',')}}';
  }
  // Explicit null is part of the host fingerprint; omit optional keys at construction.
  return jsonEncode(value);
}

String sessionPayloadFingerprint(
  String method,
  String sessionId,
  Map<String, dynamic> fields,
) => sha256.convert(utf8.encode(canonicalSessionJson({
      'method': method,
      'sessionId': sessionId,
      'fields': fields,
    }))).toString();

Map<String, dynamic> sessionMutation({
  required String method,
  required String sessionId,
  required Map<String, dynamic> fields,
  required int? expectedRuntimeFence,
}) {
  final payload = jsonDecode(jsonEncode(fields)) as Map<String, dynamic>;
  return {
    'envelope': {
      'sessionId': sessionId,
      'clientOperationId': newOperationId(),
      'expectedRuntimeFence': expectedRuntimeFence,
      'payloadFingerprint': sessionPayloadFingerprint(method, sessionId, payload),
    },
    ...payload,
  };
}

Map<String, dynamic> textMessage(String text) => {
      'kind': 'message',
      'role': 'user',
      'blocks': [
        {'type': 'text', 'text': text},
      ],
    };

Map<String, dynamic> createSessionRequest({
  required String sessionId,
  required String worktree,
  required String agent,
  String? firstMessage,
}) => sessionMutation(
      method: 'agentSession.create',
      sessionId: sessionId,
      expectedRuntimeFence: null,
      fields: {
        'worktree': worktree,
        'agent': agent,
        if (firstMessage != null)
          'firstMessage': {
            'clientMessageId': newClientId(),
            'body': textMessage(firstMessage),
          },
      },
    );

Map<String, dynamic> sendSessionRequest({
  required String sessionId,
  required String text,
  required int? fence,
}) => sessionMutation(
      method: 'agentSession.send',
      sessionId: sessionId,
      expectedRuntimeFence: fence,
      fields: {'body': textMessage(text)},
    );
