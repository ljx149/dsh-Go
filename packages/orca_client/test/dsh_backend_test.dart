import 'package:dsh_client/dsh_client.dart';
import 'package:orca_client/orca_client.dart';
import 'package:test/test.dart';

/// Scripted carrier: resolves unary RPC to canned `RpcOk` values and never
/// opens a mux link (the mapping layer exercises history/prompt, both unary).
/// Records every endpoint call so tests can assert the wire shape.
class _FakeCarrier implements DshCarrier {
  Map<String, Object?>? Function(String endpoint, Map<String, Object?> args)? responder;
  final List<Map<String, Object?>> sent = [];

  _FakeCarrier({this.responder});

  @override
  String get kind => 'fake';

  @override
  String? get hostVersion => null;

  @override
  DshTracer? get tracer => null;

  @override
  bool get supportsUplink => false;

  @override
  bool allowsEndpoint(String endpoint) => true;

  @override
  Set<String>? get peerCapabilities => null;

  @override
  Future<RpcResult> call(String endpoint, Map<String, Object?> args, {Duration? timeout}) async {
    sent.add({'endpoint': endpoint, 'args': args});
    if (responder != null) return RpcOk(responder!(endpoint, args));
    return const RpcOk(null);
  }

  @override
  Future<DshMuxLink> openLink(MuxOptions options) async => throw StateError('no mux in fake');

  @override
  Future<void> close() async {}
}

void main() {
  late _FakeCarrier carrier;
  late DshClient client;
  late DshMobileBackend backend;

  Map<String, Object?> pageValue(
    List<Map<String, Object?>> records,
    bool hasMore,
  ) => {'records': records, 'hasMore': hasMore};

  setUp(() {
    carrier = _FakeCarrier();
    client = DshClient.withCarrier(carrier);
    backend = DshMobileBackend(
      client: client,
      connectionSource: () => const Stream<ConnectionSignal>.empty(),
    );
  });

  test('history 映射：SessionLogEvent → ChatMessage 保持 seq/role/itemId/text', () async {
    carrier.responder = (endpoint, args) {
      if (endpoint == 'session/page') {
        return pageValue([
          {
            'event': {
              'seq': 1,
              'time': 1000,
              'type': 'user/message',
              // user/message parses the message from the data top level.
              'data': {
                'id': 'msg-1',
                'role': 'user',
                'content': [
                  {'type': 'text', 'text': 'hello'}
                ],
                'source': {'kind': 'user'}
              }
            }
          },
          {
            'event': {
              'seq': 2,
              'time': 2000,
              'type': 'assistant/message',
              // assistant/message parses the message from data['message'].
              'data': {
                'turn': 0,
                'step': 0,
                'message': {
                  'id': 'msg-2',
                  'role': 'assistant',
                  'content': [
                    {'type': 'text', 'text': 'hi'}
                  ],
                  'source': {'kind': 'runtime'}
                }
              }
            }
          }
        ], true);
      }
      return null;
    };
    final page = await backend.history('s1', throughSeq: 2);
    expect(page.hasMore, true);
    expect(page.messages.length, 2);
    expect(page.messages[0].seq, 1);
    expect(page.messages[0].itemId, 'msg-1');
    expect(page.messages[0].role, 'user');
    expect(page.messages[0].text, 'hello');
    expect(page.messages[1].seq, 2);
    expect(page.messages[1].itemId, 'msg-2');
    expect(page.messages[1].role, 'assistant');
    expect(page.messages[1].text, 'hi');
  });

  test('history 游标：beforeSeq 透传到 wire 的 request', () async {
    carrier.responder = (endpoint, args) {
      if (endpoint == 'session/page') {
        final req = args['request'] as Map;
        expect(req['beforeSeq'], 5);
        expect(req['throughSeq'], 10);
        return pageValue([], false);
      }
      return null;
    };
    final page = await backend.history('s1', throughSeq: 10, beforeSeq: 5);
    expect(page.hasMore, false);
    expect(page.messages, isEmpty);
  });

  test('send 映射为 session/prompt，sessionId 透传', () async {
    carrier.responder = (endpoint, args) {
      if (endpoint == 'session/prompt') {
        final req = args['request'] as Map;
        expect(req['sessionId'], 's1');
        return null;
      }
      return null;
    };
    await backend.send('s1', 'hi');
    expect(carrier.sent.last['endpoint'], 'session/prompt');
  });

  test('capabilities 含 DSH 特有能力（subagentRouting/mux/terminal 等）', () {
    final caps = backend.capabilities;
    expect(caps, containsAll([
      ChatCapability.subagentRouting,
      ChatCapability.mux,
      ChatCapability.terminalSession,
      ChatCapability.lifecycleStatus,
      ChatCapability.logExport,
      ChatCapability.transcribe,
      ChatCapability.fileUpload,
      ChatCapability.bundleList,
      ChatCapability.pluginEvents,
      ChatCapability.send,
      ChatCapability.approval,
      ChatCapability.modelCatalog,
      ChatCapability.historyPaging,
    ]));
  });
}
