/// SDK 对外模型。
///
/// 两套序列化，别混：
/// - `fromServer`：解析服务端响应 / 推送（接入文档 §3、§5），时间是东八区字符串。
/// - `toJson` / `fromJson`：SDK 内部格式，给本地存储层用，时间是 UTC 毫秒时间戳。
library;

import 'time.dart';

int _int(Object? v) => (v as num).toInt();
int? _intOrNull(Object? v) => v == null ? null : (v as num).toInt();
Map<String, dynamic> _map(Object? v) =>
    v == null ? <String, dynamic>{} : Map<String, dynamic>.from(v as Map);
DateTime _fromMs(Object? v) =>
    DateTime.fromMillisecondsSinceEpoch(_int(v), isUtc: true);

/// `copyWith` 里区分「没传」与「显式传 null」。
const Object _unset = Object();

/// 用户令牌，由接入方的 `tokenProvider` 返回。
class ImToken {
  const ImToken(this.token, this.expiresAt);

  /// 解析接入方后端原样透传的签令牌结果 `{"token", "expires_at"}`（`expires_at` 为东八区字符串）。
  factory ImToken.fromServer(Map json) =>
      ImToken(json['token'] as String, parseCst(json['expires_at'] as String));

  /// 不透明字符串，不要解析它。
  final String token;

  /// 过期时间（UTC）。
  final DateTime expiresAt;
}

/// 本地消息状态。服务端拉来 / 推来的消息一律是 [sent]。
enum ImMessageStatus {
  /// 本设备发出、尚未拿到结果。
  sending,

  /// 服务端已接收（有 `id` / `seq`）。
  sent,

  /// 发送失败，可 `resend`（看 `errorCode` 决定是否值得重发）。
  failed,

  /// 被对方拉黑（`IM_BLOCKED`）或被发送前回调拒绝（`IM_MESSAGE_REJECTED`），不要重发。
  rejected,
}

/// 长连接状态。
enum ImConnectionState { connecting, connected, disconnected }

/// 一条消息。
///
/// 服务端消息对象没有 `to`，[to] 由 SDK 推导（见 [ImMessage.fromServer]）。
/// [isSelf] 是构造时定下的字段（`from == 当前用户`），不是运行时计算——
/// 模型里不持有当前用户，切换账号时各用户的本地库本来就是分开的。
class ImMessage {
  const ImMessage({
    this.id,
    required this.clientMsgId,
    this.conversationId,
    this.seq,
    required this.from,
    required this.to,
    required this.isSelf,
    required this.type,
    required this.content,
    required this.status,
    this.errorCode,
    this.errorMessage,
    required this.createdAt,
    this.localPath,
    this.urlFetchedAt,
  });

  /// 解析服务端消息对象（发消息返回、拉消息列表、推送里的 `message`）。
  ///
  /// - [me]：当前登录用户 id，用来算 [isSelf] 与 [to]。
  /// - [peerId]：会话对方的 user_id。`from == me` 时 `to` 取它；调用方须传入，
  ///   缺省时 `to` 为空串（这条消息本人在别的设备发出、而本地还不知道会话对方）。
  /// - `from != me` 时 `to = me`，与 [peerId] 无关。
  /// - 上传图（content 有 `attachment_id`）的链接是服务端读取时现签的，[urlFetchedAt] 取本机当前时间。
  factory ImMessage.fromServer(Map json, {required String me, String? peerId}) {
    final from = json['from'] as String;
    final isSelf = from == me;
    final content = _map(json['content']);
    return ImMessage(
      id: _intOrNull(json['id']),
      clientMsgId: json['client_msg_id'] as String,
      conversationId: _intOrNull(json['conversation_id']),
      seq: _intOrNull(json['seq']),
      from: from,
      to: isSelf ? (peerId ?? '') : me,
      isSelf: isSelf,
      type: json['type'] as String,
      content: content,
      status: ImMessageStatus.sent,
      createdAt: parseCst(json['created_at'] as String),
      urlFetchedAt: content.containsKey('attachment_id')
          ? DateTime.now().toUtc()
          : null,
    );
  }

