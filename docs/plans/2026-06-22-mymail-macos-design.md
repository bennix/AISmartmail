# myMail — macOS 邮件客户端设计规格

> 目标:本规格足够完整、明确,可交由另一个 AI 100% 实现。
> 日期:2026-06-22 · 工程:`/Users/nellertcai/myMail`(现有 SwiftUI macOS 脚手架 `myMail`)

---

## 决策摘要

| 维度 | 决策 |
|---|---|
| 技术栈 | 原生 Swift 6 + SwiftUI,延续现有 Xcode 工程,macOS 14+ |
| 协议层 | 原生 Swift 协议层处理 IMAP/SMTP/POP3 + MIME,不依赖旧 C/ObjC 邮件库 |
| 认证 | 应用专用密码为主;Gmail/Outlook 可选 OAuth2 |
| 本地存储 | Core Data / SQLite 本地缓存,支持离线读、增量同步 |
| AI 平台 | ZenMux(OpenAI 兼容),`base_url=https://zenmux.ai/api/v1` |
| AI 检索 | 本地 RAG:邮件本地向量化 → 余弦 Top-K → 带引用的自然语言问答 |
| 向量库 | SQLite + sqlite-vec;embedding 只使用 Apple NLEmbedding 本地生成 |
| AI 回复 | 生成回复草稿填入编辑器,用户改后手动发送(不自动发送) |

---

## §1 整体架构

分层架构(单向数据流,MVVM):

```
┌─────────────────────────────────────────────────────┐
│  SwiftUI Views (三栏:账户/文件夹 · 邮件列表 · 阅读窗格)   │
├─────────────────────────────────────────────────────┤
│  ViewModels (ObservableObject, @MainActor)            │
├─────────────────────────────────────────────────────┤
│  Services 层                                          │
│  • MailService    (原生 Swift IMAP/SMTP/POP3/MIME)    │
│  • SyncEngine     (增量同步 → Core Data)               │
│  • AIService      (ZenMux OpenAI 兼容 API)             │
│  • SearchService  (本地过滤 + AI 自然语言 RAG 问答)      │
│  • EmbeddingService / VectorStore (本地向量化 + 检索)    │
│  • KeychainStore  (密码 / API-Key 加密存储)            │
├─────────────────────────────────────────────────────┤
│  Core Data (本地缓存:Account/Mailbox/Message/Attachment)│
│  SQLite + sqlite-vec (message_vectors)                │
└─────────────────────────────────────────────────────┘
```

**第三方依赖**:不引入旧 C/ObjC 邮件库或其他邮件协议三方库,避免 Intel-only framework 在 Apple Silicon 上产生架构警告。邮件收发、MIME 与认证协议由项目内 Swift 实现;其余全部系统框架:Foundation / SwiftUI / CoreData / Security(Keychain)/ NaturalLanguage / WebKit / URLSession。

**关键原则**:
- 所有网络/磁盘操作走 async/await,UI 永不阻塞。
- 凭据(邮箱密码、ZenMux API-Key)只进 Keychain,绝不落明文(不进 UserDefaults / Core Data)。
- AI 与协议层彻底解耦——AI 只读 Core Data 里的邮件,不直接碰网络收发。

---

## §2 数据模型

### Core Data 实体

