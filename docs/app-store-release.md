# myMail App Store Release Pack

Date: 2026-06-26

This document is the App Store submission checklist and listing copy for the macOS app target `myMail`.

For a requirement-by-requirement completion audit, see `docs/app-store-completion-audit.md`.

## App Store Compliance Audit

### Current Project State

- App Sandbox: enabled.
- Hardened Runtime: enabled.
- Network client entitlement: enabled, required for IMAP/SMTP/POP3, OAuth, and optional AI requests.
- User-selected file read/write: enabled, required for opening and saving attachments chosen by the user.
- App icon: complete macOS `AppIcon.appiconset` with 16, 32, 128, 256, 512, and 1024 pixel variants.
- App category: `LSApplicationCategoryType=public.app-category.productivity`.
- Export compliance helper: `ITSAppUsesNonExemptEncryption=false` for standard mail security, OAuth/PKCE, Keychain storage, and hashing.
- Privacy manifest: added at `myMail/PrivacyInfo.xcprivacy`.
- Third-party SDKs: none currently bundled.
- MailCore2 / Intel-only dependency: not present in the project.
- Release architecture setting: `ARCHS = arm64 x86_64`, so App Store archives can support both Apple silicon and Intel Macs.
- External account credentials: stored in Keychain, not in UserDefaults or local mail cache.
- Optional AI vectorization: user-facing privacy notice exists; local NLEmbedding fallback exists.

### Verified Build Evidence

- `xcodebuild -project myMail/myMail.xcodeproj -scheme myMail -configuration Release -destination 'platform=macOS,arch=arm64' build`: passed.
- `xcodebuild -project myMail/myMail.xcodeproj -scheme myMail -configuration Release -destination 'generic/platform=macOS' build`: passed and produced a universal binary.
- `xcodebuild build-for-testing -project myMail/myMail.xcodeproj -scheme myMail -destination 'platform=macOS,arch=arm64'`: passed.
- `lipo -archs .../Release/myMail.app/Contents/MacOS/myMail`: `x86_64 arm64`.
- Built app contains `Contents/Resources/PrivacyInfo.xcprivacy`.
- Built app contains compiled `Contents/Resources/AppIcon.icns`.
- `codesign --verify --deep --strict --verbose=2`: passed for the local Release build.
- Release build settings include `ENABLE_APP_SANDBOX=YES`, `ENABLE_HARDENED_RUNTIME=YES`, `ENABLE_OUTGOING_NETWORK_CONNECTIONS=YES`, and `ENABLE_USER_SELECTED_FILES=readwrite`.
- Local development-signed builds contain `get-task-allow=true`; do not upload a development-signed build. Upload only an Apple Distribution/App Store archive exported through Xcode Organizer or `xcodebuild -exportArchive`.
- `xcodebuild test` did not complete in this desktop session because the XCTest runner timed out or hung while enabling/starting automation. Treat this as a local test-runner issue to re-check in Xcode or CI before submission; it does not affect the verified Release build artifacts above.

### Review Guideline Risks And Mitigations

- User data and mail content: mail content is sensitive. Keep the in-app privacy notice before AI vectorization and ensure App Store Connect privacy labels disclose email address, emails/text messages, and user content used for app functionality.
- AI behavior: AI is an enhancement. It must not send mail automatically. Current behavior generates drafts only and requires the user to send manually.
- Legacy unencrypted mail ports: allowed for custom mail servers, but UI should keep SSL/TLS and STARTTLS as the preferred choices and should not silently downgrade encryption.
- OAuth: if Gmail OAuth is submitted publicly, the configured OAuth client and redirect URI must be valid for the production bundle identifier and URL scheme.
- Account deletion: app removes local account configuration, local cache, and Keychain credentials. This is important for review if account creation is available.
- Privacy policy: a public privacy policy URL must be supplied in App Store Connect before submission.
- In-app privacy access: App Review also expects an easy way to access privacy information. Use the policy draft in `docs/privacy-policy.md` for the public URL and add an in-app link before submission if the final support site has a stable URL.
- Demo/test data: no reviewer-only hardcoded personal mailbox credentials should be included.

### Required Manual App Store Connect Items

- Upload privacy policy URL.
- Upload support URL. A support-page draft is available at `docs/support.md`.
- Fill App Privacy details consistently with the privacy manifest:
  - Email Address: collected, linked to user, not used for tracking, purpose App Functionality.
  - Emails or Text Messages: collected only for app functionality when syncing mail or when the user enables remote AI/vectorization, linked to user, not used for tracking.
  - Other User Content: collected only for attachments and AI/vectorization context, linked to user, not used for tracking.
  - No tracking.
  - No third-party advertising.
- Upload screenshots for at least one supported macOS display size.
- Confirm age rating: no objectionable content generated by the app itself; user mail content may vary.
- Confirm support URL and marketing URL.
- Confirm copyright owner.
- Archive with App Store distribution signing, then verify exported entitlements do not include `com.apple.security.get-task-allow`.
- Answer export-compliance encryption questions consistently with `ITSAppUsesNonExemptEncryption=false`: the app uses standard TLS/SSL network encryption, OAuth/PKCE, Keychain, and CryptoKit hashing for app functionality. Do not claim custom cryptography.
- Provide review notes for test accounts or demo flow. If real mail login is required, provide a review-safe demo mailbox and app-specific password; never embed these in the app binary or repository.

## App Identity

### Primary Name

myMail

### Subtitle

Simplified Chinese:

> 原生邮件与本地 AI 检索

English:

> Native mail with AI search

## Promotional Text

Simplified Chinese:

> myMail 是一款原生 macOS 邮件客户端，支持 IMAP/SMTP/POP3、附件、星标、已读同步和可选 AI 邮件问答。AI 功能可选择本地向量索引或经用户同意后使用远程模型。