  /// 读取 [toJson] 的产物（存储层用）。
  factory ImMessage.fromJson(Map json) => ImMessage(
    id: _intOrNull(json['id']),
    clientMsgId: json['client_msg_id'] as String,
    conversationId: _intOrNull(json['conversation_id']),
    seq: _intOrNull(json['seq']),
    from: json['from'] as String,
    to: json['to'] as String,
    isSelf: json['is_self'] as bool,
    type: json['type'] as String,
    content: _map(json['content']),
    status: ImMessageStatus.values.byName(json['status'] as String),
    errorCode: json['error_code'] as String?,
    errorMessage: json['error_message'] as String?,
    createdAt: _fromMs(json['created_at']),
    localPath: json['local_path'] as String?,
    urlFetchedAt: json['url_fetched_at'] == null
        ? null
        : _fromMs(json['url_fetched_at']),
  );

  /// 服务端消息 id；本地「发送中 / 失败」时为 null。
  final int? id;

  /// 客户端生成的幂等 id（UUID v4），重发时沿用。
  final String clientMsgId;

  /// 会话 id；首条消息发送成功前为 null。
  final int? conversationId;

  /// 会话内序号；未确认时为 null。
  final int? seq;

  final String from;
  final String to;

  /// 是否当前用户发出（含本人在其他设备发出的）。
  final bool isSelf;

  /// `text` / `image` / `location` / `custom`。保留字符串，服务端将来加类型时不至于解析失败。
  final String type;

  /// 按 [type] 的内容，形状见接入文档 §5.1。
  final Map<String, dynamic> content;

  final ImMessageStatus status;

  /// 失败 / 拒收时的错误码（服务端码或 `NETWORK`），成功时为 null。
  final String? errorCode;
  final String? errorMessage;

  /// 服务端时间（UTC）；本地未确认的消息为本机发送时刻。
  final DateTime createdAt;

  /// 本设备发出的图片的本地文件路径（io 端重发时重读用），其余为 null。
  final String? localPath;

  /// 上传图（content 有 `attachment_id`）的临时链接是何时取得的（UTC），用来判断是否该重拉（spec §3.5）。
  /// 其余消息为 null。
  final DateTime? urlFetchedAt;

  /// 业务卡片（接入文档 §5.9）：custom 消息的 `content['data']['im_card']`；
  /// 不是 custom、没带卡片或卡片缺 `title` 时为 null，调用方退回显示 `desc`（格式由服务端发送时把关）。
  ImCard? get card =>
      type == 'custom' ? ImCard.tryParse(content['data']) : null;

  /// 复制并替换部分字段。可空字段显式传 `null` 即清空（如重发前清掉 `errorCode`）。
  ImMessage copyWith({
    Object? id = _unset,
    String? clientMsgId,
    Object? conversationId = _unset,
    Object? seq = _unset,
    String? from,
    String? to,
    bool? isSelf,
    String? type,
    Map<String, dynamic>? content,
    ImMessageStatus? status,
    Object? errorCode = _unset,
    Object? errorMessage = _unset,
    DateTime? createdAt,
    Object? localPath = _unset,
    Object? urlFetchedAt = _unset,
  }) => ImMessage(
    id: identical(id, _unset) ? this.id : id as int?,
    clientMsgId: clientMsgId ?? this.clientMsgId,
    conversationId: identical(conversationId, _unset)
        ? this.conversationId
        : conversationId as int?,
    seq: identical(seq, _unset) ? this.seq : seq as int?,
    from: from ?? this.from,
    to: to ?? this.to,
    isSelf: isSelf ?? this.isSelf,
    type: type ?? this.type,
    content: content ?? this.content,
    status: status ?? this.status,
    errorCode: identical(errorCode, _unset)
        ? this.errorCode
        : errorCode as String?,
    errorMessage: identical(errorMessage, _unset)
        ? this.errorMessage
        : errorMessage as String?,
    createdAt: createdAt ?? this.createdAt,
    localPath: identical(localPath, _unset)
        ? this.localPath
        : localPath as String?,
    urlFetchedAt: identical(urlFetchedAt, _unset)
        ? this.urlFetchedAt
        : urlFetchedAt as DateTime?,
  );

