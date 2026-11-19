# Orca 移动端接入 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 在 dsh-Go 正式 App 里接入 Orca 作为与 local/ssh/relay 并列的第四种主机：主机→目录→会话导航、新建/续聊、流式聊天、审批、模型切换、双端输入、断线恢复，全部走 `MobileChatBackend` 抽象，不伪造 DshClient。

**Architecture:** `packages/orca_client`（纯 Dart、双端唯一维护来源）新增 `MobileChatBackend` 接口与共享消息模型，DSH 与 Orca 各一份实现：`DshMobileBackend` 把现有 `DshClient` 的调用面映射到接口，`OrcaMobileBackend` 在已有 `LegacyOrcaClient`（配对/E2EE/RPC/订阅）上加 §5.2 操作身份管理与 §5.6 恢复状态机。App 侧加 `HostKind.orca`，按活跃主机选后端；UI 不再直连 `DshClient`，DSH 特有入口按 capabilities 显式缺失而隐藏（不填空实现）。

**Tech Stack:** Dart 3 / Flutter、Riverpod 3、pinenacl（E2EE，已有）、web_socket_channel（已有）、flutter_secure_storage（经现有 `SecretStore` 抽象）。

**Spec:** `docs/design/orca-mobile-link.md`（§1–§8，P0 已闭环结论是其前提，不再重复验证）。

## 已盘点的 UI 调用面（Task 1 的输入，实施时以代码为准复核）

`DshClient` 在 UI 的方法调用（`app/lib/ui/`、`app/lib/state/`，40+ 处去重后）分两类：

- **通用聊天语义**（接口必须覆盖）：`listSessions`、`history`（throughSeq/beforeSeq 游标分页，返回 `HistoryPage{events, hasMore}`）、`watch`（snapshot→连续事件→deltas，socket 丢失自动重开 follow+重同步）、`createSession`（workspaceId/cwd/agentPreset/sessionId）、`prompt`（requestId 幂等）、`cancel`、`respondApproval`/`respondHostEvent`、队列（`updateQueue` 等）、`listModels`/`setModel`/`setModelResult`、`renameSession`/`archiveSession`/`unarchiveSession`。
- **DSH 特有语义**（Orca 实现显式缺失，UI 隐藏入口）：`mux`、`routeSubagent`/`promptSubagent`、`watchWorkspaces`、`pluginManagerEvents`、`getLifecycleStatus`/`acknowledgeLifecycleUnknown`、`exportSessionLog`/`canExportSessionLog`、`transcribe`、`upload`/`statFile`/`canReadFileBytes`/`supportsFileUpload`、`listBundles`、`watchSessionControl`。

## Global Constraints

（取自 spec，每条任务的隐含前提）

- **create/send 分离**（§5.2，P0 已验证）：新建会话带首条消息 → firstMessage 自动入队投递，**之后不能再发同一条**；已有会话续聊只 send。重试不换操作身份：同一 `clientOperationId` 不同指纹 → host 拒 `fingerprintMismatch`；同指纹重放 → 回放原结果 `replayed: true`。
- **操作身份格式**（§6）：`clientOperationId` = `<13位ms时间戳>-<32位无连字符hex>`（`session_mutation.dart` 已有 `newOperationId`，直接用）；create 的 `expectedRuntimeFence` 为 null，之后的 send 用 host 返回的 fence。
- **能力边界**（§3.2/§4）：Orca 无 `worktree.watch`，刷新机制 = 切主机时全量 list 一次 + 会话增删事件触发后按需重 list，不假装持续监听。DSH 特有语义 Orca 显式返回缺失，UI 隐藏入口，**不填空实现、不假成功**。
- **会话 ID 三层语义**（§3.3）：有 `structuredSession` → 走 `agentSession.*`（可续聊/审批/模型切换）；无 → 纯历史记录行只读展示，不伪装可写。业务层显式保存 agent 身份，`raw['agent']` 仅兜底。
- **模型**（§5.5）：`agentSession.modelCatalog` 读主机实际可用模型；切换走 `agentSession.setOption` 并从 host 回读结果，不只改本地显示。
- **提交状态**（§5.6）：`dispatchState: pending/accepted` 明确显示"仍在等待"或"失败"，不吞错误；订阅成功 ≠ 恢复完成。
- **凭据**（§3.2/§8）：endpoint + pairingCode 走 `flutter_secure_storage`（经现有 `SecretStore` 抽象），不进仓库任何文件、不进日志。
- **双语文案**（硬规则）：新增界面文案改 `app/lib/l10n/parts/*.arb`，中英文同步，再跑 `python3 app/tool/l10n_merge.py`。
- **DSH 运行时不变**：Orca 是并列新连接类型，不改 DSH 主机的运行时字节与行为（Android 基线）。
- **验收口径**（§8）：实现完成后统一标注"尚未验收"，逐项留证据；不宣称已可上线。

