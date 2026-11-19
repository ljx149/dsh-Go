# Orca 移动端接入设计

创建日期：2026-11-18
分支：`feat/orca-mobile-link`（dsh-Go 与 dsh-Go-ios 同名分支）
状态：设计已评审，尚未实施；实现完成后统一标注"尚未验收"，验收标准见 §8。

## 1. 目标

在 dsh-Go / dsh-Go-ios 现有 App 上接入 Orca 作为多 harness 远程后端：主机连接、主机 → 目录 → 会话的导航、新建/打开/续聊会话、流式聊天、工具执行与审批、模型切换、双端同会话输入、断线恢复。样式与交互沿用现有聊天界面，不引入探针页或演示入口。不是最小问答原型。

与 Orca 仓库主计划（`orca/docs/orca-flutter-multi-harness-plan.md`，R04）的关系：主计划定义 P0–P6 全链路；本文档是其 P2/P3 的移动端实施细化。P0 已验证的结论（Orca 结构化链路、DSH ACP 接入、协议校验语义）是本文档的前提，不再重复验证。

## 2. 仓库分工

| 仓库 | 职责 |
|---|---|
| orca | 多 harness 接入、主机侧会话生命周期、消息调度、审批与状态同步；首批在原 agent 基础上增加 DSH Desktop（结构化 ACP，不接 dsh-web） |
| dsh-Go / dsh-Go-ios | 移动 App 底座，保留现有聊天界面、主题、交互风格；Orca 作为与 dsh-remote 并列的新连接类型 |
| `packages/orca_client` | 纯 Dart 协议与数据层，**两个移动端的唯一维护来源**。不各复制一份分别改。Android 与 iOS 仓库各放一份 path 依赖副本，任何协议改动先改 orca 仓库的源头，再同步 |

## 3. 架构：抽统一接口，不伪造 DshClient

### 3.1 为什么不能冒充 DshClient

`HostConnection.client` 是具体的 `DshClient` 类，聊天页依赖的不止列表/发送/订阅，还有历史分页、连接状态、取消、队列、审批、模型切换。复制方法签名会出现"界面能打开，操作语义不对"。

### 3.2 MobileChatBackend 接口

在 `orca_client` 中定义面向移动端功能的接口，DSH 与 Orca 各实现一份。接口面以现有 UI 的实际调用面为准，实施时逐一盘点 `chat_screen.dart`、`sessions_state.dart`、`connection_state.dart`、`drawer/` 的引用，不靠猜。最小契约：

```
MobileChatBackend
  listConversations(scope)      → 会话列表（agent、title、cwd、branch、model、running、structured 可写性）
  openConversation(id)          → 历史分页 + 订阅句柄（游标、快照语义）
  createSession(agent, ...)     → 新建；可带首条消息（见 §5.2 的 create/send 分离规则）
  send(id, body)                → 续聊；操作身份（opId）由后端生成并保持可重放
  cancel(id) / queue(id, op)    → 取消、排队（queuedMessageSend/Delete/Move/Update）
  approval(id, decision)        → 审批与提问响应（respondToApproval / respondToQuestion）
  models(id) → setModel(id, m)  → 模型目录读取 + 实际切换并回读结果，不只改本地显示
  connectionState               → 断开 / 重连 / 主机切换信号
  capabilities                  → 能力判断，DSH 特有语义（mux、terminal 会话等）Orca 实现显式返回缺失，UI 隐藏入口，不填空实现、不假成功
```

连接类型：`HostKind` 增加 `orca`，与 `local`/`ssh`/`relay` 并列，复用 `HostChip` 的机器切换 UI。配对配置（endpoint + pairingCode）走 `flutter_secure_storage`，不写进仓库任何文件。

### 3.3 会话 ID 语义（已源码核实）

`aiVault.listSessions` 的行同时携带：

- `agent`（必有，AiVaultAgent union）
- `sessionId`（provider 原生 ID）
- `structuredSession.sessionId`（可选，Orca 托管的结构化会话 ID）
- `cwd` / `branch` / `model` / `messageCount`

打开规则：
- 有 `structuredSession` → 用结构化 ID 走 `agentSession.*`（可续聊、可审批、可模型切换）
- 无 `structuredSession` → 纯历史记录行，只读展示，不伪装成可写会话
- 业务层显式保存 agent 身份与 ID 身份，`raw['agent']` 仅作兜底，核心逻辑不长期依赖它

## 4. 导航：主机 → 目录 → 会话

- 第一级：主机切换（现有 HostChip 机制）。
- 第二级：目录。Orca 侧数据来源是 `worktree.list`（git worktree）与普通文件夹工作区并存。**Orca 端没有 `worktree.watch`**（已核实，只有 list 类方法）：移动端刷新机制为"切主机时全量 list 一次 + 会话增删事件触发后按需重 list"，不假装持续监听。这是能力边界，明确记录。
- 第三级：会话列表，各 agent 统一展示（agent 图标暂缓，先用现有样式）。

