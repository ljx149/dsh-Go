// Orca mobile-link probe: connect to an Orca host with legacy pairing, create
// a DSH structured session, and stream events back. Verifies the dual-end
// shared package path end to end. Not part of any release.
//
//   flutter run -t lib/dev/orca_link_probe_main.dart
//
// Config in `files/orca_link_probe.json`:
//   {"endpoint": "ws://30.212.28.180:6769", "pairingCode": "eyJ2Ijoy..."}
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:orca_client/orca_client.dart';
import 'package:path_provider/path_provider.dart';

final _log = ValueNotifier<List<String>>([]);
final _input = TextEditingController(text: 'Reply with the single word: pong');
final _busy = ValueNotifier<bool>(false);
String? _sessionId;
int? _fence;
LegacyOrcaClient? _client;
StreamSubscription<Map<String, dynamic>>? _sub;

void _logLine(String line) {
  debugPrint('[orca-link] $line');
  _log.value = [..._log.value, line];
}

Future<Map<String, dynamic>> _readConfig() async {
  final dir = await getApplicationSupportDirectory();
  final file = File('${dir.path}/orca_link_probe.json');
  final parsed = jsonDecode(await file.readAsString()) as Map;
  return parsed.cast<String, Object?>();
}

Future<void> _run() async {
  _busy.value = true;
  try {
    final config = await _readConfig();
    final endpoint = config['endpoint'] as String;
    final code = config['pairingCode'] as String;
    _logLine('connecting $endpoint …');
    _client = await LegacyOrcaClient.connect(Uri.parse(endpoint), code);
    _logLine('authenticated');

    final prompt = _input.text.trim();
    if (_sessionId == null) {
      final sessionId = newClientId();
      final request = createSessionRequest(
        sessionId: sessionId,
        worktree: 'f64a1851-b6d4-4ebf-bfa9-309f47f43685::/Users/joseph',
        agent: 'dsh',
        firstMessage: prompt,
      );
      final value = requireMutationValue(
        await _client!.request('agentSession.create', request),
      );
      _sessionId = sessionId;
      _fence = value['fence'] as int?;
      _logLine('created $_sessionId fence=$_fence');
    } else {
      final result = await _client!.request('agentSession.send', sendSessionRequest(
        sessionId: _sessionId!, text: prompt, fence: _fence,
      ));
      requireMutationValue(result);
      _logLine('sent to $_sessionId');
    }

    await _sub?.cancel();
    _sub = _client!.subscribe(_sessionId!).listen(
      (event) {
        final batch = event['batch'] as Map?;
        final items = (batch?['items'] as List?) ?? const [];
        for (final item in items) {
          final body = item['body'] as Map?;
          final role = body?['role'];
          final blocks = (body?['blocks'] as List?) ?? const [];
          final text = blocks
              .whereType<Map<String, dynamic>>()
              .where((b) => b['type'] == 'text')
              .map((b) => b['text'] as String?)
              .join(' ');
          if (text.isNotEmpty) _logLine('$role: $text');
        }
      },
      onError: (Object error) => _logLine('stream error: $error'),
      onDone: () => _logLine('stream closed'),
    );
    _logLine('subscribed to $_sessionId');
  } catch (error) {
    _logLine('FAILED: $error');
  } finally {
    _busy.value = false;
  }
}

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const OrcaLinkProbePage());
}

/// The probe UI, embeddable from any entry point (IDE run of main.dart).
class OrcaLinkProbePage extends StatelessWidget {
  const OrcaLinkProbePage({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      home: Scaffold(
        appBar: AppBar(title: const Text('Orca Link Probe')),
        body: SafeArea(
          child: Column(
            children: [
              Expanded(
                child: ValueListenableBuilder<List<String>>(
                  valueListenable: _log,
                  builder: (context, lines, _) => ListView(
                    padding: const EdgeInsets.all(12),
                    children: [
                      for (final line in lines)
                        Text(line, style: const TextStyle(fontFamily: 'monospace', fontSize: 12)),
                    ],
                  ),
                ),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
                child: Row(
                  children: [
                    Expanded(
                      child: TextField(
                        controller: _input,
                        decoration: const InputDecoration(hintText: 'prompt'),
                      ),
                    ),
                    const SizedBox(width: 8),
                    ValueListenableBuilder<bool>(
                      valueListenable: _busy,
                      builder: (context, busy, _) => ElevatedButton(
                        onPressed: busy ? null : _run,
                        child: const Text('send'),
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