## Review Focus

spec 隐含但无任务测试覆盖、最可能咬人的输入/故障模式（每行已把固定它的测试加进所属任务）：

1. **发送失败后重试换了 opId 或指纹** → host 拒 `fingerprintMismatch`，或换 ID 造成重复投递。→ Task 2（重试保身份测试）。
2. **create 带 firstMessage 后又发同一条** → 重复提交。→ Task 2（create 后不重放首条测试）。
3. **无 structuredSession 的只读历史行被当成可写会话打开** → 出现发送入口、提交必失败。→ Task 6（widget 测试断言只读行无发送入口）。
4. **主机重启 fence 变化后仍用旧 fence 发送** → host 拒，用户看到不可理解的失败。→ Task 2（fence 变化重 attach 测试）。
5. **双端同时提交/同条消息 snapshot 与 batch 重叠** → UI 渲染同一消息两次或串会话。→ Task 2（itemId 去重测试）；双端裁决正确性是 host 侧行为，列入 §8 真机验收，不在单测范围。

---

### Task 1: 共享消息模型 + `MobileChatBackend` 接口 + `FakeMobileChatBackend`

**Files:**
- Create: `packages/orca_client/lib/src/backend_types.dart`
- Create: `packages/orca_client/lib/src/mobile_chat_backend.dart`
- Create: `packages/orca_client/lib/src/fake_mobile_chat_backend.dart`
- Modify: `packages/orca_client/lib/orca_client.dart`（导出上述三个）
- Test: `packages/orca_client/test/fake_backend_contract_test.dart`

**Interfaces:**
- Produces（后续任务全部依赖这些名字与类型）：

```dart
// backend_types.dart
class ConversationSummary {          // §3.2 listConversations 行
  final String id;                   // structuredSession.sessionId，或只读行的 provider sessionId
  final String agent;                // 显式保存的 agent 身份
  final String title;
  final String? cwd;
  final String? branch;
  final String? model;
  final bool running;
  final bool writable;               // false = 无 structuredSession 的只读历史行
}

class ChatMessage {                  // 双端共用的消息模型（UI 渲染唯一输入）
  final int seq;                     // journal 序号（游标语义）
  final String itemId;               // 去重键（§5.6）
  final String role;                 // user / assistant / tool / ...
  final List<ChatBlock> blocks;      // 至少 {'type':'text','text':...}；tool 块保留类型名
  final DateTime? timestamp;
}

class ChatHistoryPage { final List<ChatMessage> messages; final bool hasMore; }
// 注意：不与 dsh_client 的 HistoryPage 同名混用；Task 3 负责映射。

enum ChatEventKind { snapshot, batch, end }
class ChatEvent {                    // §5.1 事件形态
  final ChatEventKind kind;
  final int? cursor;                 // batch 携带；snapshot 为 null
  final List<ChatMessage> messages;
}

enum ChatCapability {
  historyPaging, createWithFirstMessage, send, cancel, queue,
  approval, question, modelCatalog, setModel, rename, archive,
  worktreeList,
  // DSH 特有（Orca 实现不声明，UI 据此隐藏入口）：
  subagentRouting, terminalSession, mux, pluginEvents,
  lifecycleStatus, logExport, transcribe, fileUpload, bundleList,
}

enum ConnectionSignalKind { connected, disconnected, reconnecting, hostSwitched }
class ConnectionSignal { final ConnectionSignalKind kind; final String? detail; }

enum QueueAction { send, delete, move, update }   // §3.2 queuedMessage* 语义

class MobileBackendException implements Exception {
  final String code;                 // 稳定错误码（硬规则）：fingerprintMismatch / replayed / fenceMismatch / notWritable / notSupported / ...
  final String message;
  final bool retriable;              // 可恢复 vs 明确失败（硬规则：不许静默吞）
}
```