  /// SDK 内部格式（存储层用）：`content` 仍是 Map，`created_at` 为 UTC 毫秒时间戳，`status` 为枚举名。
  Map<String, dynamic> toJson() => {
    'id': id,
    'client_msg_id': clientMsgId,
    'conversation_id': conversationId,
    'seq': seq,
    'from': from,
    'to': to,
    'is_self': isSelf,
    'type': type,
    'content': content,
    'status': status.name,
    'error_code': errorCode,
    'error_message': errorMessage,
    'created_at': createdAt.millisecondsSinceEpoch,
    'local_path': localPath,
    'url_fetched_at': urlFetchedAt?.millisecondsSinceEpoch,
  };

  @override
  String toString() =>
      'ImMessage(id: $id, cmid: $clientMsgId, conv: $conversationId, seq: $seq, '
      '$from→$to, $type, ${status.name}${errorCode == null ? '' : ' $errorCode'})';
}

/// 业务卡片 `custom.data.im_card` 的一行关键信息，是发送那一刻的快照。
class ImCardField {
  const ImCardField({required this.label, required this.value});

  final String label;
  final String value;
}

/// 业务卡片外壳（接入文档 §5.9）。发送时把同形状的 Map 放进 `sendCustom` 的
/// `data['im_card']`，服务端校验；这里只负责解析，渲染由 App 自己做。
///
/// 各端取自己能用的链接：网站 / H5 用 [webLink]，原生 App 用 [appLink]，
/// 小程序用 [mpPath]（[mpAppid] 不为空时跳到另一个小程序）。
class ImCard {
  const ImCard({
    required this.title,
    this.kind,
    this.subtitle,
    this.image,
    this.fields = const [],
    this.webLink,
    this.appLink,
    this.mpPath,
    this.mpAppid,
  });

  /// 解析 custom 消息的 `content['data']`，取其中的 `im_card`。
  ///
  /// 没带卡片、`title` 不是非空字符串时返回 null；其余字段类型不对按缺省处理，
  /// [fields] 只收 label、value 都是非空字符串的项。不抛错。
  static ImCard? tryParse(Object? data) {
    if (data is! Map) return null;
    final c = data['im_card'];
    if (c is! Map) return null;
    final title = c['title'];
    if (title is! String || title.trim().isEmpty) return null;
    String? str(String key) {
      final v = c[key];
      return v is String && v.isNotEmpty ? v : null;
    }

    final fields = <ImCardField>[];
    final raw = c['fields'];
    if (raw is List) {
      for (final f in raw) {
        if (f is! Map) continue;
        final label = f['label'];
        final value = f['value'];
        if (label is String &&
            label.isNotEmpty &&
            value is String &&
            value.isNotEmpty) {
          fields.add(ImCardField(label: label, value: value));
        }
      }
    }
    return ImCard(
      title: title,
      kind: str('kind'),
      subtitle: str('subtitle'),
      image: str('image'),
      fields: fields,
      webLink: str('web_link'),
      appLink: str('app_link'),
      mpPath: str('mp_path'),
      mpAppid: str('mp_appid'),
    );
  }

  final String title;

  /// 推荐 `order` / `product` / `service` / `article` / `page`，只用来显示类型名和图标。
  final String? kind;
  final String? subtitle;

  /// 封面或缩略图（https）。
  final String? image;

  /// 关键信息，发送那一刻的快照，最新状态以点开详情为准。
  final List<ImCardField> fields;

  /// 网站、H5、客服工作台用（https）。
  final String? webLink;

  /// 原生 App 内跳转用，例如 `djx://order/1`。
  final String? appLink;

  /// 小程序页面路径，例如 `/pages/order/detail?id=1`。
  final String? mpPath;

  /// 为空：跳本小程序内的 [mpPath]；不为空：跳到这个 AppID 的小程序。
  final String? mpAppid;
}

/// 会话列表里的最后一条消息摘要（不是完整消息，服务端只给这几个字段）。
class ImMessagePreview {
  const ImMessagePreview({
    required this.seq,
    required this.from,
    required this.type,
    required this.preview,
    required this.createdAt,
  });

