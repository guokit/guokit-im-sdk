# guokit IM 接入套件

guokit IM（果壳软件）是可私有部署的即时通讯服务。本仓库是它的**公开接入资料**：接口文档、OpenAPI 规范、给 AI 编码助手用的接入说明（`llms.txt` 与 Agent Skill）。
各语言 SDK 与 UI 组件会陆续加入本仓库。

需要 IM 服务端 **≥ v1.8.0**。

| 内容 | 位置 |
|---|---|
| 接入文档（人读） | [docs/IM接入文档.md](docs/IM接入文档.md) |
| OpenAPI 3.1 规范（可导入 Postman / Apifox） | [spec/openapi.yaml](spec/openapi.yaml) |
| AI 接入说明 | [llms.txt](llms.txt)、[llms-full.txt](llms-full.txt)、[skills/guokit-im](skills/guokit-im/SKILL.md) |

## 五分钟上手

```
接入方后端 ──X-Api-Key──▶ /api/im/v1/server/*   导入用户、签令牌、封禁、黑名单、代发
客户端     ──Bearer────▶ /api/im/v1/*          发消息、会话、已读、上传、黑名单
客户端     ◀─WebSocket── /api/im/v1/connect/websocket   只收推送（Centrifuge 协议）
接入方后端 ◀─签名回调──  before_send（同步审核） / after_send（异步，离线推送）
```

1. **拿 Key**：IM 后台「IM → 接入应用」新建，复制 API Key（只显示一次），放服务端配置，**不要下发客户端**。
2. **导入用户**：

   ```bash
   curl -X PUT https://im.example.com/api/im/v1/server/users/u1001 \
     -H "X-Api-Key: imk_xxx" -H "Content-Type: application/json" \
     -d '{"nickname":"张三","avatar_url":"https://cdn.example.com/a.png"}'
   ```

3. **登录时签令牌**，交给客户端：

   ```bash
   curl -X POST https://im.example.com/api/im/v1/server/users/u1001/token -H "X-Api-Key: imk_xxx"
   # {"code":0,"message":"ok","data":{"token":"…","expires_at":"2026-11-27 10:00:00"}}
   ```

4. **客户端连长连接**（Flutter / Web 用官方 `centrifuge` SDK，令牌作为 `token`），每次连上都按会话 `max_seq` 对账补拉。
5. **发一条消息**：

   ```bash
   curl -X POST https://im.example.com/api/im/v1/messages \
     -H "Authorization: Bearer <用户令牌>" -H "Content-Type: application/json" \
     -d '{"to":"u1002","type":"text","content":{"text":"你好"},"client_msg_id":"6f1c7f3e-0b8a-4a59-9d1e-2b1e5f0c9a11"}'
   ```

成功时 `code` 是**数字** `0`，失败时是字符串错误码。完整流程、同步规则与回调见[接入文档](docs/IM接入文档.md)。

## 让 AI 帮你写对接代码

Agent Skill 里有接入清单和十几条最容易写错的地方（令牌失效与暂时故障的区分、断线对账、发送重试幂等、回调验签……），比直接让 AI 读接口文档写得更对。

**Claude Code**：把 `skills/guokit-im` 目录放进项目的 `.claude/skills/`（只对本项目生效）或 `~/.claude/skills/`（全局）：

```bash
git clone --depth 1 https://github.com/guokit/im-sdk.git /tmp/guokit-im-sdk
mkdir -p .claude/skills && cp -R /tmp/guokit-im-sdk/skills/guokit-im .claude/skills/
```

之后在对话里提到「接入 guokit IM」即会自动启用。

**Codex**：支持 Agent Skills 的版本，把同一目录放进 `~/.codex/skills/`。

**Cursor 及其他工具**：把下面的链接交给 AI（Cursor 可在 Docs 设置里添加为文档源），或把 `SKILL.md` 内容放进项目规则文件：

```
https://raw.githubusercontent.com/guokit/im-sdk/main/llms-full.txt
```

## 许可证

[MIT](LICENSE) © 2026 济宁市果壳信息科技有限公司
