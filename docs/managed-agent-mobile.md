# Xcodex 插件托管 Agent 手机适配

## 范围与基线

2026-11-19，Android 基于 `1990eaad229b0054dd5d78ddf45fcf5dbe8aca71`，本次修改位于 `feat/xcodex-managed-agents`。
Android 和 iOS 按同一 DSH Remote 协议适配电脑上的 Xcodex 插件托管会话。
iOS 已有的直连 Orca 通道保留；它不是本次插件托管通道，不共用创建协议。
不迁移其他 Agent 历史，不重写登录、设备配对或中继，不修改线上服务配置。

## 协议契约

- `managedAgent/agents` 返回 `items`，每项含 `id/name/icon/agentId/registered/availability/capabilities`；旧 `available` 只表示已注册，不能解释成 CLI 已安装或鉴权成功。`availability: unverified` 表示实际可运行性在启动时确认。
- `managedAgent/create` 传 `workspaceId/agentId/operationId`。工作区必须来自当前 Host；同一创建请求重试复用 operationId，避免断线重复创建。
- 原生 DSH 新建仍调用 `session/create`。旧插件不支持发现时应保留 DSH 功能，不把网络错误伪装为空 Agent 列表。
- 会话身份只认 `projections.values.managedAgent.agentId`，不能根据模型名字或标题猜测。列表和 follow 快照都应携带该投影。
- 托管会话读取自己的 `session/modelCatalog`；模型和推理强度取电脑实际返回目录，不硬编码模型名。监听 `llm/models-updated` 清理缓存；不改变原生 DSH 全局目录语义。
- 聊天、审批、历史、标题事件沿用 `session/*` 与 `$events`；模型摘要标题由插件生成，手机显示和同步。
- 重命名、归档和恢复按会话能力使用现有接口。归档可恢复，不是永久删除。

## 能力边界与界面

能力字段按插件实际实现读取：`textPrompts/imagePrompts/fileAttachments/steering/queueWhileBusy/modelSelection/reasoningEffort/rename/archive/unarchive/pin/move/fork/rewind/compact/threadGoal/contextUsage`。
未声明的高级能力不启用；能力字段缺失的旧插件只使用已确认的兼容基础流程。

当前托管通道不支持图片、文件附件、执行中插话/排队、置顶、移动到另一工作区、分叉、回退、上下文压缩、线程目标、完整上下文用量、永久删除和权限模式切换。客户端不得仅因原生 Host 支持某接口就对托管会话调用。

- 单项及批量操作都要检查能力。批量置顶跳过不支持的托管会话；永久删除在 UI 和执行层双重拦截，混合批次仅原生可删除项执行。
- 归档搜索里的恢复入口按 `unarchive` 能力启用，托管不支持的永久删除入口隐藏。
- 自定义侧栏文件夹是手机本地分类，不等于改变 Host 工作区归属，可继续使用。
- 会话详情的目标/计划展示是只读，不代表允许新建或修改线程目标。
- 底层 CLI 自身具备能力不等于插件已经接通。未知投递结果不可自动重复发送。

## 验证与待办

Android 应用定向回归 29 项通过；SDK 契约 6 项和加密隧道 1 项通过。本次修改的应用 Dart 文件静态分析无问题。插件后端/网关定向测试 36 项通过，插件 TypeScript 类型检查通过。
生产服务器仅执行顺序检查：测试进程最多绑定两个 CPU 核心，nice +15，进程树内存上限取 4 GiB 和启动时空闲内存三分之一的较小值；不足 4 GiB 系统可用内存或超过 10 分钟即终止本次测试进程。未停止已有服务、未运行全量构建。

验证环境为 Linux、Flutter 3.47.7 / Dart 3.13.5。现有 SDK 固定的 test_api 与上游 lockfile 不一致，因此应用检查使用临时兼容解析（Android 1 个、iOS 6 个测试依赖版本变化），完成后已恢复原 lockfile，没有提交依赖降级。正式锁定依赖构建仍须在匹配 SDK 的构建机验收。字体使用服务器已有 Noto 字体目录。此结果不代表原锁定依赖的正式安装包已构建通过。

新建操作 ID 在进程内按账号/Host/工作区/Agent 保留，网络恢复后的显式重试复用；不自动重发。App 被杀进程后的未确认创建尚未实现持久化恢复，列为后续增强。

待真实 Android/iPhone/iPad 与真实电脑验证：

- 同工作区新建 DSH、Claude Code、Codex，Logo 与工作区归属准确。
- 显示电脑实际模型目录和真实支持的推理强度；更换 Host、会话和断线后不串缓存。
- 两端接回同一会话、双方消息与摘要标题可见、审批允许及拒绝。
- 执行中按钮按能力控制；附件和不支持操作不发送 RPC。
- 归档恢复、重启后直达会话、断线恢复不重复创建或重复发送。
- 撤销单设备后不能读写，其他设备和在执行任务不受影响。
- 旧插件兼容以及 iOS 原有 Orca 通道回归。

未构建发布 APK/IPA，未进行真机或真实账号验收，未部署服务。

图标来源：沿用 Xcodex 插件 `packages/plugin/client/icons.ts` 的 GPT 图标及 Claude 放射标记；目录分组不显示 Agent 头像。
