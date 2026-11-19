import 'package:orca_client/orca_client.dart';
import 'package:test/test.dart';

final readonlyRow = ConversationSummary(
  id: 'hist-1',
  agent: 'dsh',
  title: '只读历史',
  writable: false,
);

void main() {
  test('watch 事件序：snapshot 先于 batch，batch 带 cursor 与 itemId，end 收尾', () async {
    final b = FakeMobileChatBackend(scripted: true);
    final events = await b.watch('s1').take(3).toList();
    expect(events[0].kind, ChatEventKind.snapshot);
    expect(events[1].kind, ChatEventKind.batch);
    expect(events[1].cursor, isNotNull);
    expect(events[1].messages.first.itemId, isNotEmpty);
    expect(events[2].kind, ChatEventKind.end);
  });

  test('只读行 send 抛 notWritable，不静默成功', () async {
    final b = FakeMobileChatBackend(rows: [readonlyRow]);
    await expectLater(
      b.send(readonlyRow.id, 'x'),
      throwsA(isA<MobileBackendException>().having((e) => e.code, 'code', 'notWritable')),
    );
  });

  test('未声明的 capability 对应方法抛 notSupported', () async {
    final b = FakeMobileChatBackend(capabilities: {ChatCapability.send});
    expect(b.capabilities, isNot(contains(ChatCapability.approval)));
    await expectLater(
      b.respondApproval('s1', 'e1', ApprovalDecision.pass),
      throwsA(isA<MobileBackendException>().having((e) => e.code, 'code', 'notSupported')),
    );
  });
}
