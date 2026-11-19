import 'dart:async';
import 'dart:convert';

import 'package:web_socket_channel/web_socket_channel.dart';

import 'e2ee_legacy.dart';
import 'session_mutation.dart';

class OrcaRequestException implements Exception {
  final Map<String, dynamic> refusal;
  OrcaRequestException(this.refusal);

  @override
  String toString() => 'OrcaRequestException: ${jsonEncode(refusal)}';
}

/// A transport-level failure (socket dropped, reconnect in progress).
///
/// Distinct from [OrcaRequestException], which is a definitive host refusal.
/// [OrcaMobileBackend] retries on a transport failure (re-using the same
/// operation identity) and surfaces a definitive refusal as a stable error
/// code (spec §5.2, hard rule: no silent swallow, no infinite retry).
class OrcaTransportFailure implements Exception {
  const OrcaTransportFailure(this.message);
  final String message;

  @override
  String toString() => 'OrcaTransportFailure: $message';
}

/// The transport seam [OrcaMobileBackend] drives. The real host is
/// [LegacyOrcaClient]; tests stand in with a scripted rpc that replays host
/// frames at this level.
abstract interface class OrcaRpc {
  /// One sealed RPC. Resolves to the raw host frame (parsed by the caller).
  Future<Map<String, dynamic>> request(String method, Map<String, dynamic> params);

  /// A live session subscription: snapshot, then incremental batches, then end.
  Stream<Map<String, dynamic>> subscribe(String sessionId, {Map<String, dynamic>? cursor});

  Future<void> close();
}

Map<String, dynamic> requireMutationValue(Map<String, dynamic> result) {
  if (result['ok'] != true) {
    throw OrcaRequestException(
      Map<String, dynamic>.from(result['refusal'] as Map? ?? result),
    );
  }
  return Map<String, dynamic>.from(result['value'] as Map);
}

class LegacyOrcaClient implements OrcaRpc {
  final WebSocketChannel _socket;
  final Map<String, dynamic> _offer;
  final _key = generateClientSecretKey();
  late final _channel = channelFromSecretKey(_key);
  final _authenticated = Completer<void>();
  final _pending = <String, Completer<Map<String, dynamic>>>{};
  final _streams = <String, StreamController<Map<String, dynamic>>>{};
  late final StreamSubscription<dynamic> _incoming;
  bool _closed = false;
  bool _authSent = false;

  LegacyOrcaClient._(this._socket, this._offer);

  static Future<LegacyOrcaClient> connect(
    Uri endpoint,
    String pairingCode, {
    Duration timeout = const Duration(seconds: 30),
  }) async {
    final offer = jsonDecode(utf8.decode(base64.decode(base64.normalize(pairingCode.trim()))))
        as Map<String, dynamic>;
    if (offer['deviceToken'] is! String || offer['publicKeyB64'] is! String) {
      throw const FormatException('Pairing offer lacks device token or host public key');
    }
    final client = LegacyOrcaClient._(WebSocketChannel.connect(endpoint), offer);
    client._incoming = client._socket.stream.listen(
      client._receive,
      onError: (Object error) => client._fail(error),
      onDone: () => client._fail(StateError('Orca connection closed')),
    );
    final ready = client._authenticated.future.timeout(timeout);
    // Attach the error handler before asynchronous connection failures can arrive.
    unawaited(ready.then<void>((_) {}, onError: (Object _) {}));
    try {
      await client._socket.ready.timeout(timeout);
      if (client._closed) throw StateError('Orca connection closed');
      client._socket.sink.add(jsonEncode({
        'type': 'e2ee_hello',
        'publicKeyB64': clientPublicKeyB64Url(client._key),
      }));
      await ready;
      return client;
    } catch (_) {
      await client.close();
      rethrow;
    }
  }

  @override
  Future<Map<String, dynamic>> request(
    String method,
    Map<String, dynamic> params, {
    Duration timeout = const Duration(seconds: 30),
  }) async {
    if (_closed || !_authenticated.isCompleted) {
      throw StateError('Orca connection is not authenticated');
    }
    final id = newClientId();
    final response = Completer<Map<String, dynamic>>();
    _pending[id] = response;
    try {
      _send(id, method, params);
      return await response.future.timeout(timeout);
    } finally {
      _pending.remove(id);
    }
  }