English:

> myMail is a native macOS mail client with IMAP/SMTP/POP3, attachments, stars, read-state sync, and optional AI question answering over your indexed mail.

## Description

Simplified Chinese:

> myMail 是为 macOS 打造的原生邮件客户端，适合需要管理学校、企业或个人邮箱的用户。
>
> 它支持通用 IMAP/SMTP/POP3 服务器配置，能够接收、阅读、搜索和发送邮件，并处理附件、星标、已读状态和垃圾邮件文件夹。邮件列表按服务器收件时间排序，帮助你更准确地查看最新邮件。
>
> myMail 还提供可选 AI 增强功能。你可以初始化本地向量索引，让 AI 基于已索引的邮件内容回答问题并返回可点击的相关邮件引用。AI 功能不是基本收发邮件的必要条件；不配置 AI 模型也可以正常使用邮件功能。若选择远程向量化或远程问答，应用会在启用前提示邮件内容可能被发送到所配置的服务商；你也可以选择本地 NLEmbedding 方案。
>
> 主要功能：
> - 通用 IMAP/SMTP/POP3 邮箱配置
> - Gmail OAuth 登录支持
> - 附件打开与保存
> - 星标邮件与星标专栏
> - 已读状态同步
> - 垃圾邮件、收件箱、发件箱等文件夹识别
> - 按收件时间、发件人排序
> - 邮件正文和附件文本的可选向量化索引
> - 基于邮件索引的 AI 问答和引用跳转
> - Keychain 凭据保存
>
> myMail 不包含广告，不进行跨 App 或跨网站追踪。

English:

> myMail is a native macOS mail client for school, work, and personal mail accounts.
>
> It supports generic IMAP/SMTP/POP3 configuration, mail reading, search, sending, attachments, starred messages, read-state sync, and junk mail folders. Message lists are sorted by server received date so the newest mail appears in the right order even when sender date headers are unusual.
>
> myMail also includes optional AI enhancements. You can initialize a local vector index and ask questions over indexed mail, with clickable references back to the original messages. AI is not required for normal mail. If you choose remote vectorization or remote question answering, myMail explains that mail content may be sent to the configured provider before you enable it. You can also choose local NLEmbedding for offline indexing.
>
> Features:
> - Generic IMAP/SMTP/POP3 account setup
> - Gmail OAuth support
> - Attachment open and save
> - Starred mail list
> - Read-state sync
> - Inbox, sent, junk, archive, drafts, and custom folders
> - Sort by received date or sender
> - Optional vector indexing for mail and readable attachment text
> - AI answers with source message references
> - Keychain credential storage
>
> myMail has no ads and does not track you across apps or websites.

## Keywords

Simplified Chinese, 55 characters / 93 UTF-8 bytes:

> 邮件,邮箱,IMAP,SMTP,POP3,AI,附件,星标,Gmail,OAuth,本地索引,邮件搜索,客户端

English, 95 characters:

> email,mail,imap,smtp,pop3,ai,assistant,search,attachments,gmail,oauth,vector,inbox,productivity

## Metadata Length Check

- Name `myMail`: 6 characters.
- Simplified Chinese subtitle: 13 characters.
- English subtitle: 26 characters.
- Simplified Chinese promotional text: 93 characters.
- English promotional text: 153 characters.
- Simplified Chinese keywords: 55 characters / 93 UTF-8 bytes.
- English keywords: 95 characters / 95 UTF-8 bytes.

## What's New

Simplified Chinese:

> 改进 IMAP 同步、垃圾邮件文件夹识别、附件处理、收件时间排序和 AI 邮件问答体验。

English:

> Improved IMAP sync, junk folder recognition, attachment handling, received-date sorting, and AI mail Q&A.

## Support And Privacy Policy Draft

Support summary:

> For support, include your macOS version, mail provider, account type, and whether the issue affects receiving, sending, attachments, or AI indexing. Do not send passwords or app-specific passwords.

Privacy policy summary:

> myMail stores account configuration and local mail cache on your Mac. Passwords, app-specific passwords, OAuth tokens, and API keys are stored in Keychain. Mail content is sent to your configured mail servers for normal mail functionality. Optional AI features may send mail text and readable attachment text to the AI provider you configure after you enable the feature and accept the notice. You may use local NLEmbedding to avoid remote vectorization. myMail does not sell data, show ads, or track users across apps or websites.

## Screenshot Plan

Use clean demo data, not personal mail.

1. Main three-column mail view: accounts, message list, and reading pane.
2. Account setup: generic IMAP/SMTP settings and connection feedback.
3. Attachment view: system-style attachment icons, open/save controls.
4. Starred mail view.
5. AI Q&A view with rendered answer and source-message list.
6. Vectorization settings showing local/remote choice and privacy explanation.

## Icon Rationale

The app icon uses:

- Envelope: primary mail function.
- Simple fold lines: mail reading, receiving, and sending.
- Blue palette: productivity, trust, and macOS-friendly contrast.
- Minimal detail: legible at Dock, Finder, and App Store sizes without decorative badges.

The icon avoids Apple logos, third-party provider logos, trademarked mail service marks, and screenshots of UI.

## References

- App Review Guidelines: https://developer.apple.com/app-store/review/guidelines/
- App privacy details: https://developer.apple.com/app-store/app-privacy-details/
- Privacy manifest files: https://developer.apple.com/documentation/bundleresources/privacy_manifest_files
- Describing use of required reason APIs: https://developer.apple.com/documentation/bundleresources/describing-use-of-required-reason-api
- App metadata reference: https://developer.apple.com/help/app-store-connect/reference/app-metadata-reference
- Apple Human Interface Guidelines, app icons: https://developer.apple.com/design/human-interface-guidelines/app-icons
