# AISmartmail

AISmartmail is a native macOS mail client built with SwiftUI. It focuses on everyday email workflows, Apple Silicon native performance, attachment handling, and AI-assisted mail retrieval without using remote embedding services.

## Highlights

- Native SwiftUI macOS app with a three-column mail layout.
- IMAP, POP3, and SMTP support implemented in Swift, without legacy x86_64 MailCore2 dependencies.
- Generic SMTP/IMAP/POP3 account configuration, with Gmail OAuth support.
- Mailbox synchronization, incremental loading, refresh, drafts, sent mail, archive, junk mail, read state, and starred mail.
- Rich MIME decoding for non-English subjects, senders, bodies, and attachment filenames.
- Attachment display, open, and save workflows with system file icons.
- AI Q&A over vectorized local mail data, with Markdown rendering and clickable citations back to original messages.
- Local-only vectorization through Apple NaturalLanguage `NLEmbedding`; no `openai/text-embedding-3-small` or remote embedding upload is used.
- ZenMux/OpenAI-compatible chat API support for optional AI answering and draft generation.
- Multilingual UI support, including Simplified Chinese, Traditional Chinese, Japanese, Korean, English, French, Russian, Swedish, Ukrainian, and Finnish.

## Privacy

AISmartmail stores mail account passwords, OAuth tokens, and API keys in the macOS Keychain. Vectorization is local-only and is used only for AI search and Q&A. Mail text and readable attachment text are not uploaded for embedding generation.

AI chat features are optional. If no API key or model is configured, regular mail reading, sending, receiving, attachments, drafts, and local vector indexing remain available.

## Requirements

- macOS on Apple Silicon or Intel Mac
- Xcode 16 or newer recommended
- Swift 5 project settings

The project has been validated with an arm64 macOS build destination.

## Build

Open the Xcode project:

```bash
open myMail/myMail.xcodeproj
```

Or build from the command line:

```bash
xcodebuild \
  -project myMail/myMail.xcodeproj \
  -scheme myMail \
  -configuration Debug \
  -destination 'platform=macOS,arch=arm64' \
  build
```

## Repository Layout

- `myMail/myMail.xcodeproj` - Xcode project
- `myMail/myMail/` - app source code
- `myMail/myMailTests/` - unit tests
- `myMail/myMailUITests/` - UI tests
- `docs/` - product, release, support, and privacy documentation

## Current Status

This repository contains an actively developed macOS mail application. The app is functional for core mail workflows and is being refined around provider compatibility, attachment handling, AI search, and App Store readiness.

---

# AISmartmail 中文说明

AISmartmail 是一个使用 SwiftUI 构建的原生 macOS 邮件客户端，重点是日常邮件工作流、Apple Silicon 原生运行、附件处理，以及基于本地向量化数据的 AI 邮件问答。

## 主要功能

- 原生 SwiftUI macOS 应用，三栏邮件界面。
- 使用 Swift 实现 IMAP、POP3、SMTP，不依赖旧的 x86_64 MailCore2。
- 支持通用 SMTP/IMAP/POP3 配置，并支持 Gmail OAuth。
- 支持邮箱同步、增量加载、刷新、草稿、已发送、存档、垃圾邮件、已读状态、星标邮件。
- 改进 MIME 解码，支持非英文标题、发件人、正文和附件名。
- 支持附件显示、打开、另存为，并使用系统文件图标。
- AI 问答基于已经本地向量化的邮件数据，支持 Markdown 渲染和点击引用跳转原始邮件。
- 向量化只使用 Apple NaturalLanguage `NLEmbedding` 本地生成，不使用 `openai/text-embedding-3-small`，也不上传邮件内容生成 embedding。
- 可选 ZenMux/OpenAI 兼容聊天 API，用于 AI 问答和 AI 草稿生成。
- UI 支持简体中文、繁体中文、日语、韩语、英语、法语、俄语、瑞典语、乌克兰语、芬兰语等语言。

## 隐私说明

AISmartmail 会把邮箱密码、OAuth token、API Key 存入 macOS Keychain。向量化只在本机进行，仅服务于 AI 搜索和问答；邮件正文与可读取附件文本不会因为向量化上传到远端。

AI 聊天能力是增强功能。即使用户没有配置 API Key 或模型，邮件读取、发送、接收、附件、草稿和本地向量索引等基础功能也不受影响。

## 构建要求

- macOS，支持 Apple Silicon 或 Intel Mac
- 建议使用 Xcode 16 或更新版本
- Swift 5 工程设置

本项目已通过 arm64 macOS 目标构建验证。

## 构建方式

使用 Xcode 打开：

```bash
open myMail/myMail.xcodeproj
```

或使用命令行构建：

```bash
xcodebuild \
  -project myMail/myMail.xcodeproj \
  -scheme myMail \
  -configuration Debug \
  -destination 'platform=macOS,arch=arm64' \
  build
```

## 目录结构

- `myMail/myMail.xcodeproj` - Xcode 工程
- `myMail/myMail/` - 应用源码
- `myMail/myMailTests/` - 单元测试
- `myMail/myMailUITests/` - UI 测试
- `docs/` - 产品、发布、支持和隐私文档

## 当前状态

本仓库包含一个正在持续完善的 macOS 邮件应用。核心邮件工作流已可用，后续重点包括更多服务商兼容性、附件体验、AI 搜索体验和 App Store 发布准备。