  Stream<Map<String, dynamic>> subscribe(
    String sessionId, {
    Map<String, dynamic>? cursor,
  }) {
    final id = newClientId();
    late final StreamController<Map<String, dynamic>> controller;
    controller = StreamController<Map<String, dynamic>>(
      onListen: () {
        _streams[id] = controller;
        try {
          _send(id, 'agentSession.subscribe', {
            'sessionId': sessionId,
            if (cursor != null) 'cursor': cursor,
          });
        } catch (error, stack) {
          _streams.remove(id);
          controller.addError(error, stack);
          unawaited(controller.close());
        }
      },
      onCancel: () {
        _streams.remove(id);
        if (!_closed) {
          _send(newClientId(), 'agentSession.unsubscribe', {
            'sessionId': sessionId,
            'subscriptionId': id,
          });
        }
      },
    );
    return controller.stream;
  }

  void _send(String id, String method, Map<String, dynamic> params) {
    if (_closed || !_authenticated.isCompleted) {
      throw StateError('Orca connection is not authenticated');
    }
    _socket.sink.add(_channel.seal(jsonEncode({
      'id': id,
      'deviceToken': _offer['deviceToken'],
      'method': method,
      'params': params,
    })));
  }

  void _receive(dynamic raw) {
    if (_closed) return;
    try {
      final text = raw is String ? raw : utf8.decode(raw as List<int>);
      Map<String, dynamic>? plaintext;
      try {
        plaintext = jsonDecode(text) as Map<String, dynamic>;
      } on FormatException {
        // Authenticated RPC frames are encrypted base64, not plaintext JSON.
      }
      if (plaintext != null) {
        if (plaintext['type'] != 'e2ee_ready' || _authSent) {
          throw const FormatException('Unexpected plaintext handshake frame');
        }
        _authSent = true;
        _channel.acceptReady(_offer['publicKeyB64'] as String);
        _socket.sink.add(_channel.seal(jsonEncode({
          'type': 'e2ee_auth',
          'deviceToken': _offer['deviceToken'],
          'clientCapabilities': [
            'agent-session.structured.v1',
            'agent-session.structured.registered-agents.v1',
            'agentSession.create.message.v1',
          ],
        })));
        return;
      }
      final decoded = _channel.open(text);
      if (decoded == null) throw const FormatException('Invalid encrypted frame');
      final message = jsonDecode(decoded) as Map<String, dynamic>;
      if (message['type'] == 'e2ee_authenticated') {
        if (!_authenticated.isCompleted) _authenticated.complete();
        return;
      }
      final id = message['id'];
      final stream = _streams[id];
      if (message['ok'] == false) {
        final error = OrcaRequestException(
          Map<String, dynamic>.from(message['error'] as Map? ?? {'code': 'rpc_error'}),
        );
        if (stream != null) {
          _streams.remove(id);
          stream.addError(error);
          unawaited(stream.close());
        } else {
          _pending.remove(id)?.completeError(error);
        }
      } else if (stream != null && message['streaming'] == true) {
        final event = Map<String, dynamic>.from(message['result'] as Map);
        stream.add(event);
        if (event['type'] == 'end') {
          _streams.remove(id);
          unawaited(stream.close());
        }
      } else if (message['ok'] == true) {
        final pending = _pending.remove(id);
        if (pending != null) {
          pending.complete(Map<String, dynamic>.from(message['result'] as Map));
        }
      }
    } catch (error) {
      _fail(error);
    }
  }

  void _fail(Object error) {
    if (_closed) return;
    _closed = true;
    if (!_authenticated.isCompleted) _authenticated.completeError(error);
    for (final pending in _pending.values) {
      pending.completeError(error);
    }
    _pending.clear();
    for (final stream in _streams.values.toList()) {
      stream.addError(error);
      unawaited(stream.close());
    }
    _streams.clear();
    unawaited(_socket.sink.close());
  }

  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    for (final stream in _streams.values.toList()) {
      stream.addError(OrcaTransportFailure('Orca client closed'));
      unawaited(stream.close());
    }
    _streams.clear();
    for (final pending in _pending.values.toList()) {
      pending.completeError(OrcaTransportFailure('Orca client closed'));
    }
    _pending.clear();
    await _incoming.cancel();
    await _socket.sink.close();
  }
}
