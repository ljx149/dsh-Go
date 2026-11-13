import 'dart:convert';
import 'dart:io';

import 'package:dsh_remote/src/server/server_api.dart';
import 'package:test/test.dart';

void main() {
  test('device exchange sends only proofs and accepts account plus tokens', () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final api = RemoteServerApi('http://127.0.0.1:${server.port}');
    addTearDown(() async {
      api.close();
      await server.close(force: true);
    });
    final handled = server.first.then((request) async {
      expect(request.method, 'POST');
      expect(request.uri.path, '/api/v1/auth/device/exchange');
      final body = jsonDecode(await utf8.decodeStream(request)) as Map;
      expect(body.keys, unorderedEquals(['requestId', 'pickupToken', 'code', 'codeVerifier']));
      for (final value in body.values) {
        expect(value, matches(RegExp(r'^[A-Za-z0-9_-]{43}$')));
      }
      request.response.headers.contentType = ContentType.json;
      request.response.write(jsonEncode({
        'deviceId': 'test-device',
        'account': 'test@example.invalid',
        'userId': 'test-user',
        'accessToken': 'synthetic-access-token',
        'accessTokenExpiresAt': 2000000000000,
        'refreshToken': 'synthetic-refresh-token',
        'refreshTokenExpiresAt': 2000000100000,
      }));
      await request.response.close();
    });
    final result = await api.exchangeDeviceLogin('r' * 43, 'p' * 43, 'c' * 43, 'v' * 43);
    await handled;
    expect(result.deviceId, 'test-device');
    expect(result.account, 'test@example.invalid');
    expect(result.userId, 'test-user');
    expect(result.tokens.accessToken, 'synthetic-access-token');
    expect(result.tokens.refreshToken, 'synthetic-refresh-token');
  });
}
