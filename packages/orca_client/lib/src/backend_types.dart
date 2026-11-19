/// Shared message + conversation models for the mobile chat backends.
///
/// These are the rendering and bookkeeping types the UI consumes through
/// [MobileChatBackend]. They deliberately do NOT import `dsh_client`: the DSH
/// mapping layer (Task 3) converts `SessionSummary`/`SessionLogEvent` into
/// these, so the UI has a single, backend-neutral input.
library;

/// One conversation row from [MobileChatBackend.listConversations].
///
/// `id` is the structured session id when the row is writable, else the
/// provider-native session id of a read-only history row (spec §3.3).
class ConversationSummary {
  const ConversationSummary({
    required this.id,
    required this.agent,
    required this.title,
    this.cwd,
    this.branch,
    this.model,
    this.running = false,
    required this.writable,
  });

  final String id;
  final String agent;
  final String title;
  final String? cwd;
  final String? branch;
  final String? model;
  final bool running;

  /// `false` = a read-only history row with no `structuredSession`; the UI
  /// shows it but offers no send/queue entry (spec §3.3).
  final bool writable;
}

/// A single chat block. Only `type` and `text` are guaranteed; tool blocks
/// keep their host type name so the UI can label them without inventing one.
class ChatBlock {
  const ChatBlock({required this.type, this.text});

  const ChatBlock.text(String text) : this(type: 'text', text: text);

  final String type;
  final String? text;
}

/// One chat message (spec §5.6: dedupe by [itemId]).
class ChatMessage {
  const ChatMessage({
    required this.seq,
    required this.itemId,
    required this.role,
    required this.blocks,
    this.timestamp,
  });

  final int seq;
  final String itemId;
  final String role;
  final List<ChatBlock> blocks;
  final DateTime? timestamp;

  /// The concatenated text of the text blocks; empty when there is none.
  String get text => blocks
      .where((b) => b.type == 'text')
      .map((b) => b.text ?? '')
      .join(' ')
      .trim();
}

/// A page of history returned by [MobileChatBackend.history].
class ChatHistoryPage {
  const ChatHistoryPage(this.messages, this.hasMore);

  final List<ChatMessage> messages;
  final bool hasMore;
}

/// The shape of live chat events (spec §5.1): a full [snapshot], then
/// incremental [batch]es carrying a cursor, then [end].
enum ChatEventKind { snapshot, batch, end }

class ChatEvent {
  const ChatEvent(this.kind, this.messages, {this.cursor});

  final ChatEventKind kind;
  final List<ChatMessage> messages;

  /// Present on `batch` events; null on `snapshot`/`end`.
  final int? cursor;
}

/// Which operations a backend can do. The UI hides an entry whose capability
/// is absent — it never fills in a fake implementation (spec §3.2).
enum ChatCapability {
  historyPaging,
  createWithFirstMessage,
  send,
  cancel,
  queue,
  approval,
  question,
  modelCatalog,
  setModel,
  rename,
  archive,
  worktreeList,
  // DSH-only: the Orca implementation does not declare these.
  subagentRouting,
  terminalSession,
  mux,
  pluginEvents,
  lifecycleStatus,
  logExport,
  transcribe,
  fileUpload,
  bundleList,
}

enum ConnectionSignalKind { connected, disconnected, reconnecting, hostSwitched }

class ConnectionSignal {
  const ConnectionSignal(this.kind, {this.detail});

  final ConnectionSignalKind kind;
  final String? detail;
}

/// Queued-message operations (spec §3.2 queuedMessage* semantics).
enum QueueAction { send, delete, move, update }

/// An approval decision; the DSH and Orca backends each map this to their
/// host's wire value. Kept here so the interface does not import `dsh_client`.
enum ApprovalDecision { pass, reject }

/// A model in the host's catalog (spec §5.5).
class ModelInfo {
  const ModelInfo({required this.id, required this.label, this.vendor});

  final String id;
  final String label;
  final String? vendor;
}

/// A backend failure with a stable code (hard rule: no silent swallowing).
///
/// `retriable` marks whether the caller may retry; a `false` result is a
/// definitive failure the UI must surface, not hide behind a retry.
class MobileBackendException implements Exception {
  const MobileBackendException(this.code, this.message, {this.retriable = false});

  final String code;
  final String message;
  final bool retriable;

  @override
  String toString() => 'MobileBackendException($code): $message';
}