```
Account
  id: UUID
  displayName: String              // "我的 Gmail"
  emailAddress: String
  provider: enum {gmail, icloud, outlook, custom}
  authType: enum {password, oauth2}
  imapHost/imapPort/imapTLS
  smtpHost/smtpPort/smtpTLS
  pop3Host/pop3Port/pop3TLS        // 可空
  useProtocol: enum {imap, pop3}
  oauthRefreshTokenRef: String?    // Keychain 引用,非明文
  createdAt: Date
  // 凭据不存这里 → Keychain,以 id 为 key

Mailbox (文件夹)
  id: UUID, accountId → Account
  name: String                     // "INBOX" / "Sent" / "[Gmail]/All Mail"
  role: enum {inbox,sent,drafts,trash,junk,archive,custom}
  uidValidity: Int64               // IMAP 增量同步用
  unreadCount: Int

Message
  id: UUID
  accountId, mailboxId
  uid: Int64                       // IMAP UID
  messageId: String                // RFC Message-ID,跨文件夹去重
  subject, fromAddress, fromName
  toRecipients/cc/bcc: String      // JSON 数组字符串
  date: Date
  snippet: String                  // 预览前 200 字
  bodyPlain: String?               // 缓存正文(懒加载)
  bodyHTML: String?
  flags: enum set {seen,flagged,answered,draft,deleted}
  hasAttachments: Bool
  isBodyDownloaded: Bool           // 懒加载标记
  embeddingState: enum {pending, done, failed}

Attachment
  id, messageId
  filename, mimeType, sizeBytes
  localPath: String?               // 下载后落盘路径
  contentId: String?               // 内联图片 cid:
```

### 向量表(sqlite-vec)

```sql
CREATE VIRTUAL TABLE message_vectors USING vec0(
  message_id TEXT PRIMARY KEY,
  embedding  FLOAT[1536]           -- 维度随 embedding 模型配置
);
```

**关系**:`Account 1—N Mailbox 1—N Message 1—N Attachment`。
**索引**:`Message.messageId` 唯一索引(跨文件夹去重);`(accountId, mailboxId, uid)` 复合索引(增量同步)。
**分离**:正文存 Core Data,embedding 存 sqlite-vec,用 `message_id` 关联。

---

## §3 同步引擎与协议层

### MailService(原生 Swift 协议层)

用项目内 Swift 传输层实现 IMAP/SMTP/POP3、TLS/STARTTLS、MIME 与认证流程,暴露 async/await:

```swift
protocol MailService {
  func connect(_ account: Account) async throws
  func fetchMailboxes() async throws -> [Mailbox]
  func fetchHeaders(mailbox: Mailbox, uidRange: ClosedRange<Int64>) async throws -> [MessageHeader]
  func fetchBody(uid: Int64) async throws -> MessageBody        // 懒加载
  func setFlags(uid: Int64, flags: MessageFlags) async throws
  func moveMessage(uid: Int64, to: Mailbox) async throws
  func sendMessage(_ draft: OutgoingMessage) async throws       // SMTP
  func idle(mailbox: Mailbox) -> AsyncStream<MailboxEvent>      // IMAP IDLE
}
```

### SyncEngine 增量同步策略

1. **首次同步**:拉文件夹列表 → 每文件夹拉最近 N 封(默认 200)header → 存 Core Data,正文不拉。
2. **增量同步**:用 IMAP `UIDVALIDITY` + 本地最大 UID,只拉 `UID > maxLocalUID` 的新邮件;用 `\Seen/\Flagged` 标志位 diff 更新已读/星标。
3. **IDLE 推送**:对 INBOX 开 IMAP IDLE,收到 `EXISTS` 事件触发增量同步,近实时新邮件。
4. **POP3 账户**:无 IDLE/文件夹概念,定时(默认 5 分钟)`UIDL` 拉新邮件到本地 INBOX;`LIST`/`UIDL` 比对已下载列表去重。
5. **正文懒加载**:点开邮件时 `fetchBody`,落 Core Data 并标 `isBodyDownloaded=true`;同时该邮件 embedding 任务入队。

**发送流**:`OutgoingMessage`(收件人/主题/正文/附件)→ 原生 Swift SMTP → 成功后 `APPEND` 到 Sent 文件夹 → 写 Core Data。

**错误处理**:网络错误指数退避重试(≤3 次);认证失败 → 账户标 `needsReauth`,UI 提示重输密码;TLS 失败明确报错,不静默降级到明文。

**并发**:每账户一个 actor 串行化该账户的 IMAP/POP3/SMTP 操作;账户之间并行。