## 5. 聊天与会话操作

### 5.1 展示

沿用 dsh-Go 风格：消息、流式回复、工具执行、错误与审批卡片。不能以终端输出代替正常聊天。流式走 `agentSession.subscribe`，事件形态为 `snapshot`（全量快照）→ `batch`（增量，带游标）→ `end`。

### 5.2 create 与 send 必须分离（协议规则，P0 已验证）

- 新建会话且携带首条消息：host 的 atRest create 语义是 firstMessage 自动入队投递，**之后不能再发同一条**（会变成重复提交）。
- 已有会话续聊：只 send，不重新 create。
- 重试保持操作身份：host 用 `payloadFingerprint`（sha256 of 规范化 `{method, sessionId, fields}`）+ `clientOperationId` 做重放保护，同一 opId 不同指纹会拒（`fingerprintMismatch`），同指纹重放会回放原结果（`replayed: true`）。客户端不得在重试时换 ID 或换指纹。

### 5.3 双端输入

两端均可编辑和提交，由 Orca 主机统一裁决提交顺序并排队（`queuedMessages` 语义），手机操作前不收回桌面输入权。

### 5.4 审批

两端均可处理，`respondToApproval` / `respondToQuestion` 先到先得生效并同步到另一端；只有尚未裁定的冲突按桌面优先处理，不推翻已执行结果。

### 5.5 模型

- 读取主机实际可用模型：`agentSession.modelCatalog`（不等待 attach，读存储/发布事实）。
- 切换：`agentSession.setOption`，切换后从 host 回读结果同步 UI——不能只修改手机显示。
- DSH 沿用用户实际配置的模型提供方（现有百炼等 profile 配置，`~/.dsh` 凭据存储），不回退 DeepSeek 官方路由、不要求重新提供官方 Key。

### 5.6 恢复

断网、网络切换、后台返回后：按游标重新订阅、快照覆盖本地状态、按 `itemId` 去重、主机重启导致 `fence` 变化时重新 attach。提交状态（`dispatchState: pending/accepted`）明确显示"仍在等待"或"失败"，不吞错误。订阅成功不等于恢复完成——以上恢复状态机在 `orca_client` 实现一次，两端共用（唯一维护来源的落点）。

## 6. DSH 经 Orca 的前提（P0 已闭环）

- DSH 注册为 Orca 结构化 ACP agent：`dsh --profile acp`（deepseek-harness-acp），launch spec 在 orca 仓库 `src/main/dsh/dsh-acp-launch-spec.ts`，commit `84f5c2ec11`。
- 真实问答已验证：create → 投递 → ACP 子进程 → 百炼模型 → assistant 回答落回同一会话 journal。
- 会话恢复已验证：重开同一 Orca 会话（fence 不变）继续发送，原协议校验全程有效。
- 操作校验规则：`clientOperationId` 格式 `<13位ms时间戳>-<32位无连字符hex>`；create 的 `expectedRuntimeFence` 为 null，之后的 send 用 host 返回的 fence。

## 7. 实施顺序（在 feat/orca-mobile-link 分支）

1. 盘点 `DshClient` 在 UI 的完整调用面 → 定义 `MobileChatBackend` 精确接口。
2. `orca_client` 增加 Orca 实现（§3.2 契约 + §5.6 恢复状态机 + §5.2 操作身份管理）。
3. `HostKind.orca` + 连接 provider + 凭据安全存储。
4. 接进正式 App 入口（会话列表、聊天页），DSH 特有入口按能力隐藏。
5. 双端同步 `orca_client` 源，各端编译验证。

## 8. 验收标准（正式上线口径）

验收对象是正式 App 的完整使用体验，不是探针或单次 RPC 成功。

- Android、iOS 与桌面联合验证：连接、导航、新建、打开已有会话、连续问答完整可用。
- Codex、CC、DSH 分别验证模型、工具、审批和恢复等各自实际支持的能力；一个 agent 通过不代表其他通过。
- Orca 首批承诺覆盖的其他 agent 逐项记录能力与验收结果，未经确认不缩减范围。
- 双端同时提交、同时审批、切换会话与主机：不串会话、不重复执行。
- 异常路径：断网、网络切换、后台恢复、主机重启；失败有可理解的提示和恢复入口。
- 凭据安全存储，日志不泄露敏感信息；不可用能力明确说明，不吞错误、不假成功。
- 每项需求有对应验收证据；阻塞项、未验证项、已通过项分别记录。影响核心使用的未解决问题不计为完成。

实现完成后统一标注"尚未验收"，不能据此宣称已可上线。