```dart
// mobile_chat_backend.dart
abstract interface class MobileChatBackend {
  Set<ChatCapability> get capabilities;
  Stream<ConnectionSignal> get connectionState;
  Future<List<ConversationSummary>> listConversations();
  Future<ConversationSummary> openConversation(String id);   // 打开时即给出可写性与 agent 身份
  Future<ChatHistoryPage> history(String id, {required int throughSeq, int? beforeSeq});
  Stream<ChatEvent> watch(String id, {int? fromSeq});        // snapshot → batch(游标) → end
  Future<({String sessionId, int fence})> createSession({required String agent, String? worktreeId, String? firstMessage});
  Future<void> send(String id, String text);                 // 操作身份由实现内部管理，调用方不感知
  Future<void> cancel(String id);
  Future<void> queueAdd(String id, String text);
  Future<void> queueAction(String id, String itemId, QueueAction action);
  Future<void> respondApproval(String id, String eventId, ApprovalDecision decision);
  Future<void> respondQuestion(String id, String eventId, String answer);
  Future<List<ModelInfo>> modelCatalog();                   // ModelInfo {id, label, vendor}
  Future<String> setModel(String id, String modelId);       // 返回 host 回读的实际生效值
  Future<void> close();
}
```

`FakeMobileChatBackend`：脚本化的完整实现，供 UI widget 测试与后续任务用。它必须忠实遵守契约：`watch` 先 snapshot 后 batch 后 end、batch 带 cursor 与 itemId；`writable: false` 的行调 `send` 抛 `MobileBackendException(code: 'notWritable')`；未声明的 capability 对应方法抛 `code: 'notSupported'`。

- [ ] **Step 1: 写失败的契约测试**

`fake_backend_contract_test.dart` 至少三条：

```dart
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
  await expectLater(b.send(readonlyRow.id, 'x'),
    throwsA(isA<MobileBackendException>().having((e) => e.code, 'code', 'notWritable')));
});
test('未声明的 capability 对应方法抛 notSupported', () async {
  final b = FakeMobileChatBackend(capabilities: {ChatCapability.send});
  expect(b.capabilities, isNot(contains(ChatCapability.approval)));
  await expectLater(b.respondApproval('s1', 'e1', ApprovalDecision.pass),
    throwsA(isA<MobileBackendException>().having((e) => e.code, 'code', 'notSupported')));
});
```

- [ ] **Step 2: 跑测试确认失败**

Run: `cd packages/orca_client && dart test`
Expected: FAIL（`MobileChatBackend`/`FakeMobileChatBackend` 不存在，编译不过）。

- [ ] **Step 3: 实现三个文件**

按 Interfaces 块的原样签名实现。`FakeMobileChatBackend` 用构造参数脚本化行为（capabilities、行数据、watch 事件脚本），不做真实网络。`ApprovalDecision`、`ModelInfo` 若或ca_client 无既有类型则在本文件定义（与 dsh_client 的同名类型互不 import，避免循环依赖）。

- [ ] **Step 4: 跑测试确认通过 + analyze**

Run: `cd packages/orca_client && dart pub get && dart analyze && dart test`
Expected: 全绿。

- [ ] **Step 5: 提交**

```bash
git add packages/orca_client/lib/src/backend_types.dart \
        packages/orca_client/lib/src/mobile_chat_backend.dart \
        packages/orca_client/lib/src/fake_mobile_chat_backend.dart \
        packages/orca_client/lib/orca_client.dart \
        packages/orca_client/test/fake_backend_contract_test.dart
git commit -m "orca_client: MobileChatBackend 接口、共享消息模型与契约测试用假后端"
```

---

### Task 2: `OrcaMobileBackend`（§5.2 操作身份 + §5.6 恢复状态机）