---

## §4 AI 与 RAG 管线

### AIService(ZenMux,OpenAI 兼容)

`base_url=https://zenmux.ai/api/v1`,`Authorization: Bearer <API-Key>`。用于 `/chat/completions`(SSE 流式)等聊天能力;邮件向量化不调用远端 embedding 接口。

```swift
protocol AIService {
  func chat(model: String, messages: [ChatMessage], stream: Bool) -> AsyncThrowingStream<String, Error>
}
```

### A. AI 回复草稿

- 阅读邮件时点「AI 回复」→ 取原邮件(主题/发件人/正文)+ 同线程历史 → system prompt「你是邮件助手,生成礼貌得体的回复草稿」→ 调用户所选对话模型 → **流式填入撰写编辑器**。
- 用户编辑后手动发送。**不自动发送**。
- 可选指令框:用户补「婉拒并说明下周再约」作为额外 user message。

### B. RAG 自然语言检索问答

```
用户提问 "上周 Alice 关于发票的邮件"
  │
  1. LocalNLEmbeddingService.embed(问题) → 查询向量
  2. VectorStore 余弦 Top-K(默认 K=8,可加 date/account 预过滤)
  3. 取回 Top-K 邮件正文,组装带编号 context
  4. ZenMux 对话模型 + system prompt(「仅根据以下邮件回答,标注引用编号」)
  5. 流式输出答案 + 可点击邮件引用 [1][2] → 跳转原邮件
```

### C. 向量化后台任务(EmbeddingIndexer)

- 监听 `Message.embeddingState == pending` 队列。
- 文本 = `主题 + 发件人 + 正文`,超长截断到 embedding 模型上限(取首块,邮件场景够用)。
- 批量(每批 ~16 封)使用 Apple `NLEmbedding` 生成本地向量 → 写 sqlite-vec/SQLite fallback → 标 `done`;失败标 `failed` 退避重试。
- **本地-only**:不使用 `openai/text-embedding-3-small`,也不会把邮件正文或附件文本上传到远端生成 embedding。

### 模型配置

- **对话模型**:下拉,预置 `anthropic/claude-sonnet-4.6` / `z-ai/glm-5v-turbo` / `openai/gpt-5.4`,可增删,单选默认。
- **Embedding 模型**:固定使用本地 NLEmbedding,不提供远端 embedding 模型选择。

> 注:对话模型只用于 AI 回答和草稿生成;向量化独立于对话模型,始终在本机完成。

**隐私提示**:向量化只在本机生成,用于 AI 检索和问答;邮件正文和可读取附件文本不会因为向量化上传。

---

## §5 设置页与凭据加密

### Keychain 存储(KeychainStore)

`kSecClassGenericPassword`,`kSecAttrAccessibleAfterFirstUnlock`,绝不落明文/UserDefaults:

| 条目 | Keychain account key | 值 |
|---|---|---|
| 邮箱密码 / 应用专用密码 | `account.<UUID>.password` | 明文密码 |
| OAuth refresh token | `account.<UUID>.oauth` | refresh token |
| ZenMux API-Key | `zenmux.apikey` | API-Key |

### 设置页(SettingsView,标签式)

**① 账户标签**
- 账户列表 + 「添加账户」。
- 添加流程:选服务商 → 自动填预设 IMAP/SMTP/POP3 主机端口(§6)→ 输入邮箱 + 应用专用密码 → 每服务商旁有「如何获取应用专用密码」帮助链接 → 「测试连接」(实连 IMAP+SMTP 验证)→ 保存。
- Gmail/Outlook 额外显示「用 OAuth 登录」按钮(可选路径)。

**② AI 模型标签**
- **API-Key 输入框**:`SecureField`,显示 `••••••••`。
  - 已保存时显示掩码 `sk-••••1234`(仅露后 4 位)+「显示/隐藏」眼睛按钮 +「更新」。
  - 未保存时:下方提示「还没有 API-Key?」+ **邀请链接按钮**打开 `https://zenmux.ai/invite/GBQMC5`。