  factory ImMessagePreview.fromServer(Map json) => ImMessagePreview(
    seq: _int(json['seq']),
    from: json['from'] as String,
    type: json['type'] as String,
    preview: json['preview'] as String,
    createdAt: parseCst(json['created_at'] as String),
  );

  factory ImMessagePreview.fromJson(Map json) => ImMessagePreview(
    seq: _int(json['seq']),
    from: json['from'] as String,
    type: json['type'] as String,
    preview: json['preview'] as String,
    createdAt: _fromMs(json['created_at']),
  );

  final int seq;
  final String from;
  final String type;

  /// 预览文字：text 前 50 字，image `[图片]`，location `[位置]`，custom 取 `desc`。
  final String preview;
  final DateTime createdAt;

  Map<String, dynamic> toJson() => {
    'seq': seq,
    'from': from,
    'type': type,
    'preview': preview,
    'created_at': createdAt.millisecondsSinceEpoch,
  };
}

/// 会话对方（服务端 User 形状）。资料以接入方自家用户系统为准，这里只是 IM 里登记的副本。
class ImPeer {
  const ImPeer({
    required this.userId,
    required this.nickname,
    required this.avatarUrl,
  });

  factory ImPeer.fromServer(Map json) => ImPeer(
    userId: json['user_id'] as String,
    nickname: (json['nickname'] as String?) ?? '',
    avatarUrl: (json['avatar_url'] as String?) ?? '',
  );

  /// `fromJson` 与 `fromServer` 键名相同。
  factory ImPeer.fromJson(Map json) = ImPeer.fromServer;

  /// 平台客服固定为 `@cs`。
  final String userId;

  /// 可能为空串。
  final String nickname;

  /// 可能为空串。
  final String avatarUrl;

  Map<String, dynamic> toJson() => {
    'user_id': userId,
    'nickname': nickname,
    'avatar_url': avatarUrl,
  };
}

/// 一个会话（单聊或客服）。
///
/// [unread] 是 `maxSeq − readSeq` 的计算属性（服务端口径），不单独存：
/// 收到 `read` / `read_all` 推送只改 [readSeq]，未读自动跟着变。
class ImConversation {
  const ImConversation({
    required this.id,
    required this.type,
    required this.peer,
    this.lastMessage,
    required this.maxSeq,
    required this.readSeq,
    required this.lastMsgAt,
    this.pinnedAt,
    this.muted = false,
    this.clearSeq = 0,
  });

  /// 解析会话列表的一项（接入文档 §5.2 / §10.2）。服务端的 `unread` 字段不读，见 [unread]。
  /// 旧版服务端没有 `pinned_at` / `muted` / `clear_seq`，按未置顶、未免打扰、没清空过处理。
  factory ImConversation.fromServer(Map json) {
    final last = json['last_message'];
    return ImConversation(
      id: _int(json['conversation_id']),
      type: json['type'] as String,
      peer: ImPeer.fromServer(json['peer'] as Map),
      lastMessage: last == null
          ? null
          : ImMessagePreview.fromServer(last as Map),
      maxSeq: _int(json['max_seq']),
      readSeq: _int(json['read_seq']),
      lastMsgAt: parseCst(json['last_msg_at'] as String),
      pinnedAt: json['pinned_at'] == null
          ? null
          : parseCst(json['pinned_at'] as String),
      muted: (json['muted'] as bool?) ?? false,
      clearSeq: _intOrNull(json['clear_seq']) ?? 0,
    );
  }

  factory ImConversation.fromJson(Map json) {
    final last = json['last_message'];
    return ImConversation(
      id: _int(json['id']),
      type: json['type'] as String,
      peer: ImPeer.fromJson(json['peer'] as Map),
      lastMessage: last == null ? null : ImMessagePreview.fromJson(last as Map),
      maxSeq: _int(json['max_seq']),
      readSeq: _int(json['read_seq']),
      lastMsgAt: _fromMs(json['last_msg_at']),
      pinnedAt: json['pinned_at'] == null ? null : _fromMs(json['pinned_at']),
      muted: (json['muted'] as bool?) ?? false,
      clearSeq: _intOrNull(json['clear_seq']) ?? 0,
    );
  }