**Files:**
- Create: `packages/orca_client/lib/src/orca_mobile_backend.dart`
- Modify: `packages/orca_client/lib/src/legacy_rpc_client.dart`（给 `connect` 加可选 `channelFactory` 测试接缝）
- Test: `packages/orca_client/test/orca_backend_test.dart`

**Interfaces:**
- Consumes: Task 1 的全部类型；已有的 `LegacyOrcaClient.connect/request/subscribe`、`createSessionRequest`/`sendSessionRequest`/`newOperationId`/`sessionPayloadFingerprint`（`session_mutation.dart`）。
- Produces: `OrcaMobileBackend implements MobileChatBackend`，构造签名：
  `OrcaMobileBackend({required Uri endpoint, required String pairingCode, Future<LegacyOrcaClient> Function(Uri, String)? connectForTest})`。
  能力声明（§3.3/§4 的如实边界）：`historyPaging, createWithFirstMessage, send, cancel, queue, approval, question, modelCatalog, setModel, worktreeList`；**不声明** DSH 特有项。无 `worktree.watch`：`listConversations` 在切主机时全量调一次 `worktree.list`/会话 list，会话增删事件到达后按需重 list（§4 的刷新机制）。

- [ ] **Step 1: 写失败的测试（Review Focus 1/2/4/5 的落点）**

`orca_backend_test.dart`，用脚本化假 host（经 `channelFactory` 注入的假 channel，走真实 E2EE 通道加密，帧脚本按 §5.2/§6 的 host 语义回放）：

```dart
test('create 带 firstMessage 返回 sessionId 与 fence；之后同一条不重发（P0 规则）', () async {
  // backend.createSession(agent:'dsh', firstMessage:'hi') → host 回执 {ok, value:{fence: N}}
  // 断言 wire 上只出现一次 agentSession.create（firstMessage 自动入队）；
  // backend 内部把该条消息的 itemId 记为已投递，恢复快照里出现同 itemId 时不产生第二次提交。
});
test('发送失败重试保操作身份：同 opId 同指纹 → host 回 replayed:true，客户端不重复入队', () async {
  // 第一次 send 后 transport 断，重试时 host 对同指纹回 {replayed: true, 原结果}。
  // 断言重试帧的 clientOperationId 与 payloadFingerprint 不变，且结果按原结果处理（不抛、不当新提交）。
  // 对照组：换指纹同 opId → host 拒 fingerprintMismatch，backend 抛 MobileBackendException(code:'fingerprintMismatch', retriable:false)。
});
test('fence 变化后重新 attach，旧 fence 发送被拒', () async {
  // 模拟主机重启：subscribe 收到 fence 变化信号。
  // 断言 backend 用新 fence 重新 attach 后再 send；直接拿旧 fence send 得到 fenceMismatch 且被转换为 re-attach 而非终态失败。
});
test('snapshot 与 batch 重叠时按 itemId 去重（双端同条消息不渲染两次）', () async {
  // 脚本：batch(游标 N, 含 itemId X) 之后 snapshot 覆盖又含 itemId X。
  // 断言 watch 流里 itemId X 只出现一次。
});
test('dispatchState 语义：pending/accepted 如实透出，不吞错误', () async {
  // host 回 accepted → send 返回成功且状态为 accepted；transport 失败 → 抛可重试错误码，不静默。
});
```

- [ ] **Step 2: 跑测试确认失败**

Run: `cd packages/orca_client && dart test test/orca_backend_test.dart`
Expected: FAIL（`OrcaMobileBackend` 不存在）。

- [ ] **Step 3: 实现**

- `legacy_rpc_client.dart`：`connect` 增加可选 `channelFactory: (Uri) => WebSocketChannel` 参数，默认 `WebSocketChannel.connect`；不改任何既有行为。
- `orca_mobile_backend.dart`：包装 `LegacyOrcaClient`；内部维护（a）每会话的 fence 与最近 cursor，(b) 已投递 itemId 集合（去重，§5.6），(c) 操作身份登记（opId ↔ fingerprint，保证重试不换身份，§5.2）。`watch` 把 wire 的 `snapshot`/`batch`/`end` 事件映射为 Task 1 的 `ChatEvent`（wire item 的 `body.role`/`body.blocks` → `ChatMessage`）。恢复状态机 = 断线后按 cursor 重新 subscribe、snapshot 覆盖本地、itemId 去重、fence 变化重新 attach（§5.6，实现一次，双端共用）。create 的 `expectedRuntimeFence: null`、send 用 host 返回的 fence——`session_mutation.dart` 已有，直接复用。`listModels`/`setModel` 走 `agentSession.modelCatalog`/`agentSession.setOption`，setModel 回读 host 结果再返回（§5.5）。

