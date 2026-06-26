//
//  MailModels.swift
//  myMail
//

import Foundation

enum MailProvider: String, CaseIterable, Codable, Identifiable {
    case gmail
    case icloud
    case outlook
    case generic
    case fudan
    case custom

    var id: String { rawValue }

    static var allCases: [MailProvider] {
        [.generic]
    }

    var title: String {
        switch self {
        case .gmail: return "Gmail"
        case .icloud: return "iCloud"
        case .outlook: return "Outlook"
        case .generic, .fudan: return "通用邮箱"
        case .custom: return "自定义"
        }
    }
}

enum MailAuthType: String, Codable, CaseIterable, Identifiable {
    case password
    case appPassword
    case oauth2

    var id: String { rawValue }

    var title: String {
        switch self {
        case .password: return "密码"
        case .appPassword: return "专用密码"
        case .oauth2: return "OAuth2"
        }
    }
}

enum MailProtocolChoice: String, Codable, CaseIterable, Identifiable {
    case imap
    case pop3

    var id: String { rawValue }
}

enum MailboxRole: String, Codable, CaseIterable, Identifiable {
    case inbox
    case sent
    case drafts
    case trash
    case junk
    case archive
    case custom

    var id: String { rawValue }

    var symbolName: String {
        switch self {
        case .inbox: return "tray"
        case .sent: return "paperplane"
        case .drafts: return "doc.text"
        case .trash: return "trash"
        case .junk: return "exclamationmark.octagon"
        case .archive: return "archivebox"
        case .custom: return "folder"
        }
    }
}

enum MessageEmbeddingState: String, Codable, CaseIterable {
    case pending
    case done
    case failed
}

struct MessageFlags: OptionSet, Codable, Hashable, Sendable {
    let rawValue: Int

    static let seen = MessageFlags(rawValue: 1 << 0)
    static let flagged = MessageFlags(rawValue: 1 << 1)
    static let answered = MessageFlags(rawValue: 1 << 2)
    static let draft = MessageFlags(rawValue: 1 << 3)
    static let deleted = MessageFlags(rawValue: 1 << 4)
}

struct ServerEndpoint: Codable, Hashable, Sendable {
    var host: String
    var port: Int
    var tlsMode: String

    var label: String {
        "\(host):\(port) \(tlsDisplayName)"
    }

    var normalizedTLSMode: String {
        Self.normalizeTLSMode(tlsMode)
    }

    var tlsDisplayName: String {
        switch normalizedTLSMode {
        case "SSL":
            return "SSL/TLS"
        case "STARTTLS":
            return "STARTTLS"
        case "NONE":
            return "无加密"
        default:
            return tlsMode
        }
    }

    static let supportedTLSModes = ["SSL", "STARTTLS", "NONE"]

    static func normalizeTLSMode(_ mode: String) -> String {
        let trimmed = mode.trimmingCharacters(in: .whitespacesAndNewlines)
        let compact = trimmed
            .uppercased()
            .replacingOccurrences(of: " ", with: "")
            .replacingOccurrences(of: "-", with: "")
            .replacingOccurrences(of: "_", with: "")
            .replacingOccurrences(of: "/", with: "")
        switch compact {
        case "SSL", "TLS", "SSLTLS":
            return "SSL"
        case "STARTTLS":
            return "STARTTLS"
        case "NONE", "PLAIN", "CLEAR", "CLEARTEXT", "NOTLS", "无加密", "不加密":
            return "NONE"
        default:
            return trimmed.uppercased()
        }
    }
}

struct MailAccount: Identifiable, Codable, Hashable, Sendable {
    var id: UUID
    var displayName: String
    var emailAddress: String
    var provider: MailProvider
    var authType: MailAuthType
    var imap: ServerEndpoint
    var smtp: ServerEndpoint
    var pop3: ServerEndpoint?
    var useProtocol: MailProtocolChoice
    var oauthRefreshTokenRef: String?
    var createdAt: Date
    var needsReauth: Bool

    static func demo() -> MailAccount {
        let preset = ProviderPreset.preset(for: .gmail)
        return MailAccount(
            id: UUID(uuidString: "75B0A9FD-7C3D-4052-8E89-D1488F6B12A7") ?? UUID(),
            displayName: "我的 Gmail",
            emailAddress: "me@example.com",
            provider: .gmail,
            authType: .appPassword,
            imap: preset.imap,
            smtp: preset.smtp,
            pop3: preset.pop3,
            useProtocol: .imap,
            oauthRefreshTokenRef: nil,
            createdAt: Date(),
            needsReauth: false
        )
    }
}

