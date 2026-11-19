import 'dart:convert';
import 'package:crypto/crypto.dart';
String c(dynamic v) {
  if (v == null || (v is! Map && v is! List)) return jsonEncode(v ?? null);
  if (v is List) return '[${v.map(c).join(',')}]';
  final m = v as Map<String, dynamic>;
  final e = m.entries.where((x) => x.value != null).toList()..sort((a, b) => a.key.compareTo(b.key));
  return '{${e.map((x) => '${jsonEncode(x.key)}:${c(x.value)}').join(',')}}';
}
void main() {
  final fields = {'worktree': 'W', 'agent': 'claude', 'firstMessage': {'clientMessageId': 'C', 'body': {'kind': 'message', 'role': 'user', 'blocks': [{'type': 'text', 'text': 'pong'}]}}};
  final input = c({'method': 'agentSession.create', 'sessionId': 'S', 'fields': fields});
  print('input=$input');
  print('fp=${sha256.convert(utf8.encode(input)).toString()}');
}