  final int id;

  /// `c2c` 普通单聊 / `service` 平台客服。
  final String type;
  final ImPeer peer;

  /// 本人清空过记录且之后没有新消息时为 null；极少数情况下服务端也会不给。
  final ImMessagePreview? lastMessage;
  final int maxSeq;
  final int readSeq;

  /// 最后消息时间（UTC），会话列表里非置顶会话按它倒序。
  final DateTime lastMsgAt;

  /// 本人置顶该会话的时间（UTC），未置顶为 null。
  final DateTime? pinnedAt;

  /// 本人对该会话开了免打扰：[unread] 照常计数（可显示成小红点），但不计入总未读。
  final bool muted;

  /// 本人清空到的序号，`seq <= clearSeq` 的消息看不到；没清空过为 0。
  final int clearSeq;

  bool get isService => type == 'service';

  bool get pinned => pinnedAt != null;

  int get unread => maxSeq > readSeq ? maxSeq - readSeq : 0;

  ImConversation copyWith({
    String? type,
    ImPeer? peer,
    Object? lastMessage = _unset,
    int? maxSeq,
    int? readSeq,
    DateTime? lastMsgAt,
    Object? pinnedAt = _unset,
    bool? muted,
    int? clearSeq,
  }) => ImConversation(
    id: id,
    type: type ?? this.type,
    peer: peer ?? this.peer,
    lastMessage: identical(lastMessage, _unset)
        ? this.lastMessage
        : lastMessage as ImMessagePreview?,
    maxSeq: maxSeq ?? this.maxSeq,
    readSeq: readSeq ?? this.readSeq,
    lastMsgAt: lastMsgAt ?? this.lastMsgAt,
    pinnedAt: identical(pinnedAt, _unset)
        ? this.pinnedAt
        : pinnedAt as DateTime?,
    muted: muted ?? this.muted,
    clearSeq: clearSeq ?? this.clearSeq,
  );

  /// SDK 内部格式（存储层用），时间为 UTC 毫秒时间戳。
  Map<String, dynamic> toJson() => {
    'id': id,
    'type': type,
    'peer': peer.toJson(),
    'last_message': lastMessage?.toJson(),
    'max_seq': maxSeq,
    'read_seq': readSeq,
    'last_msg_at': lastMsgAt.millisecondsSinceEpoch,
    'pinned_at': pinnedAt?.millisecondsSinceEpoch,
    'muted': muted,
    'clear_seq': clearSeq,
  };
}

/// 黑名单的一项。只有 user_id，昵称头像请用 App 自家资料展示。
class ImBlockItem {
  const ImBlockItem({required this.userId, required this.createdAt});

  factory ImBlockItem.fromServer(Map json) => ImBlockItem(
    userId: json['user_id'] as String,
    createdAt: parseCst(json['created_at'] as String),
  );

  final String userId;

  /// 拉黑时间（UTC）。
  final DateTime createdAt;
}

/// 客服接待状态（接入文档 §10.4）。
enum ImCsStatus {
  /// 当前没有进行中的咨询。
  none,

  /// 排队中。
  queued,

  /// 坐席接待中。
  active,
}

/// `GET /api/imcs/v1/state` 的结果，用于客服会话页顶部的状态条。服务端不推送，按需刷新。
class ImCsState {
  const ImCsState({
    required this.status,
    required this.sessionId,
    required this.queuePosition,
  });

  /// 不认识的 status 按 [ImCsStatus.none] 处理，服务端将来加状态时不至于解析失败。
  factory ImCsState.fromServer(Map json) => ImCsState(
    status: ImCsStatus.values.firstWhere(
      (s) => s.name == json['status'],
      orElse: () => ImCsStatus.none,
    ),
    sessionId: (json['session_id'] as num).toInt(),
    queuePosition: (json['queue_position'] as num).toInt(),
  );

  final ImCsStatus status;

  /// 当前这次接待的 id；[ImCsStatus.none] 时为 0。
  final int sessionId;

  /// 排队名次（含自己，排第一为 1）；非 [ImCsStatus.queued] 时为 0。
  final int queuePosition;
}