- [ ] **Step 4: 跑测试确认通过 + 既有回归**

Run: `cd packages/orca_client && dart analyze && dart test`
Expected: 新测试 PASS，且既有包测试（若有）不回归。

- [ ] **Step 5: 提交**

```bash
git add packages/orca_client/lib/src/orca_mobile_backend.dart \
        packages/orca_client/lib/src/legacy_rpc_client.dart \
        packages/orca_client/test/orca_backend_test.dart
git commit -m "orca_client: OrcaMobileBackend 实现，含操作身份管理与断线恢复状态机"
```

---

### Task 3: `DshMobileBackend`（把现有 DshClient 映射到接口）

**Files:**
- Create: `packages/orca_client/lib/src/dsh_mobile_backend.dart`
- Modify: `packages/orca_client/pubspec.yaml`（加 `dsh_client: path: ../dsh_client`）
- Test: `packages/orca_client/test/dsh_backend_test.dart`

**Interfaces:**
- Consumes: Task 1 接口；`dsh_client` 的 `DshClient`（构造方式与测试假载体参照 `packages/dsh_client/test/client_test.dart` 的既有惯例，不另造协议）。
- Produces: `DshMobileBackend implements MobileChatBackend`，构造：`DshMobileBackend({required DshClient client, required Stream<ConnectionSignal> Function() connectionSource})`。能力声明：通用项全有 + DSH 特有项全有（`subagentRouting` 等）。`history` 把 dsh_client 的 `HistoryPage{events}` 映射为 `ChatHistoryPage{messages}`（`SessionLogEvent` → `ChatMessage`：seq=itemId 来源、role、blocks、timestamp）；`watch` 把 `DshClient.watch` 的流映射为 `ChatEvent`（snapshot 事件 → `ChatEventKind.snapshot`，follow 事件 → `batch`，流终结 → `end`）。DSH 的 requestId 幂等语义映射到接口：`send` 内部生成 requestId，重试复用同 ID。

- [ ] **Step 1: 写失败的测试**

```dart
test('SessionLogEvent → ChatMessage 映射保持 seq/role/blocks/itemId', () async {
  // 假载体回放 session/page 与 watch 的既有 wire 形态（参照 dsh_client 测试样例），
  // 断言 ChatMessage.seq == 事件 seq、itemId 非空且稳定、text 块内容一致。
});
test('history 游标映射：throughSeq/beforeSeq 语义不变，hasMore 透传', () async {
  // 两次翻页：第一次 throughSeq=tail，第二次 beforeSeq=第一页最旧 seq，断言不重不漏。
});
test('capabilities 含 DSH 特有能力，watch 映射为 snapshot/batch/end 三种形态', () async {
  // 断言 capabilities 含 subagentRouting/mux 等；watch 流形态与 Task 1 契约一致。
});
```

- [ ] **Step 2: 跑测试确认失败**

Run: `cd packages/orca_client && dart pub get && dart test test/dsh_backend_test.dart`
Expected: FAIL（`DshMobileBackend` 不存在）。

- [ ] **Step 3: 实现映射层**

纯映射，不加业务逻辑；DSH 侧的排队/审批/模型方法一一对应 `DshClient` 同名方法，错误翻译为 `MobileBackendException`（稳定错误码，硬规则）。

- [ ] **Step 4: 跑测试确认通过 + analyze + dsh_client 自身回归**

Run: `cd packages/orca_client && dart analyze && dart test && cd ../dsh_client && dart analyze && dart test`
Expected: 全绿（dsh_client 零改动，回归只是确认依赖关系没弄坏它）。

- [ ] **Step 5: 提交**