struct Mailbox: Identifiable, Codable, Hashable, Sendable {
    var id: UUID
    var accountId: UUID
    var name: String
    var role: MailboxRole
    var uidValidity: Int64
    var unreadCount: Int

    static func demoSet(accountId: UUID) -> [Mailbox] {
        [
            Mailbox(id: UUID(uuidString: "1B5A2855-C91E-4D9B-B5C8-773DBCC387AA") ?? UUID(), accountId: accountId, name: "INBOX", role: .inbox, uidValidity: 1, unreadCount: 2),
            Mailbox(id: UUID(uuidString: "D9C57B70-BA39-4642-93CB-5D9D0B519202") ?? UUID(), accountId: accountId, name: "Sent", role: .sent, uidValidity: 1, unreadCount: 0),
            Mailbox(id: UUID(uuidString: "C728E2A1-52DA-41D5-938D-2E8AF72B4F7B") ?? UUID(), accountId: accountId, name: "Drafts", role: .drafts, uidValidity: 1, unreadCount: 0),
            Mailbox(id: UUID(uuidString: "F76D13A7-9185-48F2-89C9-EE2A121A21A6") ?? UUID(), accountId: accountId, name: "Archive", role: .archive, uidValidity: 1, unreadCount: 0),
            Mailbox(id: UUID(uuidString: "E5F90E12-836B-4E0E-89BE-B0E33D232721") ?? UUID(), accountId: accountId, name: "Trash", role: .trash, uidValidity: 1, unreadCount: 0),
            Mailbox(id: UUID(uuidString: "14AC4399-2F86-4110-8153-FE42EFA8255C") ?? UUID(), accountId: accountId, name: "Junk", role: .junk, uidValidity: 1, unreadCount: 0)
        ]
    }
}

struct MailMessage: Identifiable, Codable, Hashable, Sendable {
    var id: UUID
    var accountId: UUID
    var mailboxId: UUID
    var uid: Int64
    var messageId: String
    var subject: String
    var fromAddress: String
    var fromName: String
    var toRecipientsJSON: String
    var ccRecipientsJSON: String
    var bccRecipientsJSON: String
    var date: Date
    var receivedDate: Date? = nil
    var snippet: String
    var bodyPlain: String?
    var bodyHTML: String?
    var flags: MessageFlags
    var hasAttachments: Bool
    var isBodyDownloaded: Bool
    var embeddingState: MessageEmbeddingState

    var senderDisplayName: String {
        fromName.isEmpty ? fromAddress : fromName
    }

    var sortDate: Date {
        receivedDate ?? date
    }

    var isUnread: Bool {
        !flags.contains(.seen)
    }

