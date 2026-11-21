// guokit_im 最小示例。
//
// 真实 App 里令牌由自家后端签发（后端用 API Key 调 IM 服务端接口），客户端绝不持有 API Key。
// 示例为了能独立跑，直接从启动参数拿一个已签好的令牌：
//
//   flutter run --dart-define=IM_BASE_URL=http://127.0.0.1:8080 \
//     --dart-define=IM_USER=u1001 --dart-define=IM_TOKEN=<后端签的令牌> --dart-define=IM_PEER=u1002
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:guokit_im/guokit_im.dart';

const _baseUrl = String.fromEnvironment('IM_BASE_URL', defaultValue: 'http://127.0.0.1:8080');
const _user = String.fromEnvironment('IM_USER');
const _token = String.fromEnvironment('IM_TOKEN');
const _peer = String.fromEnvironment('IM_PEER');

// 1x1 透明 PNG，演示 sendImageBytes（真实 App 用 image_picker 等取图）。
final _demoPng = base64Decode(
    'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNkYPhfDwAChwGA60e6kgAAAABJRU5ErkJggg==');

final im = GuokitIm(ImConfig(
  baseUrl: _baseUrl,
  // 真实 App：调自家后端接口取令牌；后端发现用户已封禁 / 已登出时抛 ImKickedOutException。
  tokenProvider: () async => ImToken(_token, DateTime.now().toUtc().add(const Duration(days: 7))),
));

void main() => runApp(const MaterialApp(title: 'guokit IM 示例', home: HomePage()));

class HomePage extends StatefulWidget {
  const HomePage({super.key});
  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  List<ImConversation> _convs = [];
  ImConnectionState _state = ImConnectionState.disconnected;
  int _unread = 0;

  @override
  void initState() {
    super.initState();
    im.onConversationsChanged.listen((v) => setState(() => _convs = v));
    im.onConnectionChanged.listen((v) => setState(() => _state = v));
    im.onTotalUnreadChanged.listen((v) => setState(() => _unread = v));
    im.onKickedOut.listen((_) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('已被踢下线')));
    });
    if (_user.isNotEmpty) {
      im.login(_user).then((_) async {
        final list = await im.conversations();
        if (mounted) setState(() => _convs = list);
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text('$_user · ${_state.name} · 未读 $_unread')),
      floatingActionButton: _peer.isEmpty
          ? null
          : FloatingActionButton.extended(
              onPressed: () => _open(_peer),
              label: Text('和 $_peer 聊天'),
            ),
      body: ListView(
        children: [
          for (final c in _convs)
            ListTile(
              title: Text(c.peer.nickname.isEmpty ? c.peer.userId : c.peer.nickname),
              subtitle: Text(c.lastMessage?.preview ?? ''),
              trailing: c.unread > 0 ? Badge(label: Text('${c.unread}')) : null,
              onTap: () => _open(c.peer.userId),
            ),
        ],
      ),
    );
  }

  void _open(String peer) => Navigator.of(context)
      .push(MaterialPageRoute(builder: (_) => ChatPage(peer: peer)));
}

class ChatPage extends StatefulWidget {
  const ChatPage({super.key, required this.peer});
  final String peer;
  @override
  State<ChatPage> createState() => _ChatPageState();
}

class _ChatPageState extends State<ChatPage> {
  final _input = TextEditingController();
  final Map<String, ImMessage> _msgs = {}; // 按 clientMsgId 去重
  int? _convId;

  @override
  void initState() {
    super.initState();
    im.onNewMessage.listen(_onMessage);
    im.onMessageUpdated.listen(_onMessage);
    _load();
  }

  Future<void> _load() async {
    final conv = await im.conversationWith(widget.peer);
    if (conv == null) return; // 还没有会话：直接发消息即可，服务端会建
    _convId = conv.id;
    final list = await im.messages(conv.id);
    setState(() => _msgs.addEntries(list.map((m) => MapEntry(m.clientMsgId, m))));
    await im.markRead(conv.id);
  }

  void _onMessage(ImMessage m) {
    final mine = m.from == widget.peer || m.to == widget.peer;
    if (!mine || !mounted) return;
    setState(() => _msgs[m.clientMsgId] = m);
    _convId ??= m.conversationId;
    if (!m.isSelf && _convId != null) im.markRead(_convId!);
  }

  Future<void> _sendText() async {
    final text = _input.text.trim();
    if (text.isEmpty) return;
    _input.clear();
    final r = await im.sendText(widget.peer, text);
    if (r.status != ImMessageStatus.sent && mounted) {
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text('发送失败：${r.errorCode} ${r.errorMessage ?? ''}')));
    }
  }

  @override
  Widget build(BuildContext context) {
    final list = _msgs.values.toList()
      ..sort((a, b) => (a.seq ?? 1 << 30).compareTo(b.seq ?? 1 << 30));
    return Scaffold(
      appBar: AppBar(title: Text(widget.peer)),
      body: Column(children: [
        Expanded(
          child: ListView(children: [
            for (final m in list)
              Align(
                alignment: m.isSelf ? Alignment.centerRight : Alignment.centerLeft,
                child: Padding(
                  padding: const EdgeInsets.all(6),
                  child: Text('${_describe(m)}  [${m.status.name}]'),
                ),
              ),
          ]),
        ),
        Row(children: [
          IconButton(
            icon: const Icon(Icons.image),
            onPressed: () => im.sendImageBytes(widget.peer, _demoPng, filename: 'demo.png'),
          ),
          Expanded(child: TextField(controller: _input, onSubmitted: (_) => _sendText())),
          IconButton(icon: const Icon(Icons.send), onPressed: _sendText),
        ]),
      ]),
    );
  }

  String _describe(ImMessage m) => switch (m.type) {
        'text' => m.content['text'] as String? ?? '',
        'image' => '[图片 ${m.content['width'] ?? '?'}x${m.content['height'] ?? '?'}]',
        'location' => '[位置]',
        _ => m.content['desc'] as String? ?? '[${m.type}]',
      };
}