```bash
git add packages/orca_client/lib/src/dsh_mobile_backend.dart \
        packages/orca_client/pubspec.yaml packages/orca_client/pubspec.lock \
        packages/orca_client/test/dsh_backend_test.dart
git commit -m "orca_client: DshMobileBackend 映射层，DSH 调用面接入统一接口"
```

---

### Task 4: `HostKind.orca` + 配对凭据安全存储

**Files:**
- Modify: `app/lib/state/hosts_state.dart`（`HostKind` 加 `orca`；`HostRef` 加 `orca` 构造与 decode 分支；`hostLabel` 加 case）
- Create: `app/lib/remote/orca/orca_host_config.dart`（Orca 主机配置：endpoint 进 SharedPreferences、pairingCode 进 `SecretStore`，与 SSH 同模式）
- Modify: `app/lib/l10n/parts/state_zh.arb` 与 `state_en.arb`（新主机的标签文案，中英同步）
- Test: `app/test/orca_host_config_test.dart`

**Interfaces:**
- Produces: `HostRef.orca(String id)`；`OrcaHostConfig {id, endpoint, name?}` + `OrcaHostConfigController`（save/remove/load，pairingCode 经 `secretStoreProvider` 存删，参照 `HostsController._writeSecrets` 的模式）；l10n key 命名照 `stateSshHost` 惯例。

- [ ] **Step 1: 写失败的测试**

```dart
test('HostRef.orca 编解码往返不丢字段', () {
  final r = HostRef.orca('o1');
  expect(HostRef.decode(r.encode()), r);
  expect(r.kind, HostKind.orca);
});
test('pairingCode 走 SecretStore：写入后可读、删除后为空，endpoint 不进 secret 存储', () async {
  // 用 MemorySecretStore override secretStoreProvider（既有测试惯例）：
  // save 后 secretStore 里只有 pairingCode，prefs 里只有 endpoint/名称；
  // remove 后两者都清。
});
test('hostLabel(HostKind.orca, name) 返回 l10n 文案且中英 key 都存在', () {
  // 断言 hostLabel 不抛、命中 arb 新 key；l10n_merge.py --check 通过。
});
```

- [ ] **Step 2: 跑测试确认失败**

Run: `cd app && flutter test test/orca_host_config_test.dart`
Expected: FAIL（`HostKind.orca` 不存在）。

- [ ] **Step 3: 实现**

`HostRef.decode` 加 `'orca'` 分支（既有 unknown-kind 回落 local 的兜底不动）。`hostLabel` 的 switch 加 orca 分支用新 l10n key。**l10n 硬规则**：zh/en arb 同步改，跑 `python3 app/tool/l10n_merge.py` 再生成，不手改生成物。

- [ ] **Step 4: 跑测试确认通过 + 文案检查**

Run: `cd app && flutter analyze && flutter test test/orca_host_config_test.dart && python3 app/tool/l10n_merge.py --check`
Expected: PASS。

- [ ] **Step 5: 提交**

```bash
git add app/lib/state/hosts_state.dart app/lib/remote/orca/ \
        app/lib/l10n/parts/state_zh.arb app/lib/l10n/parts/state_en.arb \
        app/test/orca_host_config_test.dart
git commit -m "app: HostKind.orca 与配对凭据安全存储（SecretStore，不进仓库/日志）"
```

---

### Task 5: 连接 provider 与后端选择（HostChip 机器切换复用）

**Files:**
- Create: `app/lib/remote/orca/orca_connection.dart`（orca 连接控制器：按 endpoint+pairingCode 连出 `OrcaMobileBackend`，暴露 `ConnectionSignal` 流，断线回前台自动重连——与 relay 的恢复语义对齐，§5.6）
- Modify: `app/lib/state/connection_state.dart` 或 `hosts_state.dart`（新增 `mobileChatBackendProvider`：读 `activeHostProvider`，orca → `OrcaMobileBackend`，其余 → `DshMobileBackend` 包 `HostConnection.client`）
- Test: `app/test/orca_backend_selection_test.dart`