    static func demoMessages(accountId: UUID, inboxId: UUID) -> [MailMessage] {
        [
            MailMessage(
                id: UUID(uuidString: "88E0DC28-10D2-437F-9897-B2C475320A4C") ?? UUID(),
                accountId: accountId,
                mailboxId: inboxId,
                uid: 231,
                messageId: "<invoice-alice@example.com>",
                subject: "上周发票和合同附件",
                fromAddress: "alice@example.com",
                fromName: "Alice Chen",
                toRecipientsJSON: "[\"me@example.com\"]",
                ccRecipientsJSON: "[]",
                bccRecipientsJSON: "[]",
                date: Date(timeIntervalSinceNow: -3_600 * 9),
                snippet: "我把上周讨论的发票和合同版本一起发来，请确认金额和抬头。",
                bodyPlain: "你好，\n\n我把上周讨论的发票和合同版本一起发来。请确认金额、抬头以及付款日期。如果没有问题，我们今天就可以走归档流程。\n\nAlice",
                bodyHTML: "<p>你好，</p><p>我把上周讨论的发票和合同版本一起发来。请确认金额、抬头以及付款日期。</p><p>Alice</p>",
                flags: [],
                hasAttachments: true,
                isBodyDownloaded: true,
                embeddingState: .done
            ),
            MailMessage(
                id: UUID(uuidString: "9B86EA9B-C09B-45BE-A7C9-8B48CC7227A9") ?? UUID(),
                accountId: accountId,
                mailboxId: inboxId,
                uid: 232,
                messageId: "<schedule-bob@example.com>",
                subject: "下周产品评审时间",
                fromAddress: "bob@example.com",
                fromName: "Bob Liu",
                toRecipientsJSON: "[\"me@example.com\"]",
                ccRecipientsJSON: "[]",
                bccRecipientsJSON: "[]",
                date: Date(timeIntervalSinceNow: -3_600 * 2),
                snippet: "我们可以把产品评审放到周三上午，AI 邮件搜索原型也一起看。",
                bodyPlain: "我们可以把产品评审放到周三上午。届时请带上 AI 邮件搜索原型，重点看引用跳转是否顺畅。",
                bodyHTML: "<p>我们可以把产品评审放到周三上午。届时请带上 AI 邮件搜索原型。</p>",
                flags: [.seen],
                hasAttachments: false,
                isBodyDownloaded: true,
                embeddingState: .done
            ),
            MailMessage(
                id: UUID(uuidString: "C6701302-385C-4931-A37F-BB8D4CF4E98F") ?? UUID(),
                accountId: accountId,
                mailboxId: inboxId,
                uid: 233,
                messageId: "<security-notice@example.com>",
                subject: "应用专用密码已创建",
                fromAddress: "security@example.com",
                fromName: "Security",
                toRecipientsJSON: "[\"me@example.com\"]",
                ccRecipientsJSON: "[]",
                bccRecipientsJSON: "[]",
                date: Date(timeIntervalSinceNow: -1_200),
                snippet: "你的邮箱应用专用密码已创建，请只在受信任的客户端中使用。",
                bodyPlain: "你的邮箱应用专用密码已创建。请只在受信任的客户端中使用，并在不再需要时撤销。",
                bodyHTML: "<p>你的邮箱应用专用密码已创建。请只在受信任的客户端中使用。</p>",
                flags: [],
                hasAttachments: false,
                isBodyDownloaded: true,
                embeddingState: .pending
            )
        ]
    }
}

struct MailAttachment: Identifiable, Codable, Hashable, Sendable {
    var id: UUID
    var messageId: UUID
    var filename: String
    var mimeType: String
    var sizeBytes: Int64
    var localPath: String?
    var contentId: String?
    var decodedContent: Data? = nil

    private enum CodingKeys: String, CodingKey {
        case id
        case messageId
        case filename
        case mimeType
        case sizeBytes
        case localPath
        case contentId
    }
}

struct MessageHeader: Codable, Hashable, Sendable {
    var uid: Int64
    var messageId: String
    var subject: String
    var fromAddress: String
    var fromName: String
    var date: Date
    var receivedDate: Date? = nil
    var flags: MessageFlags
}

struct MessageBody: Codable, Hashable, Sendable {
    var plain: String
    var html: String?
    var attachments: [MailAttachment]
}

struct OutgoingMessage: Codable, Hashable, Sendable {
    var to: [String]
    var cc: [String]
    var bcc: [String]
    var subject: String
    var bodyPlain: String
    var attachmentURLs: [URL]
}

struct ComposeDraft: Codable, Hashable {
    var to: String = ""
    var cc: String = ""
    var subject: String = ""
    var body: String = ""
    var instruction: String = ""
    var attachmentURLs: [URL] = []
    var sendingAccountID: UUID?
}

struct ChatMessage: Codable, Hashable, Sendable {
    var role: String
    var content: String
}

struct VectorMatch: Codable, Hashable, Sendable {
    var messageId: UUID
    var score: Double
}

struct SearchAnswer: Identifiable, Hashable {
    var id = UUID()
    var question: String
    var answer: String
    var citations: [MailMessage]
}

struct ProviderPreset: Hashable, Sendable {
    var provider: MailProvider
    var imap: ServerEndpoint
    var smtp: ServerEndpoint
    var pop3: ServerEndpoint?
    var appPasswordHelpURL: URL?
    var inlineNote: String

    var supportsOAuth2: Bool {
        provider == .gmail || provider == .outlook
    }

    var oauthHelpURL: URL? {
        switch provider {
        case .gmail:
            return URL(string: "https://developers.google.com/identity/protocols/oauth2")
        case .outlook:
            return URL(string: "https://learn.microsoft.com/en-us/entra/identity-platform/v2-oauth2-auth-code-flow")
        case .icloud, .generic, .fudan, .custom:
            return nil
        }
    }

