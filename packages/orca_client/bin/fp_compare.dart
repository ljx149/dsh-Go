import 'dart:convert';
import 'package:crypto/crypto.dart';

String canonicalize(dynamic v) {
  if (v == null || (v is! Map && v is! List)) return jsonEncode(v ?? null);
  if (v is List) return '[${v.map(canonicalize).join(',')}]';
  final m = v as Map<String, dynamic>;
  final entries = m.entries.where((e) => e.value != null).toList()..sort((a, b) => a.key.compareTo(b.key));
  return '{${entries.map((e) => '${jsonEncode(e.key)}:${canonicalize(e.value)}').join(',')}}';
}

void main() {
  final payload = {
    'worktree': 'f64a1851-b6d4-4ebf-bfa9-309f47f43685::/Users/joseph',
    'agent': 'dsh',
    'firstMessage': {
      'clientMessageId': 'CLIENTMSGID',
      'body': {
        'kind': 'message',
        'role': 'user',
        'blocks': [
          {'type': 'text', 'text': 'Reply with the single word: pong'}
        ],
      },
    },
  };
  final input = canonicalize({
    'method': 'agentSession.create',
    'sessionId': 'TESTSESSION',
    'fields': payload,
  });
  print('INPUT=$input');
  print('FP=${sha256.convert(utf8.encode(input)).toString()}');
}