**Interfaces:**
- Consumes: Task 2 的 `OrcaMobileBackend`、Task 3 的 `DshMobileBackend`、Task 4 的 `OrcaHostConfig`/`HostRef.orca`、既有 `HostConnection`/`secretStoreProvider`/`activeHostProvider`。
- Produces: `mobileChatBackendProvider: Provider<MobileChatBackend>`——UI 唯一入口（Task 6 的输入）。切主机时旧后端 `close()`，新后端重建；`connectionState` 流合并进既有连接状态展示（断开/重连/主机切换信号，§3.2）。

- [ ] **Step 1: 写失败的测试**

```dart
test('activeHost 为 orca 时 mobileChatBackendProvider 给出 OrcaMobileBackend，且 capabilities 不含 DSH 特有能力', () {
  // override activeHostProvider 为 HostRef.orca，注入假 OrcaMobileBackend（或经 connectForTest 假连接），
  // 断言 provider 值类型与 capabilities。
});
test('切回本机/SSH 时 provider 换回 DshMobileBackend，旧后端被 close', () {
  // 断言旧后端的 close() 被调用一次（不泄漏 socket），新后端是 DshMobileBackend。
});
test('orca 断线后重连成功，connectionState 依次给出 disconnected → reconnecting → connected', () async {
  // 假连接脚本：第一次连上即断，第二次成功。断言信号序与会话状态不丢（§5.6）。
});
```

- [ ] **Step 2: 跑测试确认失败**

Run: `cd app && flutter test test/orca_backend_selection_test.dart`
Expected: FAIL（provider 不存在）。

- [ ] **Step 3: 实现**

后端选择是纯 provider 逻辑：`switch (host.kind) { HostKind.orca => orca 连接, _ => DshMobileBackend(...) }`。不引入全局开关——能力差异由 `capabilities` 表达（硬规则：不全局放开或关闭）。

- [ ] **Step 4: 跑测试确认通过 + analyze**

Run: `cd app && flutter analyze && flutter test test/orca_backend_selection_test.dart`
Expected: PASS。

- [ ] **Step 5: 提交**

```bash
git add app/lib/remote/orca/orca_connection.dart app/lib/state/connection_state.dart \
        app/test/orca_backend_selection_test.dart
git commit -m "app: mobileChatBackendProvider 按主机类型选后端，orca 断线自动重连"
```

---

### Task 6: 正式 App 入口接入 + DSH 特有入口按能力隐藏

**Files:**
- Modify: `app/lib/ui/chat/chat_screen.dart`、`app/lib/state/sessions_state.dart`、`app/lib/ui/shell/drawer/drawer_list.dart`、`app/lib/ui/shell/drawer/session_tile.dart`、新建会话入口（以 `mobileChatBackendProvider` 替换直接 `DshClient` 调用；消息渲染从 `SessionLogEvent`/`DshEvent` 迁到 `ChatMessage`）
- Modify: `app/lib/l10n/parts/*.arb`（新增能力缺失提示等文案，中英同步）
- Test: `app/test/orca_ui_entries_test.dart`（widget 测试）

**Interfaces:**
- Consumes: `mobileChatBackendProvider`（Task 5）、`ConversationSummary.writable`（Task 1）。
- Produces: 正式会话列表/聊天页/新建流程走统一后端；DSH 主机行为零变化（回归保护）。

- [ ] **Step 1: 写失败的 widget 测试（Review Focus 3 的落点 + 防锁死回归）**

```dart
testWidgets('orca 主机：DSH 特有入口（mux/terminal/插件/日志导出等）不渲染', (tester) async {
  // override mobileChatBackendProvider 为 capabilities 不含 DSH 特有能力的前端假后端，
  // 泵入聊天页与抽屉，断言这些入口 widget 不存在（不是点了无反应的按钮，是完全不渲染）。
});
testWidgets('本机/SSH 主机：DSH 特有入口仍渲染（防把功能锁死）', (tester) async {
  // 同上但 capabilities 全有，断言入口存在。
});
testWidgets('无 structuredSession 的只读行：不出现发送入口与新建排队操作', (tester) async {
  // 抽屉里注入 writable:false 的行，点开聊天页断言无输入框/发送按钮，显示只读历史与说明文案。
});
testWidgets('切换主机时聊天回到“新对话”，不串会话', (tester) async {
  // 沿用 ActiveHostController.select 的既有语义（hosts_state.dart:351-362 已有 select(null)），
  // 断言切到 orca 后聊天页不残留旧主机的会话内容。
});
```