- **对话模型**:可增删列表(预置 3 个),「+ 添加模型名」自由输入;单选默认。
- **向量化说明**:固定本地 NLEmbedding,显示「本地向量化」说明与初始化/重建索引按钮;不提供远端 embedding 模型输入。
- 「测试 API-Key」:发最小 chat 请求验证。

**③ 通用标签**
- POP3 轮询间隔、缓存邮件数 N、签名、是否开启向量化。

**加密 UI 原则**:API-Key 与密码任何时候不以明文回显;内存中仅请求时从 Keychain 取用,用后不缓存到可序列化对象。

---

## §6 服务商预设、UI 布局、测试方案

### 服务商预设(添加账户自动填充)

| 服务商 | IMAP | SMTP | POP3 | 应用专用密码生成页 |
|---|---|---|---|---|
| Gmail | imap.gmail.com:993 SSL | smtp.gmail.com:465 SSL | pop.gmail.com:995 | myaccount.google.com/apppasswords |
| iCloud | imap.mail.me.com:993 SSL | smtp.mail.me.com:587 STARTTLS | (不支持) | appleid.apple.com → 应用专用密码 |
| Outlook | outlook.office365.com:993 SSL | smtp.office365.com:587 STARTTLS | outlook.office365.com:995 | account.microsoft.com → 应用密码 |
| 自定义 | 手填 | 手填 | 手填 | — |

注:iCloud 无 POP3;Gmail/Outlook 用应用专用密码需先开两步验证。约束在 UI 内联提示。

### UI 布局(三栏 `NavigationSplitView`)

- **左栏**:账户 → 文件夹树(收件箱/已发送/草稿/垃圾/归档),底部齿轮进设置。
- **中栏**:邮件列表(发件人/主题/预览/日期/未读点/附件夹标),顶部搜索框(普通过滤 +「AI 问答」切换)、刷新、撰写按钮。
- **右栏**:阅读窗格(HTML 正文 `WKWebView` 渲染、附件条、回复/转发/AI 回复/删除工具栏)。
- **撰写窗口**:独立 `Window`,收件人/抄送/主题/正文/附件;AI 草稿流式填入。
- **AI 问答面板**:搜索切到 AI 模式 → 输入自然语言 → 流式答案 + 引用卡片(点击跳邮件)。

### 测试方案

- **单元测试**:MIME 解析、UID 增量 diff、余弦 Top-K 排序、Keychain 读写、服务商预设映射、API-Key 掩码格式化。
- **集成测试**:原生 Swift 协议层连测试 IMAP(GreenMail / 本地 dovecot 容器)跑收发;ZenMux 用 mock URLProtocol 拦截。
- **手动验收清单**:三服务商各加账户能收发;AI 回复草稿生成;RAG 问答带正确引用;重启后凭据从 Keychain 恢复、UI 不泄明文。
- **TDD 流程**:每个 Service 先写协议 + 测试桩,再实现。

---

## 实现里程碑建议(交付顺序)

1. **M1 工程骨架**:原生 Swift 邮件协议层 + Core Data/SQLite 模型 + KeychainStore。
2. **M2 账户与同步**:添加账户/服务商预设/测试连接 → IMAP 首次同步 + 增量 + IDLE → 三栏列表读邮件。
3. **M3 收发**:正文懒加载 + 撰写/发送/回复/转发 + POP3 轮询。
4. **M4 AI**:AIService(ZenMux)+ AI 回复草稿(流式)。
5. **M5 RAG**:EmbeddingIndexer + sqlite-vec + 自然语言问答面板 + 引用跳转 + NLEmbedding 降级。
6. **M6 打磨**:OAuth2 可选路径、错误/重连体验、签名、验收清单全过。