    static func preset(for provider: MailProvider) -> ProviderPreset {
        switch provider {
        case .gmail:
            return ProviderPreset(
                provider: provider,
                imap: ServerEndpoint(host: "imap.gmail.com", port: 993, tlsMode: "SSL"),
                smtp: ServerEndpoint(host: "smtp.gmail.com", port: 465, tlsMode: "SSL"),
                pop3: ServerEndpoint(host: "pop.gmail.com", port: 995, tlsMode: "SSL"),
                appPasswordHelpURL: URL(string: "https://myaccount.google.com/apppasswords"),
                inlineNote: "推荐使用“浏览器登录”连接 Google 账号；应用专用密码仅作为开启两步验证后的备用方式。"
            )
        case .icloud:
            return ProviderPreset(
                provider: provider,
                imap: ServerEndpoint(host: "imap.mail.me.com", port: 993, tlsMode: "SSL"),
                smtp: ServerEndpoint(host: "smtp.mail.me.com", port: 587, tlsMode: "STARTTLS"),
                pop3: nil,
                appPasswordHelpURL: URL(string: "https://appleid.apple.com"),
                inlineNote: "iCloud 不支持 POP3，请使用 IMAP 和应用专用密码。"
            )
        case .outlook:
            return ProviderPreset(
                provider: provider,
                imap: ServerEndpoint(host: "outlook.office365.com", port: 993, tlsMode: "SSL"),
                smtp: ServerEndpoint(host: "smtp.office365.com", port: 587, tlsMode: "STARTTLS"),
                pop3: ServerEndpoint(host: "outlook.office365.com", port: 995, tlsMode: "SSL"),
                appPasswordHelpURL: URL(string: "https://account.microsoft.com"),
                inlineNote: "应用专用密码需要先开启两步验证；也可后续接入 OAuth。"
            )
        case .generic, .fudan:
            return ProviderPreset(
                provider: provider,
                imap: ServerEndpoint(host: "", port: 993, tlsMode: "SSL"),
                smtp: ServerEndpoint(host: "", port: 465, tlsMode: "SSL"),
                pop3: ServerEndpoint(host: "", port: 995, tlsMode: "SSL"),
                appPasswordHelpURL: nil,
                inlineNote: "适用于学校或企业邮箱。可填写 SSL/TLS、STARTTLS 或无加密的旧端口；密码仅写入 Keychain，不会明文回显。"
            )
        case .custom:
            return ProviderPreset(
                provider: provider,
                imap: ServerEndpoint(host: "", port: 993, tlsMode: "SSL"),
                smtp: ServerEndpoint(host: "", port: 587, tlsMode: "STARTTLS"),
                pop3: ServerEndpoint(host: "", port: 995, tlsMode: "SSL"),
                appPasswordHelpURL: nil,
                inlineNote: "请手动填写服务器、端口与 TLS 设置。"
            )
        }
    }
}

enum SecretMaskFormatter {
    static func maskAPIKey(_ value: String?) -> String {
        guard let value, !value.isEmpty else { return "未保存" }
        let suffix = String(value.suffix(4))
        return "sk-••••\(suffix)"
    }
}

enum UIDSyncPlanner {
    static func newUIDRanges(remoteUIDs: [Int64], localMaxUID: Int64) -> [ClosedRange<Int64>] {
        let sorted = remoteUIDs.filter { $0 > localMaxUID }.sorted()
        guard var start = sorted.first else { return [] }
        var previous = start
        var ranges: [ClosedRange<Int64>] = []

        for uid in sorted.dropFirst() {
            if uid == previous + 1 {
                previous = uid
            } else {
                ranges.append(start...previous)
                start = uid
                previous = uid
            }
        }

        ranges.append(start...previous)
        return ranges
    }

    static func headersToInsert(_ headers: [MessageHeader], existingMessageIDs: Set<String>) -> [MessageHeader] {
        headers.filter { !existingMessageIDs.contains($0.messageId) }
    }

    static func headersToInsert(
        _ headers: [MessageHeader],
        existingUIDs: Set<Int64>,
        existingMessageIDs: Set<String>
    ) -> [MessageHeader] {
        headers.filter { header in
            !existingUIDs.contains(header.uid) && !existingMessageIDs.contains(header.messageId)
        }
    }
}