- [ ] **Step 2: 跑测试确认失败**

Run: `cd app && flutter test test/orca_ui_entries_test.dart`
Expected: FAIL（UI 仍直连 DshClient，无 capabilities 分支）。

- [ ] **Step 3: 迁移 UI 调用面**

聊天页、会话列表、新建流程改从 `mobileChatBackendProvider` 取后端；消息渲染改用 `ChatMessage`（Task 1 模型），视觉与交互沿用现有样式（§1）。DSH 特有入口加 `capabilities.contains(...)` 守卫；能力缺失时隐藏入口，不填假实现（§3.2）。l10n 文案 zh/en 同步 + 重新生成。

- [ ] **Step 4: 跑测试确认通过 + 全量回归（DSH 行为不变是硬要求）**

Run: `cd app && flutter analyze && flutter test && python3 app/tool/l10n_merge.py --check`
Expected: 新测试 PASS，且既有全部 app 测试不回归（DSH 主机路径零行为变化）。

- [ ] **Step 5: 提交**

```bash
git add app/lib/ui/chat/chat_screen.dart app/lib/state/sessions_state.dart \
        app/lib/ui/shell/drawer/drawer_list.dart app/lib/ui/shell/drawer/session_tile.dart \
        app/lib/l10n/parts/ app/test/orca_ui_entries_test.dart
git commit -m "app: 正式入口接入 MobileChatBackend，DSH 特有入口按能力隐藏"
```

---

### Task 7: 双端同步与编译验证

**Files:**
- 本仓库：无新文件（确认 `packages/orca_client` 完整、可独立解析）
- 跨仓库：把 `packages/orca_client/` 原样拷入 `/Users/joseph/projects/dsh-Go-ios/packages/`（同名分支 `feat/orca-mobile-link`，path 依赖指向各自的包）

**Interfaces:**
- Consumes: Task 1–6 的全部产物。
- Produces: 两个仓库各一份逐字节相同的 `orca_client` 源（唯一维护来源的落地，§2）。

- [ ] **Step 1: 本仓库最终回归**

Run: `cd app && flutter pub get && flutter analyze && flutter test`；`cd packages/orca_client && dart analyze && dart test`；`cd packages/dsh_client && dart analyze && dart test`
Expected: 全绿。

- [ ] **Step 2: 同步到 iOS 仓库并验证**

```bash
rm -rf /Users/joseph/projects/dsh-Go-ios/packages/orca_client
cp -R packages/orca_client /Users/joseph/projects/dsh-Go-ios/packages/orca_client
cd /Users/joseph/projects/dsh-Go-ios/app && flutter pub get && flutter analyze && flutter test
```
Expected: iOS 仓库 analyze/test 通过。若 iOS 仓库的 `pubspec` 需要登记 path 依赖，按该仓库惯例补。

- [ ] **Step 3: 如实记录验收状态**

按 §8：实现完成后在设计文档顶部与两个仓库的变更报告里标注**"尚未验收"**；列出已通过项（单测/widget 测试/编译）、未验证项（真机 Android/iOS、双端同会话提交与审批、主机重启恢复的真机表现、Codex/CC/DSH 逐 agent 能力）——不宣称已可上线。

- [ ] **Step 4: 提交（仅本仓库；iOS 仓库的提交在该仓库进行）**

```bash
git add packages/orca_client/ app/pubspec.lock
git commit -m "app: orca_client 双端同步基线，全量回归通过"
```

---

## 收尾验证（非独立任务）

- `flutter analyze && flutter test`（app）、`dart analyze && dart test`（orca_client、dsh_client）全绿。
- `l10n_merge.py --check` 通过（文案同步）。
- 真机项（Android 连接/导航/问答、iOS 同路径、双端同会话、断网恢复、主机重启）未运行则明确写"未运行"及原因（硬规则：桌面结果不能替代真机）。
- 设计文档标注"尚未验收"，逐项列证据（§8）。
