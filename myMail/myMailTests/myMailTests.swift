//
//  myMailTests.swift
//  myMailTests
//

import CoreData
import Foundation
import Testing
@testable import myMail

struct myMailTests {
    @Test func appLocalizerCoversEverySupportedLanguage() {
        for language in AppLanguage.allCases {
            for key in AppText.allCases {
                let text = AppLocalizer.text(key, language: language)
                #expect(!text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                #expect(text != key.rawValue)
            }
        }

        #expect(AppLocalizer.text(.openAttachment, language: .japanese) == "添付ファイルを開く")
        #expect(AppLocalizer.text(.apiKeyValidationPassed, language: .russian) == "Проверка API-Key успешна.")
        #expect(AppLocalizer.text(.vectorIndexOptionalInfo, language: .finnish).contains("Vektori-indeksi"))
    }

    @Test func providerPresetsMatchSpecification() {
        let gmail = ProviderPreset.preset(for: .gmail)
        #expect(gmail.imap.host == "imap.gmail.com")
        #expect(gmail.imap.port == 993)
        #expect(gmail.smtp.host == "smtp.gmail.com")
        #expect(gmail.smtp.port == 465)
        #expect(gmail.smtp.tlsMode == "SSL")
        #expect(gmail.pop3?.host == "pop.gmail.com")
        #expect(gmail.pop3?.port == 995)
        #expect(gmail.supportsOAuth2)
        #expect(gmail.oauthHelpURL != nil)
        #expect(gmail.inlineNote.contains("浏览器登录"))

        let icloud = ProviderPreset.preset(for: .icloud)
        #expect(icloud.pop3 == nil)
        #expect(icloud.smtp.tlsMode == "STARTTLS")
        #expect(!icloud.supportsOAuth2)

        let outlook = ProviderPreset.preset(for: .outlook)
        #expect(outlook.imap.host == "outlook.office365.com")
        #expect(outlook.smtp.port == 587)
        #expect(outlook.supportsOAuth2)

        let generic = ProviderPreset.preset(for: .generic)
        #expect(generic.imap.host.isEmpty)
        #expect(generic.imap.port == 993)
        #expect(generic.smtp.host.isEmpty)
        #expect(generic.smtp.port == 465)
        #expect(generic.pop3?.port == 995)
        #expect(generic.inlineNote.contains("无加密"))
        #expect(generic.inlineNote.contains("旧端口"))
        #expect(!generic.supportsOAuth2)
        #expect(ServerEndpoint.normalizeTLSMode("SSL/TLS") == "SSL")
        #expect(ServerEndpoint.normalizeTLSMode("plain") == "NONE")
        #expect(ServerEndpoint(host: "smtp.example.com", port: 25, tlsMode: "NONE").label == "smtp.example.com:25 无加密")
        #expect(MailProvider.allCases == [.generic])
        #expect(!MailProvider.allCases.contains(.gmail))
        #expect(!MailProvider.allCases.contains(.icloud))
        #expect(!MailProvider.allCases.contains(.outlook))
        #expect(!MailProvider.allCases.contains(.fudan))
    }

    @MainActor
    @Test func existingGmailAccountsMigrateToOfficialPreset() {
        let preset = ProviderPreset.preset(for: .gmail)
        var account = MailAccount.demo()
        account.provider = .gmail
        account.imap = preset.imap
        account.smtp = ServerEndpoint(host: "smtp.gmail.com", port: 587, tlsMode: "STARTTLS")
        account.pop3 = preset.pop3
        let store = MemoryMailStore(snapshot: MailStoreSnapshot(accounts: [account], mailboxes: [], messages: [], attachments: []))

        let viewModel = MailAppViewModel(
            secretStore: MemorySecretStore(),
            mailStore: store,
            mailService: StubMailService(body: MessageBody(plain: "", html: nil, attachments: [])),
            aiService: StubAIService(chunks: []),
            vectorStore: InMemoryVectorStore(),
            embeddingService: LocalNLEmbeddingService(),
            autoBootstrapEmbeddings: false
        )

        #expect(viewModel.accounts.first?.smtp == preset.smtp)
        #expect(store.savedSnapshots.last?.accounts.first?.smtp == preset.smtp)
    }

    @MainActor
    @Test func visibleMessagesSortByDateAndSender() {
        let account = MailAccount.demo()
        let inbox = Mailbox(id: UUID(), accountId: account.id, name: "INBOX", role: .inbox, uidValidity: 1, unreadCount: 0)
        func message(uid: Int64, sender: String, date: Date) -> MailMessage {
            MailMessage(
                id: UUID(),
                accountId: account.id,
                mailboxId: inbox.id,
                uid: uid,
                messageId: "<\(uid)@example.com>",
                subject: sender,
                fromAddress: "\(sender.lowercased())@example.com",
                fromName: sender,
                toRecipientsJSON: "[]",
                ccRecipientsJSON: "[]",
                bccRecipientsJSON: "[]",
                date: date,
                snippet: "",
                bodyPlain: nil,
                bodyHTML: nil,
                flags: [],
                hasAttachments: false,
                isBodyDownloaded: false,
                embeddingState: .pending
            )
        }
        let baseDate = Date(timeIntervalSince1970: 1_000)
        let bobOld = message(uid: 1, sender: "Bob", date: baseDate)
        let aliceMiddle = message(uid: 2, sender: "Alice", date: baseDate.addingTimeInterval(60))
        let carolNew = message(uid: 3, sender: "Carol", date: baseDate.addingTimeInterval(120))
        let store = MemoryMailStore(snapshot: MailStoreSnapshot(
            accounts: [account],
            mailboxes: [inbox],
            messages: [bobOld, carolNew, aliceMiddle],
            attachments: []
        ))
        let viewModel = MailAppViewModel(
            secretStore: MemorySecretStore(),
            mailStore: store,
            mailService: StubMailService(body: MessageBody(plain: "", html: nil, attachments: [])),
            aiService: StubAIService(chunks: []),
            vectorStore: InMemoryVectorStore(),
            embeddingService: LocalNLEmbeddingService(),
            autoBootstrapEmbeddings: false
        )

        #expect(viewModel.visibleMessages.map(\.id) == [carolNew.id, aliceMiddle.id, bobOld.id])

        viewModel.messageSortAscending = true
        #expect(viewModel.visibleMessages.map(\.id) == [bobOld.id, aliceMiddle.id, carolNew.id])

        viewModel.messageSortField = .sender
        #expect(viewModel.visibleMessages.map(\.id) == [aliceMiddle.id, bobOld.id, carolNew.id])

        viewModel.messageSortAscending = false
        #expect(viewModel.visibleMessages.map(\.id) == [carolNew.id, bobOld.id, aliceMiddle.id])
    }

    @MainActor
    @Test func visibleMessagesSortByReceivedDateBeforeHeaderDate() {
        let account = MailAccount.demo()
        let inbox = Mailbox(id: UUID(), accountId: account.id, name: "INBOX", role: .inbox, uidValidity: 1, unreadCount: 0)
        let headerNewButReceivedOld = MailMessage(
            id: UUID(),
            accountId: account.id,
            mailboxId: inbox.id,
            uid: 1,
            messageId: "<old-received@example.com>",
            subject: "Header date is newer",
            fromAddress: "a@example.com",
            fromName: "A",
            toRecipientsJSON: "[]",
            ccRecipientsJSON: "[]",
            bccRecipientsJSON: "[]",
            date: Date(timeIntervalSince1970: 2_000),
            receivedDate: Date(timeIntervalSince1970: 1_000),
            snippet: "",
            bodyPlain: nil,
            bodyHTML: nil,
            flags: [],
            hasAttachments: false,
            isBodyDownloaded: false,
            embeddingState: .pending
        )
        let headerOldButReceivedNew = MailMessage(
            id: UUID(),
            accountId: account.id,
            mailboxId: inbox.id,
            uid: 2,
            messageId: "<new-received@example.com>",
            subject: "Received date is newer",
            fromAddress: "b@example.com",
            fromName: "B",
            toRecipientsJSON: "[]",
            ccRecipientsJSON: "[]",
            bccRecipientsJSON: "[]",
            date: Date(timeIntervalSince1970: 1_000),
            receivedDate: Date(timeIntervalSince1970: 2_000),
            snippet: "",
            bodyPlain: nil,
            bodyHTML: nil,
            flags: [],
            hasAttachments: false,
            isBodyDownloaded: false,
            embeddingState: .pending
        )
        let store = MemoryMailStore(snapshot: MailStoreSnapshot(
            accounts: [account],
            mailboxes: [inbox],
            messages: [headerNewButReceivedOld, headerOldButReceivedNew],
            attachments: []
        ))
        let viewModel = MailAppViewModel(
            secretStore: MemorySecretStore(),
            mailStore: store,
            mailService: StubMailService(body: MessageBody(plain: "", html: nil, attachments: [])),
            aiService: StubAIService(chunks: []),
            vectorStore: InMemoryVectorStore(),
            embeddingService: LocalNLEmbeddingService(),
            autoBootstrapEmbeddings: false
        )

        #expect(viewModel.visibleMessages.map(\.id) == [headerOldButReceivedNew.id, headerNewButReceivedOld.id])

        viewModel.messageSortAscending = true
        #expect(viewModel.visibleMessages.map(\.id) == [headerNewButReceivedOld.id, headerOldButReceivedNew.id])
    }

    @MainActor
    @Test func imapRefreshLoadsSeenOlderMessagesUntilExhausted() async throws {
        let account = MailAccount.demo()
        let inbox = Mailbox(id: UUID(), accountId: account.id, name: "INBOX", role: .inbox, uidValidity: 1, unreadCount: 0)
        let store = MemoryMailStore(snapshot: MailStoreSnapshot(accounts: [account], mailboxes: [inbox], messages: [], attachments: []))
        let mailService = StubMailService(body: MessageBody(plain: "", html: nil, attachments: []))
        mailService.headersToReturn = [
            MessageHeader(uid: 101, messageId: "<101@example.com>", subject: "最新未读", fromAddress: "new@example.com", fromName: "New", date: Date(timeIntervalSince1970: 101), flags: [])
        ]
        mailService.olderHeadersToReturn = [
            MessageHeader(uid: 99, messageId: "<99@example.com>", subject: "其他客户端已读", fromAddress: "seen@example.com", fromName: "Seen", date: Date(timeIntervalSince1970: 99), flags: [.seen])
        ]
        let viewModel = MailAppViewModel(
            secretStore: MemorySecretStore(),
            mailStore: store,
            mailService: mailService,
            aiService: StubAIService(chunks: []),
            vectorStore: InMemoryVectorStore(),
            embeddingService: LocalNLEmbeddingService(),
            autoBootstrapEmbeddings: false
        )
        viewModel.selectedAccountID = account.id
        viewModel.selectedMailboxID = inbox.id

        viewModel.refresh()
        for _ in 0..<50 where viewModel.messages.count < 2 {
            try await Task.sleep(nanoseconds: 10_000_000)
        }

        #expect(viewModel.messages.map(\.uid).sorted() == [99, 101])
        #expect(viewModel.messages.first { $0.uid == 99 }?.flags.contains(.seen) == true)
        #expect(viewModel.mailboxes.first { $0.id == inbox.id }?.unreadCount == 1)
        #expect(mailService.fetchedOlderHeaderRequests.first?.beforeUID == 101)
        #expect(mailService.fetchedOlderHeaderRequests.count >= 2)
    }

    @MainActor
    @Test func imapRefreshAlsoSynchronizesJunkMailbox() async throws {
        let account = MailAccount.demo()
        let inbox = Mailbox(id: UUID(), accountId: account.id, name: "INBOX", role: .inbox, uidValidity: 1, unreadCount: 0)
        let junk = Mailbox(id: UUID(), accountId: account.id, name: "Junk Mail", role: .junk, uidValidity: 1, unreadCount: 0)
        let store = MemoryMailStore(snapshot: MailStoreSnapshot(accounts: [account], mailboxes: [inbox, junk], messages: [], attachments: []))
        let mailService = StubMailService(body: MessageBody(plain: "", html: nil, attachments: []))
        mailService.mailboxesToReturn = [inbox, junk]
        mailService.headersByMailboxID = [
            inbox.id: [
                MessageHeader(uid: 11, messageId: "<inbox@example.com>", subject: "Inbox", fromAddress: "inbox@example.com", fromName: "Inbox", date: Date(timeIntervalSince1970: 11), receivedDate: Date(timeIntervalSince1970: 11), flags: [])
            ],
            junk.id: [
                MessageHeader(uid: 21, messageId: "<junk@example.com>", subject: "Junk", fromAddress: "junk@example.com", fromName: "Junk", date: Date(timeIntervalSince1970: 21), receivedDate: Date(timeIntervalSince1970: 21), flags: [])
            ]
        ]
        let viewModel = MailAppViewModel(
            secretStore: MemorySecretStore(),
            mailStore: store,
            mailService: mailService,
            aiService: StubAIService(chunks: []),
            vectorStore: InMemoryVectorStore(),
            embeddingService: LocalNLEmbeddingService(),
            autoBootstrapEmbeddings: false
        )
        viewModel.selectedAccountID = account.id
        viewModel.selectedMailboxID = inbox.id

        viewModel.refresh()
        for _ in 0..<50 where viewModel.messages.count < 2 {
            try await Task.sleep(nanoseconds: 10_000_000)
        }

        #expect(viewModel.messages.contains { $0.mailboxId == inbox.id && $0.uid == 11 })
        #expect(viewModel.messages.contains { $0.mailboxId == junk.id && $0.uid == 21 })
        #expect(mailService.fetchedHeaderMailboxIDs.contains(inbox.id))
        #expect(mailService.fetchedHeaderMailboxIDs.contains(junk.id))
    }

    @MainActor
    @Test func imapMergeDoesNotDeduplicateMessageIDAcrossMailboxes() async throws {
        let account = MailAccount.demo()
        let inbox = Mailbox(id: UUID(), accountId: account.id, name: "INBOX", role: .inbox, uidValidity: 1, unreadCount: 0)
        let archive = Mailbox(id: UUID(), accountId: account.id, name: "Archive", role: .archive, uidValidity: 1, unreadCount: 0)
        let sharedMessageID = "<shared@example.com>"
        let existingInboxMessage = MailMessage(
            id: UUID(),
            accountId: account.id,
            mailboxId: inbox.id,
            uid: 5,
            messageId: sharedMessageID,
            subject: "Inbox copy",
            fromAddress: "sender@example.com",
            fromName: "Sender",
            toRecipientsJSON: "[]",
            ccRecipientsJSON: "[]",
            bccRecipientsJSON: "[]",
            date: Date(timeIntervalSince1970: 5),
            snippet: "",
            bodyPlain: nil,
            bodyHTML: nil,
            flags: [],
            hasAttachments: false,
            isBodyDownloaded: false,
            embeddingState: .pending
        )
        let store = MemoryMailStore(snapshot: MailStoreSnapshot(accounts: [account], mailboxes: [inbox, archive], messages: [existingInboxMessage], attachments: []))
        let mailService = StubMailService(body: MessageBody(plain: "", html: nil, attachments: []))
        mailService.headersToReturn = [
            MessageHeader(uid: 12, messageId: sharedMessageID, subject: "Archive copy", fromAddress: "sender@example.com", fromName: "Sender", date: Date(timeIntervalSince1970: 12), flags: [.seen])
        ]
        let viewModel = MailAppViewModel(
            secretStore: MemorySecretStore(),
            mailStore: store,
            mailService: mailService,
            aiService: StubAIService(chunks: []),
            vectorStore: InMemoryVectorStore(),
            embeddingService: LocalNLEmbeddingService(),
            autoBootstrapEmbeddings: false
        )
        viewModel.selectedAccountID = account.id
        viewModel.selectedMailboxID = archive.id

        viewModel.refresh()
        for _ in 0..<50 where viewModel.messages.filter({ $0.messageId == sharedMessageID }).count < 2 {
            try await Task.sleep(nanoseconds: 10_000_000)
        }

        #expect(viewModel.messages.filter { $0.messageId == sharedMessageID }.count == 2)
        #expect(viewModel.messages.contains { $0.mailboxId == inbox.id && $0.uid == 5 })
        #expect(viewModel.messages.contains { $0.mailboxId == archive.id && $0.uid == 12 })
    }

    @Test func apiKeyMaskOnlyShowsLastFourCharacters() {
        #expect(SecretMaskFormatter.maskAPIKey(nil) == "未保存")
        #expect(SecretMaskFormatter.maskAPIKey("sk-test-12345678") == "sk-••••5678")
    }

    @MainActor
    @Test func apiKeyVisibilityIsExplicitAndEmptySaveDoesNotOverwriteSecret() throws {
        let store = MemorySecretStore()
        let viewModel = MailAppViewModel(
            secretStore: store,
            mailService: StubMailService(body: MessageBody(plain: "", html: nil, attachments: [])),
            aiService: StubAIService(chunks: []),
            vectorStore: InMemoryVectorStore(),
            embeddingService: LocalNLEmbeddingService(),
            autoBootstrapEmbeddings: false
        )

        viewModel.saveAPIKey("  sk-visible-12345678  ")
        #expect(viewModel.apiKeyMask == "sk-••••5678")
        #expect(viewModel.isAPIKeyVisible == false)
        #expect(try store.read(account: "zenmux.apikey") == "sk-visible-12345678")

        viewModel.toggleAPIKeyVisibility()
        #expect(viewModel.isAPIKeyVisible == true)
        #expect(viewModel.apiKeyMask == "sk-visible-12345678")

        viewModel.toggleAPIKeyVisibility()
        #expect(viewModel.isAPIKeyVisible == false)
        #expect(viewModel.apiKeyMask == "sk-••••5678")

        viewModel.saveAPIKey("   ")
        #expect(viewModel.statusMessage == "请输入 ZenMux API-Key。")
        #expect(try store.read(account: "zenmux.apikey") == "sk-visible-12345678")
    }

    @MainActor
    @Test func chatModelManagementDeduplicatesAndKeepsASelectedModel() {
        let viewModel = MailAppViewModel(
            secretStore: MemorySecretStore(),
            mailService: StubMailService(body: MessageBody(plain: "", html: nil, attachments: [])),
            aiService: StubAIService(chunks: []),
            vectorStore: InMemoryVectorStore(),
            embeddingService: LocalNLEmbeddingService(),
            autoBootstrapEmbeddings: false
        )

        viewModel.addChatModel("  openai/gpt-5.4  ")
        #expect(viewModel.settings.chatModels.filter { $0 == "openai/gpt-5.4" }.count == 1)
        #expect(viewModel.settings.selectedChatModel == "openai/gpt-5.4")

        viewModel.addChatModel("custom/model")
        #expect(viewModel.settings.chatModels.last == "custom/model")
        #expect(viewModel.settings.selectedChatModel == "custom/model")

        viewModel.removeSelectedChatModel()
        #expect(!viewModel.settings.chatModels.contains("custom/model"))
        #expect(!viewModel.settings.selectedChatModel.isEmpty)
        #expect(viewModel.settings.chatModels.contains(viewModel.settings.selectedChatModel))
    }


    @MainActor
    @Test func enablingRemoteVectorizationRequiresPrivacyConsent() async throws {
        let settingsStore = MemorySettingsStore()
        let viewModel = MailAppViewModel(
            secretStore: MemorySecretStore(),
            settingsStore: settingsStore,
            mailService: StubMailService(body: MessageBody(plain: "", html: nil, attachments: [])),
            aiService: StubAIService(chunks: []),
            vectorStore: InMemoryVectorStore(),
            embeddingService: LocalNLEmbeddingService(),
            autoBootstrapEmbeddings: false
        )

        #expect(!viewModel.settings.vectorizationEnabled)
        viewModel.setVectorizationEnabled(true)

        #expect(!viewModel.settings.vectorizationEnabled)
        #expect(!viewModel.settings.vectorizationConsentAccepted)
        #expect(viewModel.showsVectorizationPrivacyPrompt)

        viewModel.acceptRemoteVectorization()

        #expect(viewModel.settings.vectorizationEnabled)
        #expect(viewModel.settings.vectorizationConsentAccepted)
        #expect(!viewModel.settings.useLocalEmbedding)
        #expect(!viewModel.showsVectorizationPrivacyPrompt)
        #expect(settingsStore.savedSettings.last?.vectorizationConsentAccepted == true)
    }

    @MainActor
    @Test func vectorizationPrivacyPromptCanSwitchToLocalEmbedding() async throws {
        let viewModel = MailAppViewModel(
            secretStore: MemorySecretStore(),
            settingsStore: MemorySettingsStore(),
            mailService: StubMailService(body: MessageBody(plain: "", html: nil, attachments: [])),
            aiService: StubAIService(chunks: []),
            vectorStore: InMemoryVectorStore(),
            embeddingService: LocalNLEmbeddingService(),
            autoBootstrapEmbeddings: false
        )

        viewModel.setVectorizationEnabled(true)
        #expect(viewModel.showsVectorizationPrivacyPrompt)

        viewModel.useLocalVectorization()

        #expect(viewModel.settings.vectorizationEnabled)
        #expect(viewModel.settings.useLocalEmbedding)
        #expect(!viewModel.settings.vectorizationConsentAccepted)
        #expect(!viewModel.showsVectorizationPrivacyPrompt)

        viewModel.setUseLocalEmbedding(false)

        #expect(!viewModel.settings.vectorizationEnabled)
        #expect(!viewModel.settings.useLocalEmbedding)
        #expect(viewModel.showsVectorizationPrivacyPrompt)
    }

    @MainActor
    @Test func rebuildVectorizationCanStartWhenToggleIsOff() async throws {
        let account = MailAccount.demo()
        let inbox = Mailbox(id: UUID(), accountId: account.id, name: "INBOX", role: .inbox, uidValidity: 1, unreadCount: 0)
        var message = MailMessage.demoMessages(accountId: account.id, inboxId: inbox.id)[0]
        message.embeddingState = .done
        var settings = AppSettings()
        settings.vectorizationEnabled = false
        settings.useLocalEmbedding = true
        let viewModel = MailAppViewModel(
            secretStore: MemorySecretStore(),
            mailStore: MemoryMailStore(snapshot: MailStoreSnapshot(accounts: [account], mailboxes: [inbox], messages: [message], attachments: [])),
            settingsStore: MemorySettingsStore(settings: settings),
            mailService: StubMailService(body: MessageBody(plain: "", html: nil, attachments: [])),
            aiService: StubAIService(chunks: []),
            vectorStore: InMemoryVectorStore(),
            embeddingService: StubEmbeddingService(result: .success([[0.1, 0.2, 0.3]])),
            autoBootstrapEmbeddings: false
        )

        viewModel.startOrRebuildVectorization()
        for _ in 0..<50 where viewModel.vectorizationProgress?.isActive == true {
            try await Task.sleep(nanoseconds: 10_000_000)
        }

        #expect(viewModel.settings.vectorizationEnabled)
        #expect(viewModel.messages.first?.embeddingState == .done)
        #expect(viewModel.vectorizationProgress?.isActive == false)
        #expect(viewModel.vectorizationProgress?.total == 1)
    }

    @MainActor
    @Test func rebuildVectorizationPromptsWhenNoVectorizationModeIsChosen() async throws {
        let viewModel = MailAppViewModel(
            secretStore: MemorySecretStore(),
            settingsStore: MemorySettingsStore(),
            mailService: StubMailService(body: MessageBody(plain: "", html: nil, attachments: [])),
            aiService: StubAIService(chunks: []),
            vectorStore: InMemoryVectorStore(),
            embeddingService: LocalNLEmbeddingService(),
            autoBootstrapEmbeddings: false
        )

        viewModel.startOrRebuildVectorization()

        #expect(!viewModel.settings.vectorizationEnabled)
        #expect(viewModel.showsVectorizationPrivacyPrompt)
        #expect(viewModel.statusMessage == "请选择本地向量化或确认远程向量化后开始初始化。")
    }

    @Test func uidPlannerProducesContiguousRangesAboveLocalMax() {
        let ranges = UIDSyncPlanner.newUIDRanges(remoteUIDs: [8, 9, 11, 14, 12, 4], localMaxUID: 7)
        #expect(ranges.map { "\($0.lowerBound)-\($0.upperBound)" } == ["8-9", "11-12", "14-14"])
    }

    @Test func uidPlannerDropsExistingMessageIDs() {
        let headers = [
            MessageHeader(uid: 1, messageId: "<a>", subject: "A", fromAddress: "a@example.com", fromName: "A", date: Date(), flags: []),
            MessageHeader(uid: 2, messageId: "<b>", subject: "B", fromAddress: "b@example.com", fromName: "B", date: Date(), flags: [])
        ]
        let insertable = UIDSyncPlanner.headersToInsert(headers, existingMessageIDs: ["<a>"])
        #expect(insertable.map(\.messageId) == ["<b>"])
    }

    @MainActor
    @Test func addedAccountUsesAppPasswordAndStoresSecret() throws {
        let store = MemorySecretStore()
        let viewModel = MailAppViewModel(secretStore: store, vectorStore: InMemoryVectorStore(), embeddingService: LocalNLEmbeddingService())
        let imap = ServerEndpoint(host: "mail.example.edu.cn", port: 993, tlsMode: "SSL")
        let smtp = ServerEndpoint(host: "smtp.example.edu.cn", port: 465, tlsMode: "SSL")
        viewModel.addAccount(provider: .generic, email: "zpxu@example.edu.cn", password: "app-password", customIMAP: imap, customSMTP: smtp)

        let account = try #require(viewModel.accounts.first { $0.emailAddress == "zpxu@example.edu.cn" })
        #expect(account.authType == .appPassword)
        #expect(account.provider == .generic)
        #expect(account.imap.host == "mail.example.edu.cn")
        #expect(account.smtp.host == "smtp.example.edu.cn")
        #expect(try store.read(account: "account.\(account.id.uuidString).password") == "app-password")
    }

    @MainActor
    @Test func oauthAccountStoresTokenRefInKeychain() throws {
        let store = MemorySecretStore()
        let viewModel = MailAppViewModel(
            secretStore: store,
            mailStore: MemoryMailStore(snapshot: MailStoreSnapshot(accounts: [], mailboxes: [], messages: [], attachments: [])),
            settingsStore: MemorySettingsStore(),
            mailService: StubMailService(body: MessageBody(plain: "", html: nil, attachments: [])),
            aiService: StubAIService(chunks: []),
            vectorStore: InMemoryVectorStore(),
            embeddingService: LocalNLEmbeddingService(),
            autoBootstrapEmbeddings: false
        )

        viewModel.addOAuthAccount(provider: .gmail, email: " me@gmail.com ", oauthToken: " ya29.oauth-token ")

        let account = try #require(viewModel.accounts.first { $0.emailAddress == "me@gmail.com" })
        #expect(account.authType == .oauth2)
        #expect(account.oauthRefreshTokenRef == "account.\(account.id.uuidString).oauth")
        let stored = try #require(try store.read(account: account.oauthRefreshTokenRef ?? ""))
        #expect(try OAuthTokenSet.decodeStoredSecret(stored).validAccessToken() == "ya29.oauth-token")
        #expect(viewModel.mailboxes.contains { $0.accountId == account.id && $0.role == .inbox })

        viewModel.addOAuthAccount(provider: .generic, email: "zpxu@example.edu.cn", oauthToken: "token")
        #expect(viewModel.accounts.filter { $0.provider == .generic && $0.authType == .oauth2 }.isEmpty)
        #expect(viewModel.statusMessage == "通用邮箱 暂未提供 OAuth2 登录路径。")
    }

    @Test func oauthAuthorizationURLIncludesProviderScopesAndPKCE() throws {
        let service = OAuth2Service()
        let gmailURL = try service.makeAuthorizationURL(
            provider: .gmail,
            clientID: "gmail-client",
            redirectURI: "mymail://oauth/google",
            state: "state-123",
            codeChallenge: "challenge-abc"
        )
        let gmailComponents = try #require(URLComponents(url: gmailURL, resolvingAgainstBaseURL: false))
        let gmailItems = Dictionary(uniqueKeysWithValues: (gmailComponents.queryItems ?? []).compactMap { item in
            item.value.map { (item.name, $0) }
        })

        #expect(gmailURL.absoluteString.hasPrefix("https://accounts.google.com/o/oauth2/v2/auth"))
        #expect(gmailItems["client_id"] == "gmail-client")
        #expect(gmailItems["redirect_uri"] == "mymail://oauth/google")
        #expect(gmailItems["scope"] == "https://mail.google.com/")
        #expect(gmailItems["access_type"] == "offline")
        #expect(gmailItems["prompt"] == "consent")
        #expect(gmailItems["code_challenge"] == "challenge-abc")
        #expect(gmailItems["code_challenge_method"] == "S256")

        let outlookURL = try service.makeAuthorizationURL(
            provider: .outlook,
            clientID: "outlook-client",
            redirectURI: "mymail://oauth/outlook",
            state: "state-456"
        )
        let outlookComponents = try #require(URLComponents(url: outlookURL, resolvingAgainstBaseURL: false))
        let outlookScope = outlookComponents.queryItems?.first { $0.name == "scope" }?.value ?? ""
        #expect(outlookURL.absoluteString.hasPrefix("https://login.microsoftonline.com/common/oauth2/v2.0/authorize"))
        #expect(outlookScope.contains("IMAP.AccessAsUser.All"))
        #expect(outlookScope.contains("SMTP.Send"))
        #expect(outlookScope.contains("offline_access"))
    }

    @Test func oauthServiceExchangesAuthorizationCodeForTokenSet() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [OAuthMockURLProtocol.self]
        let session = URLSession(configuration: configuration)
        let stubID = OAuthMockURLProtocol.registerStub(matching: { _, body in
            return body.contains("code=auth-code")
        }) { request, body in
            #expect(request.url?.absoluteString == "https://oauth2.googleapis.com/token")
            #expect(request.httpMethod == "POST")
            #expect(body.contains("client_id=client-123"))
            #expect(body.contains("code=auth-code"))
            #expect(body.contains("code_verifier=verifier-xyz"))
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            let data = """
            {"access_token":"access-123","refresh_token":"refresh-456","token_type":"Bearer","expires_in":3600,"scope":"https://mail.google.com/"}
            """.data(using: .utf8)!
            return (response, data)
        }
        defer { OAuthMockURLProtocol.unregisterStub(stubID) }
        let now = Date(timeIntervalSince1970: 10_000)
        let service = OAuth2Service(session: session, now: { now })

        let tokenSet = try await service.exchangeCode(
            provider: .gmail,
            clientID: "client-123",
            code: "auth-code",
            redirectURI: "mymail://oauth/google",
            codeVerifier: "verifier-xyz"
        )

        #expect(tokenSet.accessToken == "access-123")
        #expect(tokenSet.refreshToken == "refresh-456")
        #expect(tokenSet.expiresAt == now.addingTimeInterval(3600))
        #expect(try OAuthTokenSet.decodeStoredSecret(tokenSet.storageString).validAccessToken(now: now) == "access-123")
    }

    @Test func oauthServiceRefreshesAccessTokenAndKeepsExistingRefreshToken() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [OAuthMockURLProtocol.self]
        let session = URLSession(configuration: configuration)
        let stubID = OAuthMockURLProtocol.registerStub(matching: { _, body in
            return body.contains("refresh_token=refresh-existing")
        }) { request, body in
            #expect(request.url?.absoluteString == "https://login.microsoftonline.com/common/oauth2/v2.0/token")
            #expect(body.contains("grant_type=refresh_token"))
            #expect(body.contains("refresh_token=refresh-existing"))
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            let data = """
            {"access_token":"access-new","token_type":"Bearer","expires_in":1800}
            """.data(using: .utf8)!
            return (response, data)
        }
        defer { OAuthMockURLProtocol.unregisterStub(stubID) }
        let now = Date(timeIntervalSince1970: 20_000)
        let service = OAuth2Service(session: session, now: { now })

        let tokenSet = try await service.refreshAccessToken(
            provider: .outlook,
            clientID: "client-456",
            refreshToken: "refresh-existing"
        )

        #expect(tokenSet.accessToken == "access-new")
        #expect(tokenSet.refreshToken == "refresh-existing")
        #expect(tokenSet.expiresAt == now.addingTimeInterval(1800))
    }

    @Test func credentialResolverRefreshesExpiredOAuthTokenAndPersistsIt() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [OAuthMockURLProtocol.self]
        let session = URLSession(configuration: configuration)
        let stubID = OAuthMockURLProtocol.registerStub(matching: { _, body in
            body.contains("refresh_token=refresh-resolver")
        }) { request, body in
            #expect(request.url?.absoluteString == "https://oauth2.googleapis.com/token")
            #expect(body.contains("client_id=client-refresh"))
            #expect(body.contains("grant_type=refresh_token"))
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            let data = """
            {"access_token":"access-refreshed","token_type":"Bearer","expires_in":1200}
            """.data(using: .utf8)!
            return (response, data)
        }
        defer { OAuthMockURLProtocol.unregisterStub(stubID) }
        let now = Date(timeIntervalSince1970: 40_000)
        let secretStore = MemorySecretStore()
        let accountID = UUID()
        let tokenRef = "account.\(accountID.uuidString).oauth"
        let expired = OAuthTokenSet(
            accessToken: "access-old",
            refreshToken: "refresh-resolver",
            tokenType: "Bearer",
            scope: nil,
            expiresAt: now.addingTimeInterval(-10)
        )
        try secretStore.save(expired.storageString, account: tokenRef)
        let preset = ProviderPreset.preset(for: .gmail)
        let account = MailAccount(
            id: accountID,
            displayName: "Gmail OAuth",
            emailAddress: "me@gmail.com",
            provider: .gmail,
            authType: .oauth2,
            imap: preset.imap,
            smtp: preset.smtp,
            pop3: preset.pop3,
            useProtocol: .imap,
            oauthRefreshTokenRef: tokenRef,
            createdAt: now,
            needsReauth: false
        )
        let resolver = MailCredentialResolver(
            secretStore: secretStore,
            oauth2Service: OAuth2Service(session: session, now: { now }),
            oauthClientIDProvider: { provider in provider == .gmail ? "client-refresh" : "" }
        )

        let secret = try await resolver.authSecret(for: account)

        #expect(secret == "access-refreshed")
        let stored = try #require(try secretStore.read(account: tokenRef))
        let refreshed = try OAuthTokenSet.decodeStoredSecret(stored)
        #expect(refreshed.accessToken == "access-refreshed")
        #expect(refreshed.refreshToken == "refresh-resolver")
        #expect(refreshed.expiresAt == now.addingTimeInterval(1200))
    }

    @MainActor
    @Test func oauthCallbackExchangesCodeAndSavesAccount() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [OAuthMockURLProtocol.self]
        let session = URLSession(configuration: configuration)
        let stubID = OAuthMockURLProtocol.registerStub(matching: { _, body in
            return body.contains("code=callback-code")
        }) { request, body in
            #expect(body.contains("code=callback-code"))
            #expect(body.contains("code_verifier="))
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            let data = """
            {"access_token":"callback-access","refresh_token":"callback-refresh","token_type":"Bearer","expires_in":3600}
            """.data(using: .utf8)!
            return (response, data)
        }
        defer { OAuthMockURLProtocol.unregisterStub(stubID) }
        let secretStore = MemorySecretStore()
        let mailStore = MemoryMailStore(snapshot: MailStoreSnapshot(accounts: [], mailboxes: [], messages: [], attachments: []))
        let viewModel = MailAppViewModel(
            secretStore: secretStore,
            mailStore: mailStore,
            settingsStore: MemorySettingsStore(),
            mailService: StubMailService(body: MessageBody(plain: "", html: nil, attachments: [])),
            aiService: StubAIService(chunks: []),
            vectorStore: InMemoryVectorStore(),
            embeddingService: LocalNLEmbeddingService(),
            oauth2Service: OAuth2Service(session: session, now: { Date(timeIntervalSince1970: 30_000) }),
            autoBootstrapEmbeddings: false
        )

        let authURL = try #require(viewModel.startOAuthLogin(
            provider: .gmail,
            email: "oauth@example.com",
            clientID: "client-id",
            useProtocol: .imap
        ))
        let state = try #require(URLComponents(url: authURL, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "state" }?.value)

        await viewModel.handleOAuthCallback(URL(string: "mymail://oauth/gmail?code=callback-code&state=\(state)")!)

        let account = try #require(viewModel.accounts.first { $0.emailAddress == "oauth@example.com" })
        #expect(account.authType == .oauth2)
        let stored = try #require(try secretStore.read(account: account.oauthRefreshTokenRef ?? ""))
        let tokenSet = try OAuthTokenSet.decodeStoredSecret(stored)
        #expect(tokenSet.accessToken == "callback-access")
        #expect(tokenSet.refreshToken == "callback-refresh")
        #expect(mailStore.savedSnapshots.last?.accounts.contains { $0.emailAddress == "oauth@example.com" } == true)
        #expect(viewModel.statusMessage == "OAuth2 登录完成，凭据仅写入 Keychain。")
    }

    @MainActor
    @Test func oauthCallbackRejectsMismatchedState() async throws {
        let viewModel = MailAppViewModel(
            secretStore: MemorySecretStore(),
            mailStore: MemoryMailStore(snapshot: MailStoreSnapshot(accounts: [], mailboxes: [], messages: [], attachments: [])),
            settingsStore: MemorySettingsStore(),
            mailService: StubMailService(body: MessageBody(plain: "", html: nil, attachments: [])),
            aiService: StubAIService(chunks: []),
            vectorStore: InMemoryVectorStore(),
            embeddingService: LocalNLEmbeddingService(),
            autoBootstrapEmbeddings: false
        )
        _ = try #require(viewModel.startOAuthLogin(
            provider: .outlook,
            email: "oauth@example.com",
            clientID: "client-id",
            useProtocol: .imap
        ))

        await viewModel.handleOAuthCallback(URL(string: "mymail://oauth/outlook?code=callback-code&state=wrong")!)

        #expect(viewModel.accounts.allSatisfy { $0.authType != .oauth2 })
        #expect(viewModel.statusMessage == "OAuth state 校验失败，请重新登录。")
    }


    @MainActor
    @Test func gmailConnectionTestAllowsSavingWhenOnlySMTPFails() async throws {
        let mailService = StubMailService(body: MessageBody(plain: "", html: nil, attachments: []))
        mailService.outgoingTestFailureMessage = "smtp TLS failure"
        let viewModel = MailAppViewModel(
            secretStore: MemorySecretStore(),
            mailStore: MemoryMailStore(snapshot: MailStoreSnapshot(accounts: [], mailboxes: [], messages: [], attachments: [])),
            settingsStore: MemorySettingsStore(),
            mailService: mailService,
            aiService: StubAIService(chunks: []),
            vectorStore: InMemoryVectorStore(),
            embeddingService: LocalNLEmbeddingService(),
            autoBootstrapEmbeddings: false
        )

        let didPassConnectionTest = await viewModel.testAccountConnection(
            provider: .gmail,
            email: "dr.bennix@gmail.com",
            password: "abcd efgh ijkl mnop",
            useProtocol: .imap
        )

        #expect(didPassConnectionTest)
        #expect(mailService.testedAccount?.provider == .gmail)
        #expect(mailService.testedAccount?.useProtocol == .imap)
        #expect(mailService.testedPassword == "abcdefghijklmnop")
        #expect(viewModel.statusMessage.contains("收信测试通过"))
        #expect(viewModel.statusMessage.contains("SMTP 发信测试失败"))
    }

    @MainActor
    @Test func customAccountUsesProvidedServerEndpoints() async throws {
        let store = MemorySecretStore()
        let mailService = StubMailService(body: MessageBody(plain: "", html: nil, attachments: []))
        let viewModel = MailAppViewModel(
            secretStore: store,
            mailStore: MemoryMailStore(snapshot: MailStoreSnapshot(accounts: [], mailboxes: [], messages: [], attachments: [])),
            settingsStore: MemorySettingsStore(),
            mailService: mailService,
            aiService: StubAIService(chunks: []),
            vectorStore: InMemoryVectorStore(),
            embeddingService: LocalNLEmbeddingService(),
            autoBootstrapEmbeddings: false
        )
        let imap = ServerEndpoint(host: " imap.custom.example ", port: 993, tlsMode: "SSL")
        let smtp = ServerEndpoint(host: " smtp.custom.example ", port: 587, tlsMode: "STARTTLS")
        let pop3 = ServerEndpoint(host: " pop.custom.example ", port: 995, tlsMode: "SSL")

        let didPassConnectionTest = await viewModel.testAccountConnection(
            provider: .custom,
            email: " user@custom.example ",
            password: "custom-secret",
            useProtocol: .pop3,
            customIMAP: imap,
            customSMTP: smtp,
            customPOP3: pop3
        )

        #expect(didPassConnectionTest)
        #expect(mailService.testedAccount?.imap.host == "imap.custom.example")
        #expect(mailService.testedAccount?.smtp.host == "smtp.custom.example")
        #expect(mailService.testedAccount?.pop3?.host == "pop.custom.example")
        #expect(mailService.testedAccount?.useProtocol == .pop3)
        #expect(mailService.testedPassword == "custom-secret")

        viewModel.addAccount(
            provider: .custom,
            email: " user@custom.example ",
            password: "custom-secret",
            useProtocol: .pop3,
            customIMAP: imap,
            customSMTP: smtp,
            customPOP3: pop3
        )

        let account = try #require(viewModel.accounts.first { $0.emailAddress == "user@custom.example" })
        #expect(account.provider == .custom)
        #expect(account.imap.host == "imap.custom.example")
        #expect(account.smtp.host == "smtp.custom.example")
        #expect(account.pop3?.host == "pop.custom.example")
        #expect(account.useProtocol == .pop3)
        #expect(try store.read(account: "account.\(account.id.uuidString).password") == "custom-secret")
    }

    @MainActor
    @Test func customAccountRequiresServersBeforeSaving() {
        let viewModel = MailAppViewModel(
            secretStore: MemorySecretStore(),
            mailStore: MemoryMailStore(snapshot: MailStoreSnapshot(accounts: [], mailboxes: [], messages: [], attachments: [])),
            settingsStore: MemorySettingsStore(),
            mailService: StubMailService(body: MessageBody(plain: "", html: nil, attachments: [])),
            aiService: StubAIService(chunks: []),
            vectorStore: InMemoryVectorStore(),
            embeddingService: LocalNLEmbeddingService(),
            autoBootstrapEmbeddings: false
        )
        let smtp = ServerEndpoint(host: "smtp.custom.example", port: 587, tlsMode: "STARTTLS")
        let initialAccountCount = viewModel.accounts.count

        viewModel.addAccount(
            provider: .custom,
            email: "user@custom.example",
            password: "custom-secret",
            useProtocol: .imap,
            customIMAP: ServerEndpoint(host: "", port: 993, tlsMode: "SSL"),
            customSMTP: smtp,
            customPOP3: nil
        )

        #expect(viewModel.accounts.count == initialAccountCount)
        #expect(!viewModel.accounts.contains { $0.emailAddress == "user@custom.example" })
        #expect(viewModel.statusMessage.contains("请填写 IMAP 与 SMTP 服务器"))

        viewModel.addAccount(
            provider: .custom,
            email: "user@custom.example",
            password: "custom-secret",
            useProtocol: .pop3,
            customIMAP: ServerEndpoint(host: "imap.custom.example", port: 993, tlsMode: "SSL"),
            customSMTP: smtp,
            customPOP3: nil
        )

        #expect(viewModel.accounts.count == initialAccountCount)
        #expect(!viewModel.accounts.contains { $0.emailAddress == "user@custom.example" })
        #expect(viewModel.statusMessage.contains("选择 POP3 时请填写 POP3 服务器"))
    }

    @MainActor
    @Test func fudanGenericAccountUsesPublishedSSLPortsAndDoesNotRequirePOP3ForIMAP() async throws {
        let mailService = StubMailService(body: MessageBody(plain: "", html: nil, attachments: []))
        let viewModel = MailAppViewModel(
            secretStore: MemorySecretStore(),
            mailStore: MemoryMailStore(snapshot: MailStoreSnapshot(accounts: [], mailboxes: [], messages: [], attachments: [])),
            settingsStore: MemorySettingsStore(),
            mailService: mailService,
            aiService: StubAIService(chunks: []),
            vectorStore: InMemoryVectorStore(),
            embeddingService: LocalNLEmbeddingService(),
            autoBootstrapEmbeddings: false
        )
        let imap = ServerEndpoint(host: "mail.fudan.edu.cn", port: 993, tlsMode: "SSL")
        let wrongSMTP = ServerEndpoint(host: "mail.fudan.edu.cn", port: 587, tlsMode: "SSL")

        let rejected = await viewModel.testAccountConnection(
            provider: .generic,
            email: "zpxu@fudan.edu.cn",
            password: "custom-secret",
            useProtocol: .imap,
            customIMAP: imap,
            customSMTP: wrongSMTP,
            customPOP3: nil
        )

        #expect(!rejected)
        #expect(mailService.testedAccount == nil)
        #expect(viewModel.statusMessage.contains("复旦 SMTP 请使用 mail.fudan.edu.cn:465 SSL"))

        let accepted = await viewModel.testAccountConnection(
            provider: .generic,
            email: "zpxu@fudan.edu.cn",
            password: "custom-secret",
            useProtocol: .imap,
            customIMAP: imap,
            customSMTP: ServerEndpoint(host: "mail.fudan.edu.cn", port: 465, tlsMode: "SSL"),
            customPOP3: nil
        )

        #expect(accepted)
        #expect(mailService.testedAccount?.imap.port == 993)
        #expect(mailService.testedAccount?.smtp.port == 465)
        #expect(mailService.testedAccount?.pop3 == nil)
        #expect(mailService.testedAccount?.useProtocol == .imap)

        let popService = StubMailService(body: MessageBody(plain: "", html: nil, attachments: []))
        let popViewModel = MailAppViewModel(
            secretStore: MemorySecretStore(),
            mailStore: MemoryMailStore(snapshot: MailStoreSnapshot(accounts: [], mailboxes: [], messages: [], attachments: [])),
            settingsStore: MemorySettingsStore(),
            mailService: popService,
            aiService: StubAIService(chunks: []),
            vectorStore: InMemoryVectorStore(),
            embeddingService: LocalNLEmbeddingService(),
            autoBootstrapEmbeddings: false
        )
        let acceptedPOP3 = await popViewModel.testAccountConnection(
            provider: .generic,
            email: "zpxu@fudan.edu.cn",
            password: "custom-secret",
            useProtocol: .pop3,
            customIMAP: nil,
            customSMTP: ServerEndpoint(host: "mail.fudan.edu.cn", port: 465, tlsMode: "SSL"),
            customPOP3: ServerEndpoint(host: "mail.fudan.edu.cn", port: 995, tlsMode: "SSL")
        )

        #expect(acceptedPOP3)
        #expect(popService.testedAccount?.imap.host.isEmpty == true)
        #expect(popService.testedAccount?.pop3?.port == 995)
        #expect(popService.testedAccount?.useProtocol == .pop3)
    }

    @MainActor
    @Test func settingsPersistAcrossViewModelsWithoutSecrets() throws {
        let settingsStore = MemorySettingsStore()
        let first = MailAppViewModel(
            secretStore: MemorySecretStore(),
            settingsStore: settingsStore,
            mailService: StubMailService(body: MessageBody(plain: "", html: nil, attachments: [])),
            aiService: StubAIService(chunks: []),
            vectorStore: InMemoryVectorStore(),
            embeddingService: LocalNLEmbeddingService(),
            autoBootstrapEmbeddings: false
        )
        first.settings.pop3PollingMinutes = 12
        first.settings.cacheMessageLimit = 37
        first.settings.selectedChatModel = "openai/gpt-5.4"
        first.settings.signature = "Regards, myMail"

        let second = MailAppViewModel(
            secretStore: MemorySecretStore(),
            settingsStore: settingsStore,
            mailService: StubMailService(body: MessageBody(plain: "", html: nil, attachments: [])),
            aiService: StubAIService(chunks: []),
            vectorStore: InMemoryVectorStore(),
            embeddingService: LocalNLEmbeddingService(),
            autoBootstrapEmbeddings: false
        )

        #expect(second.settings.pop3PollingMinutes == 12)
        #expect(second.settings.cacheMessageLimit == 37)
        #expect(second.settings.selectedChatModel == "openai/gpt-5.4")
        #expect(second.settings.signature == "Regards, myMail")
        #expect(settingsStore.savedSettings.last?.signature == "Regards, myMail")
    }

    @MainActor
    @Test func deletingAccountRemovesConfigurationSecretsAndLocalCache() throws {
        var firstAccount = MailAccount.demo()
        firstAccount.oauthRefreshTokenRef = "account.\(firstAccount.id.uuidString).oauth"
        var secondAccount = MailAccount.demo()
        secondAccount.id = UUID()
        secondAccount.emailAddress = "second@example.com"
        secondAccount.displayName = "Second"
        let firstMailboxes = Mailbox.demoSet(accountId: firstAccount.id)
        let secondMailboxes = Mailbox.demoSet(accountId: secondAccount.id)
        let firstInbox = try #require(firstMailboxes.first { $0.role == .inbox })
        let secondInbox = try #require(secondMailboxes.first { $0.role == .inbox })
        let firstMessage = MailMessage.demoMessages(accountId: firstAccount.id, inboxId: firstInbox.id)[0]
        let secondMessage = MailMessage.demoMessages(accountId: secondAccount.id, inboxId: secondInbox.id)[0]
        let attachmentRoot = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let cachedAttachmentDirectory = attachmentRoot.appendingPathComponent(firstMessage.id.uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: cachedAttachmentDirectory, withIntermediateDirectories: true)
        let cachedAttachmentURL = cachedAttachmentDirectory.appendingPathComponent("cached.txt")
        try Data("cached".utf8).write(to: cachedAttachmentURL)
        defer { try? FileManager.default.removeItem(at: attachmentRoot) }
        let firstAttachment = MailAttachment(
            id: UUID(),
            messageId: firstMessage.id,
            filename: "cached.txt",
            mimeType: "text/plain",
            sizeBytes: 6,
            localPath: cachedAttachmentURL.path,
            contentId: nil,
            decodedContent: nil
        )
        let store = MemoryMailStore(snapshot: MailStoreSnapshot(
            accounts: [firstAccount, secondAccount],
            mailboxes: firstMailboxes + secondMailboxes,
            messages: [firstMessage, secondMessage],
            attachments: [firstAttachment]
        ))
        let secrets = MemorySecretStore()
        try secrets.save("password", account: "account.\(firstAccount.id.uuidString).password")
        try secrets.save("oauth-token", account: firstAccount.oauthRefreshTokenRef!)
        let viewModel = MailAppViewModel(
            secretStore: secrets,
            mailStore: store,
            settingsStore: MemorySettingsStore(),
            mailService: StubMailService(body: MessageBody(plain: "", html: nil, attachments: [])),
            aiService: StubAIService(chunks: []),
            vectorStore: InMemoryVectorStore(),
            embeddingService: LocalNLEmbeddingService(),
            attachmentCacheRoot: attachmentRoot,
            autoBootstrapEmbeddings: false
        )
        viewModel.selectedAccountID = firstAccount.id
        viewModel.selectedMailboxID = firstInbox.id
        viewModel.selectedMessageID = firstMessage.id

        viewModel.deleteAccount(accountID: firstAccount.id)

        #expect(!viewModel.accounts.contains { $0.id == firstAccount.id })
        #expect(viewModel.accounts.map(\.id) == [secondAccount.id])
        #expect(viewModel.mailboxes.allSatisfy { $0.accountId == secondAccount.id })
        #expect(viewModel.messages.map(\.accountId) == [secondAccount.id])
        #expect(viewModel.attachments.isEmpty)
        #expect(viewModel.selectedAccountID == secondAccount.id)
        #expect(viewModel.selectedMailboxID == secondInbox.id)
        #expect(try secrets.read(account: "account.\(firstAccount.id.uuidString).password") == nil)
        #expect(try secrets.read(account: firstAccount.oauthRefreshTokenRef!) == nil)
        #expect(!FileManager.default.fileExists(atPath: cachedAttachmentDirectory.path))
        #expect(store.savedSnapshots.last?.accounts.map(\.id) == [secondAccount.id])
        #expect(viewModel.statusMessage == "账户配置已删除。")
    }

    @Test func appSettingsDecodeOlderPayloadWithDefaults() throws {
        let data = """
        {
          "selectedChatModel": "openai/gpt-5.4",
          "chatModels": ["openai/gpt-5.4"],
          "cacheMessageLimit": 50
        }
        """.data(using: .utf8)!

        let settings = try JSONDecoder().decode(AppSettings.self, from: data)

        #expect(settings.selectedChatModel == "openai/gpt-5.4")
        #expect(settings.cacheMessageLimit == 50)
        #expect(settings.gmailOAuthClientID.isEmpty)
        #expect(settings.outlookOAuthClientID.isEmpty)
        #expect(settings.signature == "Sent from myMail")
        #expect(settings.interfaceLanguage == .simplifiedChinese)
    }

    @MainActor
    @Test func pop3PollingSyncsPOP3AccountAndPreservesInboxID() async throws {
        var account = MailAccount.demo()
        account.useProtocol = .pop3
        let localInbox = Mailbox(id: UUID(), accountId: account.id, name: "INBOX", role: .inbox, uidValidity: 1, unreadCount: 0)
        let remoteInbox = Mailbox(id: UUID(), accountId: account.id, name: "INBOX", role: .inbox, uidValidity: 1, unreadCount: 0)
        var settings = AppSettings()
        settings.cacheMessageLimit = 37
        let mailStore = MemoryMailStore(snapshot: MailStoreSnapshot(accounts: [account], mailboxes: [localInbox], messages: [], attachments: []))
        let settingsStore = MemorySettingsStore(settings: settings)
        let mailService = StubMailService(body: MessageBody(plain: "", html: nil, attachments: []))
        mailService.mailboxesToReturn = [remoteInbox]
        mailService.headersToReturn = [
            MessageHeader(uid: 7, messageId: "<pop3-new@example.com>", subject: "POP3 新邮件", fromAddress: "sender@example.com", fromName: "Sender", date: Date(), flags: [])
        ]
        let viewModel = MailAppViewModel(
            secretStore: MemorySecretStore(),
            mailStore: mailStore,
            settingsStore: settingsStore,
            mailService: mailService,
            aiService: StubAIService(chunks: []),
            vectorStore: InMemoryVectorStore(),
            embeddingService: LocalNLEmbeddingService(),
            autoBootstrapEmbeddings: false
        )

        await viewModel.pollPOP3Once()

        #expect(mailService.connectedAccountID == account.id)
        #expect(mailService.fetchedHeaderMailboxIDs == [localInbox.id])
        #expect(mailService.fetchedHeaderRanges.first?.lowerBound == 1)
        #expect(mailService.fetchedHeaderRanges.first?.upperBound == 37)
        #expect(viewModel.mailboxes.first?.id == localInbox.id)
        #expect(viewModel.messages.first?.messageId == "<pop3-new@example.com>")
        #expect(viewModel.messages.first?.mailboxId == localInbox.id)
        #expect(mailStore.savedSnapshots.last?.messages.first?.messageId == "<pop3-new@example.com>")
    }

    @MainActor
    @Test func pop3PollingUsesSeparateMailServicesPerAccount() async throws {
        let preset = ProviderPreset.preset(for: .gmail)
        var firstAccount = MailAccount.demo()
        firstAccount.id = UUID()
        firstAccount.emailAddress = "first@example.com"
        firstAccount.useProtocol = .pop3
        firstAccount.pop3 = preset.pop3
        var secondAccount = MailAccount.demo()
        secondAccount.id = UUID()
        secondAccount.emailAddress = "second@example.com"
        secondAccount.useProtocol = .pop3
        secondAccount.pop3 = preset.pop3
        let firstInbox = Mailbox(id: UUID(), accountId: firstAccount.id, name: "INBOX", role: .inbox, uidValidity: 1, unreadCount: 0)
        let secondInbox = Mailbox(id: UUID(), accountId: secondAccount.id, name: "INBOX", role: .inbox, uidValidity: 1, unreadCount: 0)
        var createdServices: [StubMailService] = []

        let viewModel = MailAppViewModel(
            secretStore: MemorySecretStore(),
            mailStore: MemoryMailStore(snapshot: MailStoreSnapshot(accounts: [firstAccount, secondAccount], mailboxes: [], messages: [], attachments: [])),
            settingsStore: MemorySettingsStore(),
            mailServiceFactory: {
                let stub = StubMailService(body: MessageBody(plain: "", html: nil, attachments: []))
                stub.mailboxesToReturn = createdServices.isEmpty ? [firstInbox] : [secondInbox]
                createdServices.append(stub)
                return stub
            },
            aiService: StubAIService(chunks: []),
            vectorStore: InMemoryVectorStore(),
            embeddingService: LocalNLEmbeddingService(),
            autoBootstrapEmbeddings: false,
            retryDelayNanoseconds: 0
        )

        await viewModel.pollPOP3Once()
        await viewModel.pollPOP3Once()

        #expect(createdServices.count == 2)
        #expect(createdServices[0] !== createdServices[1])
        #expect(createdServices[0].connectedAccountID == firstAccount.id)
        #expect(createdServices[1].connectedAccountID == secondAccount.id)
        #expect(createdServices[0].fetchMailboxAttempts == 2)
        #expect(createdServices[1].fetchMailboxAttempts == 2)
    }

    @MainActor
    @Test func syncRetriesTransientHeaderFailures() async throws {
        var account = MailAccount.demo()
        account.useProtocol = .pop3
        let inbox = Mailbox(id: UUID(), accountId: account.id, name: "INBOX", role: .inbox, uidValidity: 1, unreadCount: 0)
        let mailStore = MemoryMailStore(snapshot: MailStoreSnapshot(accounts: [account], mailboxes: [inbox], messages: [], attachments: []))
        let mailService = StubMailService(body: MessageBody(plain: "", html: nil, attachments: []))
        mailService.mailboxesToReturn = [inbox]
        mailService.fetchHeaderFailuresRemaining = 2
        mailService.headersToReturn = [
            MessageHeader(uid: 9, messageId: "<retry-success@example.com>", subject: "重试后成功", fromAddress: "sender@example.com", fromName: "Sender", date: Date(), flags: [])
        ]
        let viewModel = MailAppViewModel(
            secretStore: MemorySecretStore(),
            mailStore: mailStore,
            settingsStore: MemorySettingsStore(),
            mailService: mailService,
            aiService: StubAIService(chunks: []),
            vectorStore: InMemoryVectorStore(),
            embeddingService: LocalNLEmbeddingService(),
            autoBootstrapEmbeddings: false,
            retryDelayNanoseconds: 0
        )

        await viewModel.pollPOP3Once()

        #expect(mailService.fetchHeaderAttempts == 3)
        #expect(viewModel.messages.first?.messageId == "<retry-success@example.com>")
        #expect(viewModel.statusMessage == "POP3 轮询完成。")
    }


    @MainActor
    @Test func authenticationFailureMarksAccountForReauthAndPasswordUpdateClearsIt() async throws {
        var account = MailAccount.demo()
        account.useProtocol = .imap
        let inbox = Mailbox(id: UUID(), accountId: account.id, name: "INBOX", role: .inbox, uidValidity: 1, unreadCount: 0)
        let mailStore = MemoryMailStore(snapshot: MailStoreSnapshot(accounts: [account], mailboxes: [inbox], messages: [], attachments: []))
        let secretStore = MemorySecretStore()
        try secretStore.save("old-password", account: "account.\(account.id.uuidString).password")
        let mailService = StubMailService(body: MessageBody(plain: "", html: nil, attachments: []))
        mailService.connectFailuresRemaining = 3
        mailService.connectFailureMessage = "authentication failed: invalid password"
        let viewModel = MailAppViewModel(
            secretStore: secretStore,
            mailStore: mailStore,
            settingsStore: MemorySettingsStore(),
            mailService: mailService,
            aiService: StubAIService(chunks: []),
            vectorStore: InMemoryVectorStore(),
            embeddingService: LocalNLEmbeddingService(),
            autoBootstrapEmbeddings: false,
            retryDelayNanoseconds: 0
        )

        viewModel.refresh()
        for _ in 0..<50 where viewModel.accounts.first?.needsReauth == false {
            try await Task.sleep(nanoseconds: 10_000_000)
        }

        #expect(viewModel.accounts.first?.needsReauth == true)
        #expect(mailStore.savedSnapshots.last?.accounts.first?.needsReauth == true)
        #expect((try? secretStore.read(account: "account.\(account.id.uuidString).password")) == "old-password")

        viewModel.updateAccountPassword(accountID: account.id, password: "   ")
        #expect(viewModel.accounts.first?.needsReauth == true)
        #expect((try? secretStore.read(account: "account.\(account.id.uuidString).password")) == "old-password")

        viewModel.updateAccountPassword(accountID: account.id, password: "new-app-password")

        #expect(viewModel.accounts.first?.needsReauth == false)
        #expect((try? secretStore.read(account: "account.\(account.id.uuidString).password")) == "new-app-password")
        #expect(mailStore.savedSnapshots.last?.accounts.first?.needsReauth == false)
    }

    @MainActor
    @Test func syncUpdatesExistingMessageFlagsWithoutDuplicatingOrDroppingBody() async throws {
        var account = MailAccount.demo()
        account.useProtocol = .pop3
        let inbox = Mailbox(id: UUID(), accountId: account.id, name: "INBOX", role: .inbox, uidValidity: 1, unreadCount: 1)
        var existing = MailMessage.demoMessages(accountId: account.id, inboxId: inbox.id)[0]
        existing.uid = 9
        existing.messageId = "<existing@example.com>"
        existing.subject = "旧主题"
        existing.bodyPlain = "已经缓存的正文"
        existing.snippet = "旧预览"
        existing.isBodyDownloaded = true
        existing.flags = []
        existing.embeddingState = .done
        var updatedFlags = MessageFlags()
        updatedFlags.insert(.seen)
        updatedFlags.insert(.flagged)

        let mailStore = MemoryMailStore(snapshot: MailStoreSnapshot(accounts: [account], mailboxes: [inbox], messages: [existing], attachments: []))
        let mailService = StubMailService(body: MessageBody(plain: "", html: nil, attachments: []))
        mailService.mailboxesToReturn = [inbox]
        mailService.headersToReturn = [
            MessageHeader(uid: 9, messageId: "<existing@example.com>", subject: "新主题", fromAddress: "sender@example.com", fromName: "Sender", date: existing.date.addingTimeInterval(60), flags: updatedFlags)
        ]
        let viewModel = MailAppViewModel(
            secretStore: MemorySecretStore(),
            mailStore: mailStore,
            settingsStore: MemorySettingsStore(),
            mailService: mailService,
            aiService: StubAIService(chunks: []),
            vectorStore: InMemoryVectorStore(),
            embeddingService: LocalNLEmbeddingService(),
            autoBootstrapEmbeddings: false,
            retryDelayNanoseconds: 0
        )
        viewModel.selectedMessageID = existing.id

        await viewModel.pollPOP3Once()

        #expect(viewModel.messages.count == 1)
        #expect(viewModel.messages.first?.id == existing.id)
        #expect(viewModel.messages.first?.subject == "新主题")
        #expect(viewModel.messages.first?.flags == updatedFlags)
        #expect(viewModel.messages.first?.bodyPlain == "已经缓存的正文")
        #expect(viewModel.messages.first?.snippet == "旧预览")
        #expect(viewModel.messages.first?.embeddingState == MessageEmbeddingState.pending)
        #expect(viewModel.mailboxes.first?.unreadCount == 0)
        #expect(viewModel.selectedMessageID == existing.id)
        #expect(mailStore.savedSnapshots.last?.messages.count == 1)
        #expect(mailStore.savedSnapshots.last?.messages.first?.flags == updatedFlags)
        #expect(mailStore.savedSnapshots.last?.mailboxes.first?.unreadCount == 0)
    }

    @MainActor
    @Test func syncEnforcesCacheMessageLimitAndRemovesAttachments() async throws {
        var account = MailAccount.demo()
        account.useProtocol = .pop3
        let inbox = Mailbox(id: UUID(), accountId: account.id, name: "INBOX", role: .inbox, uidValidity: 1, unreadCount: 3)
        let baseDate = Date(timeIntervalSince1970: 1_700_000_000)
        func message(uid: Int64, seconds: TimeInterval, flags: MessageFlags = []) -> MailMessage {
            MailMessage(
                id: UUID(),
                accountId: account.id,
                mailboxId: inbox.id,
                uid: uid,
                messageId: "<cache-\(uid)@example.com>",
                subject: "缓存邮件 \(uid)",
                fromAddress: "sender@example.com",
                fromName: "Sender",
                toRecipientsJSON: "[]",
                ccRecipientsJSON: "[]",
                bccRecipientsJSON: "[]",
                date: baseDate.addingTimeInterval(seconds),
                snippet: "缓存邮件 \(uid)",
                bodyPlain: nil,
                bodyHTML: nil,
                flags: flags,
                hasAttachments: true,
                isBodyDownloaded: false,
                embeddingState: .pending
            )
        }
        let oldest = message(uid: 1, seconds: 0)
        let middle = message(uid: 2, seconds: 60)
        let newestLocal = message(uid: 3, seconds: 120, flags: [.seen])
        let oldAttachment = MailAttachment(
            id: UUID(),
            messageId: oldest.id,
            filename: "old.pdf",
            mimeType: "application/pdf",
            sizeBytes: 128,
            localPath: "/tmp/old.pdf",
            contentId: nil
        )
        var settings = AppSettings()
        settings.cacheMessageLimit = 2
        let mailStore = MemoryMailStore(snapshot: MailStoreSnapshot(
            accounts: [account],
            mailboxes: [inbox],
            messages: [oldest, middle, newestLocal],
            attachments: [oldAttachment]
        ))
        let mailService = StubMailService(body: MessageBody(plain: "", html: nil, attachments: []))
        mailService.mailboxesToReturn = [inbox]
        mailService.headersToReturn = [
            MessageHeader(
                uid: 4,
                messageId: "<cache-4@example.com>",
                subject: "缓存邮件 4",
                fromAddress: "sender@example.com",
                fromName: "Sender",
                date: baseDate.addingTimeInterval(180),
                flags: []
            )
        ]
        let viewModel = MailAppViewModel(
            secretStore: MemorySecretStore(),
            mailStore: mailStore,
            settingsStore: MemorySettingsStore(settings: settings),
            mailService: mailService,
            aiService: StubAIService(chunks: []),
            vectorStore: InMemoryVectorStore(),
            embeddingService: LocalNLEmbeddingService(),
            autoBootstrapEmbeddings: false,
            retryDelayNanoseconds: 0
        )
        viewModel.selectedMessageID = oldest.id

        await viewModel.pollPOP3Once()

        #expect(viewModel.messages.map(\.uid).sorted() == [3, 4])
        #expect(viewModel.attachments.isEmpty)
        #expect(viewModel.selectedMessageID == viewModel.messages.sorted { $0.date > $1.date }.first?.id)
        #expect(viewModel.mailboxes.first?.unreadCount == 1)
        #expect(mailStore.savedSnapshots.last?.messages.map(\.uid).sorted() == [3, 4])
        #expect(mailStore.savedSnapshots.last?.attachments.isEmpty == true)
        #expect(mailStore.savedSnapshots.last?.mailboxes.first?.unreadCount == 1)
    }

    @MainActor
    @Test func scrollingToEndLoadsOlderIMAPMessagesWithoutCacheTrimming() async throws {
        let account = MailAccount.demo()
        let inbox = Mailbox(id: UUID(), accountId: account.id, name: "INBOX", role: .inbox, uidValidity: 1, unreadCount: 0)
        let baseDate = Date(timeIntervalSince1970: 1_700_000_000)
        func message(uid: Int64, seconds: TimeInterval) -> MailMessage {
            MailMessage(
                id: UUID(),
                accountId: account.id,
                mailboxId: inbox.id,
                uid: uid,
                messageId: "<imap-page-\(uid)@example.com>",
                subject: "分页邮件 \(uid)",
                fromAddress: "sender@example.com",
                fromName: "Sender",
                toRecipientsJSON: "[]",
                ccRecipientsJSON: "[]",
                bccRecipientsJSON: "[]",
                date: baseDate.addingTimeInterval(seconds),
                snippet: "分页邮件 \(uid)",
                bodyPlain: nil,
                bodyHTML: nil,
                flags: [],
                hasAttachments: false,
                isBodyDownloaded: false,
                embeddingState: .pending
            )
        }
        let olderVisibleMessage = message(uid: 9, seconds: 60)
        let newestVisibleMessage = message(uid: 10, seconds: 120)
        var settings = AppSettings()
        settings.cacheMessageLimit = 2
        let mailStore = MemoryMailStore(snapshot: MailStoreSnapshot(
            accounts: [account],
            mailboxes: [inbox],
            messages: [newestVisibleMessage, olderVisibleMessage],
            attachments: []
        ))
        let mailService = StubMailService(body: MessageBody(plain: "", html: nil, attachments: []))
        mailService.olderHeadersToReturn = [
            MessageHeader(uid: 7, messageId: "<imap-page-7@example.com>", subject: "分页邮件 7", fromAddress: "sender@example.com", fromName: "Sender", date: baseDate, flags: []),
            MessageHeader(uid: 8, messageId: "<imap-page-8@example.com>", subject: "分页邮件 8", fromAddress: "sender@example.com", fromName: "Sender", date: baseDate.addingTimeInterval(30), flags: [])
        ]
        let viewModel = MailAppViewModel(
            secretStore: MemorySecretStore(),
            mailStore: mailStore,
            settingsStore: MemorySettingsStore(settings: settings),
            mailService: mailService,
            aiService: StubAIService(chunks: []),
            vectorStore: InMemoryVectorStore(),
            embeddingService: LocalNLEmbeddingService(),
            autoBootstrapEmbeddings: false,
            retryDelayNanoseconds: 0
        )
        viewModel.selectedMailboxID = inbox.id

        await viewModel.loadMoreMessagesIfNeeded(currentMessage: olderVisibleMessage)

        #expect(mailService.fetchedOlderHeaderRequests.count == 1)
        #expect(mailService.fetchedOlderHeaderRequests.first?.beforeUID == 9)
        #expect(mailService.fetchedOlderHeaderRequests.first?.limit == 2)
        #expect(viewModel.messages.map(\.uid).sorted() == [7, 8, 9, 10])
        #expect(mailStore.savedSnapshots.last?.messages.map(\.uid).sorted() == [7, 8, 9, 10])
    }

    @MainActor
    @Test func sortingDoesNotImmediatelyTriggerLoadMoreIMAPMessages() async throws {
        let account = MailAccount.demo()
        let inbox = Mailbox(id: UUID(), accountId: account.id, name: "INBOX", role: .inbox, uidValidity: 1, unreadCount: 0)
        let message = MailMessage(
            id: UUID(),
            accountId: account.id,
            mailboxId: inbox.id,
            uid: 40,
            messageId: "<40@example.com>",
            subject: "Current page",
            fromAddress: "sender@example.com",
            fromName: "Sender",
            toRecipientsJSON: "[]",
            ccRecipientsJSON: "[]",
            bccRecipientsJSON: "[]",
            date: Date(timeIntervalSince1970: 40),
            receivedDate: Date(timeIntervalSince1970: 40),
            snippet: "",
            bodyPlain: nil,
            bodyHTML: nil,
            flags: [],
            hasAttachments: false,
            isBodyDownloaded: false,
            embeddingState: .pending
        )
        let store = MemoryMailStore(snapshot: MailStoreSnapshot(accounts: [account], mailboxes: [inbox], messages: [message], attachments: []))
        let mailService = StubMailService(body: MessageBody(plain: "", html: nil, attachments: []))
        mailService.olderHeadersToReturn = [
            MessageHeader(uid: 39, messageId: "<39@example.com>", subject: "Older", fromAddress: "old@example.com", fromName: "Old", date: Date(timeIntervalSince1970: 39), receivedDate: Date(timeIntervalSince1970: 39), flags: [])
        ]
        let viewModel = MailAppViewModel(
            secretStore: MemorySecretStore(),
            mailStore: store,
            mailService: mailService,
            aiService: StubAIService(chunks: []),
            vectorStore: InMemoryVectorStore(),
            embeddingService: LocalNLEmbeddingService(),
            autoBootstrapEmbeddings: false
        )
        viewModel.selectedAccountID = account.id
        viewModel.selectedMailboxID = inbox.id

        viewModel.messageSortAscending = true
        await viewModel.loadMoreMessagesIfNeeded(currentMessage: message)

        #expect(mailService.fetchedOlderHeaderRequests.isEmpty)
        #expect(viewModel.messages.map(\.uid) == [40])
    }

    @MainActor
    @Test func inboxIdleExistsEventTriggersSync() async throws {
        let account = MailAccount.demo()
        let inbox = Mailbox(id: UUID(), accountId: account.id, name: "INBOX", role: .inbox, uidValidity: 1, unreadCount: 0)
        let mailStore = MemoryMailStore(snapshot: MailStoreSnapshot(accounts: [account], mailboxes: [inbox], messages: [], attachments: []))
        let mailService = StubMailService(body: MessageBody(plain: "", html: nil, attachments: []))
        mailService.idleEvents = [.exists(1)]
        mailService.mailboxesToReturn = [inbox]
        mailService.headersToReturn = [
            MessageHeader(uid: 11, messageId: "<idle-new@example.com>", subject: "IDLE 新邮件", fromAddress: "sender@example.com", fromName: "Sender", date: Date(), flags: [])
        ]
        let viewModel = MailAppViewModel(
            secretStore: MemorySecretStore(),
            mailStore: mailStore,
            settingsStore: MemorySettingsStore(),
            mailService: mailService,
            aiService: StubAIService(chunks: []),
            vectorStore: InMemoryVectorStore(),
            embeddingService: LocalNLEmbeddingService(),
            autoBootstrapEmbeddings: false,
            retryDelayNanoseconds: 0
        )

        viewModel.startInboxIdle()
        for _ in 0..<100 where viewModel.messages.isEmpty {
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        viewModel.stopInboxIdle()

        #expect(mailService.idleMailboxID == inbox.id)
        #expect(mailService.fetchedHeaderMailboxIDs == [inbox.id])
        #expect(viewModel.messages.first?.messageId == "<idle-new@example.com>")
        #expect(viewModel.statusMessage == "IDLE 收到新邮件，已同步。")
    }

    @MainActor
    @Test func selectedMessageDownloadsBodyAndPersistsCache() async throws {
        let account = MailAccount.demo()
        let mailboxes = Mailbox.demoSet(accountId: account.id)
        var message = MailMessage.demoMessages(accountId: account.id, inboxId: mailboxes[0].id)[0]
        message.bodyPlain = nil
        message.bodyHTML = nil
        message.snippet = "header only"
        message.hasAttachments = false
        message.isBodyDownloaded = false
        message.embeddingState = .done
        let attachmentData = Data("agenda attachment bytes".utf8)
        let bodyAttachment = MailAttachment(
            id: UUID(),
            messageId: UUID(),
            filename: "agenda.pdf",
            mimeType: "application/pdf",
            sizeBytes: Int64(attachmentData.count),
            localPath: nil,
            contentId: nil,
            decodedContent: attachmentData
        )
        let body = MessageBody(plain: "完整正文来自服务器", html: "<p>完整正文来自服务器</p>", attachments: [bodyAttachment])
        let mailService = StubMailService(body: body)
        let store = MemoryMailStore(snapshot: MailStoreSnapshot(accounts: [account], mailboxes: mailboxes, messages: [message], attachments: []))
        let attachmentCacheRoot = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: attachmentCacheRoot) }
        let viewModel = MailAppViewModel(
            secretStore: MemorySecretStore(),
            mailStore: store,
            mailService: mailService,
            aiService: StubAIService(chunks: []),
            vectorStore: InMemoryVectorStore(),
            embeddingService: LocalNLEmbeddingService(),
            attachmentCacheRoot: attachmentCacheRoot
        )
        viewModel.selectedMailboxID = mailboxes[0].id
        viewModel.selectedMessageID = message.id

        await viewModel.loadSelectedMessageBodyIfNeeded()

        #expect(mailService.connectedAccountID == account.id)
        #expect(mailService.fetchedMailboxID == mailboxes[0].id)
        #expect(mailService.fetchedUID == message.uid)
        #expect(viewModel.messages.first?.bodyPlain == "完整正文来自服务器")
        #expect(viewModel.messages.first?.bodyHTML == "<p>完整正文来自服务器</p>")
        #expect(viewModel.messages.first?.isBodyDownloaded == true)
        #expect(viewModel.messages.first?.embeddingState == MessageEmbeddingState.pending)
        #expect(viewModel.attachments.first?.messageId == message.id)
        #expect(viewModel.attachments.first?.filename == "agenda.pdf")
        #expect(viewModel.attachments.first?.decodedContent == nil)
        let savedPath = try #require(viewModel.attachments.first?.localPath)
        #expect(savedPath.contains(attachmentCacheRoot.path))
        #expect(FileManager.default.contents(atPath: savedPath) == attachmentData)
        #expect(store.savedSnapshots.last?.messages.first?.isBodyDownloaded == true)
        #expect(store.savedSnapshots.last?.attachments.first?.filename == "agenda.pdf")
        #expect(store.savedSnapshots.last?.attachments.first?.localPath == savedPath)
        #expect(store.savedSnapshots.last?.attachments.first?.decodedContent == nil)
    }

    @MainActor
    @Test func openingCachedMessageMarksItSeen() async throws {
        let account = MailAccount.demo()
        let inbox = Mailbox(id: UUID(), accountId: account.id, name: "INBOX", role: .inbox, uidValidity: 1, unreadCount: 1)
        var message = MailMessage.demoMessages(accountId: account.id, inboxId: inbox.id)[0]
        message.flags = []
        message.bodyPlain = "已缓存正文"
        message.isBodyDownloaded = true
        let store = MemoryMailStore(snapshot: MailStoreSnapshot(accounts: [account], mailboxes: [inbox], messages: [message], attachments: []))
        let mailService = StubMailService(body: MessageBody(plain: "", html: nil, attachments: []))
        let viewModel = MailAppViewModel(
            secretStore: MemorySecretStore(),
            mailStore: store,
            mailService: mailService,
            aiService: StubAIService(chunks: []),
            vectorStore: InMemoryVectorStore(),
            embeddingService: LocalNLEmbeddingService()
        )
        viewModel.selectedMailboxID = inbox.id
        viewModel.selectedMessageID = message.id

        await viewModel.loadSelectedMessageBodyIfNeeded()
        for _ in 0..<50 where mailService.setFlagsUID == nil {
            try await Task.sleep(nanoseconds: 10_000_000)
        }

        #expect(mailService.fetchedUID == nil)
        #expect(viewModel.messages.first?.flags.contains(.seen) == true)
        #expect(viewModel.mailboxes.first?.unreadCount == 0)
        #expect(mailService.setFlagsUID == message.uid)
        #expect(store.savedSnapshots.last?.messages.first?.flags.contains(.seen) == true)
    }

    @MainActor
    @Test func markSelectedSeenUpdatesUnreadCountAndSyncsImapFlag() async throws {
        let account = MailAccount.demo()
        let inbox = Mailbox(id: UUID(), accountId: account.id, name: "INBOX", role: .inbox, uidValidity: 1, unreadCount: 1)
        var message = MailMessage.demoMessages(accountId: account.id, inboxId: inbox.id)[0]
        message.flags = []
        let store = MemoryMailStore(snapshot: MailStoreSnapshot(accounts: [account], mailboxes: [inbox], messages: [message], attachments: []))
        let mailService = StubMailService(body: MessageBody(plain: "", html: nil, attachments: []))
        let viewModel = MailAppViewModel(
            secretStore: MemorySecretStore(),
            mailStore: store,
            mailService: mailService,
            aiService: StubAIService(chunks: []),
            vectorStore: InMemoryVectorStore(),
            embeddingService: LocalNLEmbeddingService()
        )
        viewModel.selectedMailboxID = inbox.id
        viewModel.selectedMessageID = message.id

        viewModel.markSelectedSeen()
        for _ in 0..<50 where mailService.setFlagsUID == nil {
            try await Task.sleep(nanoseconds: 10_000_000)
        }

        #expect(viewModel.messages.first?.flags.contains(.seen) == true)
        #expect(viewModel.mailboxes.first?.unreadCount == 0)
        #expect(mailService.connectedAccountID == account.id)
        #expect(mailService.setFlagsMailboxID == inbox.id)
        #expect(mailService.setFlagsUID == message.uid)
        #expect(mailService.setFlagsValue?.contains(.seen) == true)
        #expect(store.savedSnapshots.last?.messages.first?.flags.contains(.seen) == true)
        #expect(store.savedSnapshots.last?.mailboxes.first?.unreadCount == 0)
    }

    @MainActor
    @Test func starredSmartMailboxShowsOnlyFlaggedMessages() async throws {
        let account = MailAccount.demo()
        let inbox = Mailbox(id: UUID(), accountId: account.id, name: "INBOX", role: .inbox, uidValidity: 1, unreadCount: 0)
        var messages = MailMessage.demoMessages(accountId: account.id, inboxId: inbox.id)
        messages[0].flags.insert(.flagged)
        messages[1].flags.remove(.flagged)
        messages[2].flags.insert(.flagged)
        let viewModel = MailAppViewModel(
            secretStore: MemorySecretStore(),
            mailStore: MemoryMailStore(snapshot: MailStoreSnapshot(accounts: [account], mailboxes: [inbox], messages: messages, attachments: [])),
            mailService: StubMailService(body: MessageBody(plain: "", html: nil, attachments: [])),
            aiService: StubAIService(chunks: []),
            vectorStore: InMemoryVectorStore(),
            embeddingService: LocalNLEmbeddingService(),
            autoBootstrapEmbeddings: false
        )

        viewModel.selectSmartMailbox(.starred)

        #expect(viewModel.selectedSmartMailbox == .starred)
        #expect(viewModel.starredMessageCount == 2)
        #expect(Set(viewModel.visibleMessages.map(\.id)) == Set([messages[0].id, messages[2].id]))
    }

    @MainActor
    @Test func toggleStarUpdatesLocalStateAndSyncsImapFlag() async throws {
        let account = MailAccount.demo()
        let inbox = Mailbox(id: UUID(), accountId: account.id, name: "INBOX", role: .inbox, uidValidity: 1, unreadCount: 0)
        var message = MailMessage.demoMessages(accountId: account.id, inboxId: inbox.id)[0]
        message.flags = []
        let store = MemoryMailStore(snapshot: MailStoreSnapshot(accounts: [account], mailboxes: [inbox], messages: [message], attachments: []))
        let mailService = StubMailService(body: MessageBody(plain: "", html: nil, attachments: []))
        let viewModel = MailAppViewModel(
            secretStore: MemorySecretStore(),
            mailStore: store,
            mailService: mailService,
            aiService: StubAIService(chunks: []),
            vectorStore: InMemoryVectorStore(),
            embeddingService: LocalNLEmbeddingService(),
            autoBootstrapEmbeddings: false
        )

        viewModel.toggleStar(messageID: message.id)
        for _ in 0..<50 where mailService.setFlagsUID == nil {
            try await Task.sleep(nanoseconds: 10_000_000)
        }

        #expect(viewModel.messages.first?.flags.contains(.flagged) == true)
        #expect(viewModel.starredMessageCount == 1)
        #expect(mailService.connectedAccountID == account.id)
        #expect(mailService.setFlagsMailboxID == inbox.id)
        #expect(mailService.setFlagsUID == message.uid)
        #expect(mailService.setFlagsValue?.contains(.flagged) == true)
        #expect(store.savedSnapshots.last?.messages.first?.flags.contains(.flagged) == true)
    }

    @MainActor
    @Test func deleteSelectedMessageMovesImapMessageToTrash() async throws {
        let account = MailAccount.demo()
        let mailboxes = Mailbox.demoSet(accountId: account.id)
        let inbox = try #require(mailboxes.first { $0.role == .inbox })
        let trash = try #require(mailboxes.first { $0.role == .trash })
        var message = MailMessage.demoMessages(accountId: account.id, inboxId: inbox.id)[0]
        message.flags = []
        message.bodyPlain = "保留的本地正文"
        message.isBodyDownloaded = true
        let attachment = MailAttachment(
            id: UUID(),
            messageId: message.id,
            filename: "delete-check.pdf",
            mimeType: "application/pdf",
            sizeBytes: 32,
            localPath: "/tmp/delete-check.pdf",
            contentId: nil,
            decodedContent: nil
        )
        let store = MemoryMailStore(snapshot: MailStoreSnapshot(accounts: [account], mailboxes: mailboxes, messages: [message], attachments: [attachment]))
        let mailService = StubMailService(body: MessageBody(plain: "", html: nil, attachments: []))
        let viewModel = MailAppViewModel(
            secretStore: MemorySecretStore(),
            mailStore: store,
            mailService: mailService,
            aiService: StubAIService(chunks: []),
            vectorStore: InMemoryVectorStore(),
            embeddingService: LocalNLEmbeddingService()
        )
        viewModel.selectedMailboxID = inbox.id
        viewModel.selectedMessageID = message.id

        viewModel.deleteSelectedMessage()
        for _ in 0..<50 where viewModel.messages.first(where: { $0.id == message.id })?.mailboxId != trash.id {
            try await Task.sleep(nanoseconds: 10_000_000)
        }

        #expect(mailService.connectedAccountID == account.id)
        #expect(mailService.movedUID == message.uid)
        #expect(mailService.movedSourceMailboxID == inbox.id)
        #expect(mailService.movedMailboxID == trash.id)
        let movedMessage = try #require(viewModel.messages.first { $0.id == message.id })
        #expect(movedMessage.mailboxId == trash.id)
        #expect(movedMessage.bodyPlain == "保留的本地正文")
        #expect(viewModel.attachments.first?.messageId == message.id)
        #expect(viewModel.mailboxes.first { $0.id == inbox.id }?.unreadCount == 0)
        #expect(viewModel.mailboxes.first { $0.id == trash.id }?.unreadCount == 1)
        #expect(store.savedSnapshots.last?.messages.first?.mailboxId == trash.id)
        #expect(store.savedSnapshots.last?.attachments.first?.filename == "delete-check.pdf")
        #expect(viewModel.statusMessage == "邮件已移动到 Trash。")
    }

    @MainActor
    @Test func sendDraftAppendsToSentAndCachesLocalCopy() async throws {
        let account = MailAccount.demo()
        let mailboxes = Mailbox.demoSet(accountId: account.id)
        let sentMailbox = try #require(mailboxes.first { $0.role == .sent })
        let store = MemoryMailStore(snapshot: MailStoreSnapshot(accounts: [account], mailboxes: mailboxes, messages: [], attachments: []))
        let mailService = StubMailService(body: MessageBody(plain: "", html: nil, attachments: []))
        let expectedSignature = "Sent from myMail"
        var settings = AppSettings()
        settings.signature = expectedSignature
        let viewModel = MailAppViewModel(
            secretStore: MemorySecretStore(),
            mailStore: store,
            settingsStore: MemorySettingsStore(settings: settings),
            mailService: mailService,
            aiService: StubAIService(chunks: []),
            vectorStore: InMemoryVectorStore(),
            embeddingService: LocalNLEmbeddingService()
        )
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let attachmentURL = directory.appendingPathComponent("sent.txt")
        try Data("sent attachment".utf8).write(to: attachmentURL)
        viewModel.composeDraft = ComposeDraft(
            to: "alice@example.com",
            cc: "bob@example.com",
            subject: "发送缓存测试",
            body: "这是一封已发送邮件",
            instruction: "",
            attachmentURLs: [attachmentURL]
        )

        viewModel.sendDraft()
        for _ in 0..<50 where mailService.sentDrafts.isEmpty || viewModel.messages.first(where: { $0.mailboxId == sentMailbox.id }) == nil {
            try await Task.sleep(nanoseconds: 10_000_000)
        }

        #expect(mailService.sentDrafts.first?.subject == "发送缓存测试")
        #expect(mailService.sentDrafts.first?.bodyPlain == "这是一封已发送邮件\n\n\(expectedSignature)")
        #expect(mailService.sentMailboxID == sentMailbox.id)
        #expect(viewModel.composeDraft.body.isEmpty)
        let sentMessage = try #require(viewModel.messages.first { $0.mailboxId == sentMailbox.id })
        #expect(sentMessage.bodyPlain == "这是一封已发送邮件\n\n\(expectedSignature)")
        #expect(sentMessage.isBodyDownloaded)
        #expect(sentMessage.hasAttachments)
        #expect(sentMessage.embeddingState == MessageEmbeddingState.pending)
        #expect(viewModel.attachments.first?.filename == "sent.txt")
        #expect(store.savedSnapshots.last?.messages.first?.subject == "发送缓存测试")
        #expect(store.savedSnapshots.last?.attachments.first?.localPath == attachmentURL.path)
    }

    @MainActor
    @Test func composeReplyAndForwardIncludeSignature() async throws {
        let account = MailAccount.demo()
        let mailbox = Mailbox(id: UUID(), accountId: account.id, name: "INBOX", role: .inbox, uidValidity: 1, unreadCount: 0)
        var message = MailMessage.demoMessages(accountId: account.id, inboxId: mailbox.id)[0]
        message.subject = "签名测试"
        message.bodyPlain = "原邮件正文"
        let viewModel = MailAppViewModel(
            secretStore: MemorySecretStore(),
            mailStore: MemoryMailStore(snapshot: MailStoreSnapshot(accounts: [account], mailboxes: [mailbox], messages: [message], attachments: [])),
            mailService: StubMailService(body: MessageBody(plain: "", html: nil, attachments: [])),
            aiService: StubAIService(chunks: []),
            vectorStore: InMemoryVectorStore(),
            embeddingService: LocalNLEmbeddingService(),
            autoBootstrapEmbeddings: false
        )
        viewModel.settings.signature = "Regards, myMail"
        viewModel.selectMessage(message)

        viewModel.startCompose()
        #expect(viewModel.composeDraft.body == "Regards, myMail")

        viewModel.replyToSelected()
        #expect(viewModel.composeDraft.body.contains("Regards, myMail"))
        #expect(viewModel.composeDraft.body.contains("---- 原邮件 ----"))
        let replySignatureIndex = try #require(viewModel.composeDraft.body.range(of: "Regards, myMail")?.lowerBound)
        let replyQuoteIndex = try #require(viewModel.composeDraft.body.range(of: "---- 原邮件 ----")?.lowerBound)
        #expect(replySignatureIndex < replyQuoteIndex)

        viewModel.forwardSelected()
        #expect(viewModel.composeDraft.body.contains("Regards, myMail"))
        #expect(viewModel.composeDraft.body.contains("---- 转发邮件 ----"))
        let forwardSignatureIndex = try #require(viewModel.composeDraft.body.range(of: "Regards, myMail")?.lowerBound)
        let forwardQuoteIndex = try #require(viewModel.composeDraft.body.range(of: "---- 转发邮件 ----")?.lowerBound)
        #expect(forwardSignatureIndex < forwardQuoteIndex)
    }

    @MainActor
    @Test func forwardSelectedBuildsForwardDraftWithLocalAttachments() async throws {
        let account = MailAccount.demo()
        let mailbox = Mailbox(id: UUID(), accountId: account.id, name: "INBOX", role: .inbox, uidValidity: 1, unreadCount: 0)
        var message = MailMessage.demoMessages(accountId: account.id, inboxId: mailbox.id)[0]
        message.subject = "合同确认"
        message.fromAddress = "alice@example.com"
        message.fromName = "Alice"
        message.bodyPlain = "请确认合同条款。"
        message.snippet = "请确认合同条款。"

        let attachmentURL = FileManager.default.temporaryDirectory.appendingPathComponent("forward-local.txt")
        try Data("forward attachment".utf8).write(to: attachmentURL)
        defer { try? FileManager.default.removeItem(at: attachmentURL) }
        let attachment = MailAttachment(
            id: UUID(),
            messageId: message.id,
            filename: "forward-local.txt",
            mimeType: "text/plain",
            sizeBytes: 18,
            localPath: attachmentURL.path,
            contentId: nil
        )

        let viewModel = MailAppViewModel(
            secretStore: MemorySecretStore(),
            mailStore: MemoryMailStore(snapshot: MailStoreSnapshot(accounts: [account], mailboxes: [mailbox], messages: [message], attachments: [attachment])),
            mailService: StubMailService(body: MessageBody(plain: "", html: nil, attachments: [])),
            aiService: StubAIService(chunks: []),
            vectorStore: InMemoryVectorStore(),
            embeddingService: LocalNLEmbeddingService(),
            autoBootstrapEmbeddings: false
        )
        viewModel.selectMessage(message)

        viewModel.forwardSelected()

        #expect(viewModel.composeDraft.to.isEmpty)
        #expect(viewModel.composeDraft.cc.isEmpty)
        #expect(viewModel.composeDraft.subject == "Fwd: 合同确认")
        #expect(viewModel.composeDraft.body.contains("---- 转发邮件 ----"))
        #expect(viewModel.composeDraft.body.contains("Alice <alice@example.com>"))
        #expect(viewModel.composeDraft.body.contains("请确认合同条款。"))
        #expect(viewModel.composeDraft.attachmentURLs == [attachmentURL])
    }

    @MainActor
    @Test func aiReplyDraftStreamsIntoComposeBody() async throws {
        let ai = StubAIService(chunks: ["你好，", "\n\n我已收到。"])
        let viewModel = MailAppViewModel(
            secretStore: MemorySecretStore(),
            aiService: ai,
            vectorStore: InMemoryVectorStore(),
            embeddingService: LocalNLEmbeddingService()
        )

        await viewModel.generateAIReplyDraft()

        #expect(viewModel.composeDraft.body.hasPrefix("你好，\n\n我已收到。"))
        #expect(viewModel.composeDraft.body.contains("---- 原邮件 ----"))
        #expect(ai.lastModel == viewModel.settings.selectedChatModel)
        #expect(ai.lastMessages.first?.role == "system")
    }

    @MainActor
    @Test func testAPIKeyRunsMinimalChatRequest() async throws {
        let store = MemorySecretStore()
        let ai = StubAIService(chunks: ["OK"])
        let viewModel = MailAppViewModel(
            secretStore: store,
            aiService: ai,
            vectorStore: InMemoryVectorStore(),
            embeddingService: LocalNLEmbeddingService()
        )

        viewModel.saveAPIKey("sk-test-value")
        await viewModel.testAPIKey()

        #expect(viewModel.statusMessage.contains("API-Key 验证通过"))
        #expect(viewModel.apiKeyTestFeedback == "API-Key 验证通过：OK")
        #expect(viewModel.isTestingAPIKey == false)
        #expect(ai.lastStream == false)
        #expect(ai.lastMessages.last?.content == "请回复 OK")
    }

    @MainActor
    @Test func testAPIKeyReportsMissingSavedKey() async throws {
        let ai = StubAIService(chunks: ["OK"])
        let viewModel = MailAppViewModel(
            secretStore: MemorySecretStore(),
            aiService: ai,
            vectorStore: InMemoryVectorStore(),
            embeddingService: LocalNLEmbeddingService(),
            autoBootstrapEmbeddings: false
        )

        await viewModel.testAPIKey()

        #expect(viewModel.statusMessage == "请先保存 API-Key。")
        #expect(viewModel.apiKeyTestFeedback == "请先保存 API-Key。")
        #expect(viewModel.isTestingAPIKey == false)
        #expect(ai.lastMessages.isEmpty)
    }

    @Test func memorySecretStoreRoundTripsValues() throws {
        let store = MemorySecretStore()
        try store.save("secret", account: "zenmux.apikey")
        #expect(try store.read(account: "zenmux.apikey") == "secret")
        try store.delete(account: "zenmux.apikey")
        #expect(try store.read(account: "zenmux.apikey") == nil)
    }

    @Test func outgoingMessageKeepsAttachmentURLs() {
        let attachment = URL(fileURLWithPath: "/tmp/invoice.pdf")
        let message = OutgoingMessage(
            to: ["alice@example.com"],
            cc: [],
            bcc: [],
            subject: "Invoice",
            bodyPlain: "Attached.",
            attachmentURLs: [attachment]
        )
        #expect(message.attachmentURLs == [attachment])
    }

    @MainActor
    @Test func draftAttachmentLifecycleTracksDuplicatesAndRemoval() throws {
        let viewModel = MailAppViewModel(
            secretStore: MemorySecretStore(),
            mailService: StubMailService(body: MessageBody(plain: "", html: nil, attachments: [])),
            aiService: StubAIService(chunks: []),
            vectorStore: InMemoryVectorStore(),
            embeddingService: LocalNLEmbeddingService(),
            autoBootstrapEmbeddings: false
        )
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let attachment = directory.appendingPathComponent("draft.txt")
        try Data("draft attachment".utf8).write(to: attachment)

        viewModel.addDraftAttachments([attachment, attachment])

        #expect(viewModel.composeDraft.attachmentURLs == [attachment])
        #expect(viewModel.trackedDraftAttachmentCount == 1)

        viewModel.removeDraftAttachment(attachment)

        #expect(viewModel.composeDraft.attachmentURLs.isEmpty)
        #expect(viewModel.trackedDraftAttachmentCount == 0)
    }

    @MainActor
    @Test func successfulSendReleasesTrackedDraftAttachments() async throws {
        let account = MailAccount.demo()
        let sentMailbox = Mailbox(id: UUID(), accountId: account.id, name: "Sent", role: .sent, uidValidity: 1, unreadCount: 0)
        let store = MemoryMailStore(snapshot: MailStoreSnapshot(accounts: [account], mailboxes: [sentMailbox], messages: [], attachments: []))
        let mailService = StubMailService(body: MessageBody(plain: "", html: nil, attachments: []))
        let viewModel = MailAppViewModel(
            secretStore: MemorySecretStore(),
            mailStore: store,
            settingsStore: MemorySettingsStore(settings: AppSettings(signature: "")),
            mailService: mailService,
            aiService: StubAIService(chunks: []),
            vectorStore: InMemoryVectorStore(),
            embeddingService: LocalNLEmbeddingService(),
            autoBootstrapEmbeddings: false
        )
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let attachment = directory.appendingPathComponent("send.txt")
        try Data("send attachment".utf8).write(to: attachment)

        viewModel.composeDraft.to = "alice@example.com"
        viewModel.composeDraft.subject = "附件释放测试"
        viewModel.composeDraft.body = "请查收"
        viewModel.addDraftAttachments([attachment])
        #expect(viewModel.trackedDraftAttachmentCount == 1)

        viewModel.sendDraft()
        for _ in 0..<50 where mailService.sentDrafts.isEmpty {
            try await Task.sleep(nanoseconds: 10_000_000)
        }

        #expect(mailService.sentDrafts.first?.attachmentURLs == [attachment])
        #expect(viewModel.composeDraft.attachmentURLs.isEmpty)
        #expect(viewModel.trackedDraftAttachmentCount == 0)
    }

    @Test func mimeBuilderIncludesAttachments() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let attachment = directory.appendingPathComponent("invoice.txt")
        try Data("hello attachment".utf8).write(to: attachment)

        let account = MailAccount.demo()
        let message = OutgoingMessage(
            to: ["alice@example.com"],
            cc: [],
            bcc: [],
            subject: "发票",
            bodyPlain: "请查收附件。",
            attachmentURLs: [attachment]
        )

        let data = try SMTPMIMEBuilder().makeMessage(from: account, draft: message)
        let raw = try #require(String(data: data, encoding: .utf8))
        #expect(raw.contains("multipart/mixed"))
        #expect(raw.contains("filename=\"invoice.txt\""))
        #expect(raw.contains(Data("hello attachment".utf8).base64EncodedString()))
    }

    @Test func mimeParserExtractsIncomingAttachments() throws {
        let attachmentData = Data("hello attachment".utf8)
        let attachmentPayload = attachmentData.base64EncodedString()
        let raw = """
        MIME-Version: 1.0
        Content-Type: multipart/mixed; boundary="frontier"

        --frontier
        Content-Type: text/plain; charset=utf-8
        Content-Transfer-Encoding: quoted-printable

        =E4=BD=A0=E5=A5=BD=EF=BC=8C=E8=AF=B7=E6=9F=A5=E6=94=B6=E9=99=84=E4=BB=B6=E3=80=82
        --frontier
        Content-Type: text/plain; name="invoice.txt"
        Content-Disposition: attachment; filename="invoice.txt"
        Content-Transfer-Encoding: base64
        Content-ID: <invoice-1>

        \(attachmentPayload)
        --frontier--
        """

        let body = MIMEParser.parseMessageBody(raw)

        #expect(body.plain.contains("你好，请查收附件。"))
        #expect(body.html == nil)
        #expect(body.attachments.count == 1)
        #expect(body.attachments.first?.filename == "invoice.txt")
        #expect(body.attachments.first?.mimeType == "text/plain")
        #expect(body.attachments.first?.sizeBytes == Int64(attachmentData.count))
        #expect(body.attachments.first?.contentId == "invoice-1")
        #expect(body.attachments.first?.decodedContent == attachmentData)
    }

    @Test func mimeParserKeepsImageAttachmentOutOfBodyAndDecodesFilename() throws {
        let pngSignature = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])
        let raw = """
        MIME-Version: 1.0
        Content-Type: multipart/mixed; boundary="image-boundary"

        --image-boundary
        Content-Type: image/png; name="=?UTF-8?B?5rWL6K+V5Zu+54mHLnBuZw==?="
        Content-Disposition: attachment; filename="=?UTF-8?B?5rWL6K+V5Zu+54mHLnBuZw==?="
        Content-Transfer-Encoding: base64

        iVBORw0KGgo=
        --image-boundary--
        """

        let body = MIMEParser.parseMessageBody(raw)

        #expect(body.plain.isEmpty)
        #expect(body.attachments.count == 1)
        #expect(body.attachments.first?.filename == "测试图片.png")
        #expect(body.attachments.first?.mimeType == "image/png")
        #expect(body.attachments.first?.decodedContent == pngSignature)
    }

    @Test func mimeParserDecodesMalformedUTF8Base64Header() {
        let rawSubject = "=?UTF-8?B?5b6Q5b+X5bmz6ICB5biI77yM5pep5LiK5aW9"

        let subject = MIMEParser.decodeHeaderValue(rawSubject)

        #expect(subject == "徐志平老师，早上好")
    }

    @Test func mimeParserDecodesChineseQuotedPrintableCharset() throws {
        let raw = """
        MIME-Version: 1.0
        Content-Type: text/plain; charset=gb2312
        Content-Transfer-Encoding: quoted-printable

        =D7=F0=BE=B4=B5=C4=D0=EC=D6=BE=C6=BD=C0=CF=CA=A6=A3=BA=0D=0A=C4=FA=BA=C3=A3=A1
        """

        let body = MIMEParser.parseMessageBody(raw)

        #expect(body.plain.contains("尊敬的徐志平老师："))
        #expect(body.plain.contains("您好！"))
    }

    @Test func mimeParserDecodesUndeclaredChineseEightBitBody() throws {
        let gb18030Bytes = Data([
            0xD7, 0xF0, 0xBE, 0xB4, 0xB5, 0xC4, 0xD0, 0xEC,
            0xD6, 0xBE, 0xC6, 0xBD, 0xC0, 0xCF, 0xCA, 0xA6,
            0xA3, 0xBA, 0x0D, 0x0A, 0xC4, 0xFA, 0xBA, 0xC3,
            0xA3, 0xA1
        ])
        let bodyBytes = try #require(String(data: gb18030Bytes, encoding: .isoLatin1))
        let raw = """
        MIME-Version: 1.0
        Content-Type: text/plain
        Content-Transfer-Encoding: 8bit

        \(bodyBytes)
        """

        let body = MIMEParser.parseMessageBody(raw)

        #expect(body.plain.contains("尊敬的徐志平老师："))
        #expect(body.plain.contains("您好！"))
    }

    @Test func smtpClientUpgradesStartTLSBeforeAuthentication() throws {
        let endpoint = ServerEndpoint(host: "smtp.example.com", port: 587, tlsMode: "STARTTLS")
        let connection = StubMailLineConnection(lines: [
            "220 smtp.example.com ready",
            "250-smtp.example.com",
            "250 STARTTLS",
            "220 Ready to start TLS",
            "250-smtp.example.com",
            "250 AUTH PLAIN",
            "235 Authentication successful",
            "250 Sender OK",
            "250 Reset OK",
            "221 Bye"
        ])
        let client = SMTPClient(
            endpoint: endpoint,
            credentials: MailConnectionCredentials(username: "me@example.com", password: "secret"),
            connectionFactory: { connection }
        )

        try client.verify(from: "me@example.com")

        #expect(connection.didOpen)
        #expect(connection.didUpgradeToTLS)
        #expect(connection.sentLines.prefix(5) == [
            "EHLO myMail.local",
            "STARTTLS",
            "EHLO myMail.local",
            "AUTH PLAIN AG1lQGV4YW1wbGUuY29tAHNlY3JldA==",
            "MAIL FROM:<me@example.com>"
        ])
    }

    @Test func smtpClientCanUseLegacyPlainConnection() throws {
        let endpoint = ServerEndpoint(host: "smtp.example.com", port: 25, tlsMode: "NONE")
        let connection = StubMailLineConnection(lines: [
            "220 smtp.example.com ready",
            "250 AUTH PLAIN",
            "235 Authentication successful",
            "250 Sender OK",
            "250 Reset OK",
            "221 Bye"
        ])
        let client = SMTPClient(
            endpoint: endpoint,
            credentials: MailConnectionCredentials(username: "me@example.com", password: "secret"),
            connectionFactory: { connection }
        )

        try client.verify(from: "me@example.com")

        #expect(connection.didOpen)
        #expect(!connection.didUpgradeToTLS)
        #expect(connection.sentLines.prefix(3) == [
            "EHLO myMail.local",
            "AUTH PLAIN AG1lQGV4YW1wbGUuY29tAHNlY3JldA==",
            "MAIL FROM:<me@example.com>"
        ])
    }

    @Test func smtpClientCanAuthenticateWithOAuth2() throws {
        let credentials = MailConnectionCredentials(username: "me@gmail.com", secret: "ya29.oauth-token", authType: .oauth2)
        let connection = StubMailLineConnection(lines: [
            "220 smtp.gmail.com ready",
            "250-smtp.gmail.com",
            "250 STARTTLS",
            "220 Ready to start TLS",
            "250-smtp.gmail.com",
            "250 AUTH XOAUTH2",
            "235 Authentication successful",
            "250 Sender OK",
            "250 Reset OK",
            "221 Bye"
        ])
        let client = SMTPClient(
            endpoint: ServerEndpoint(host: "smtp.gmail.com", port: 587, tlsMode: "STARTTLS"),
            credentials: credentials,
            connectionFactory: { connection }
        )

        try client.verify(from: "me@gmail.com")

        #expect(connection.didUpgradeToTLS)
        #expect(connection.sentLines.prefix(3) == ["EHLO myMail.local", "STARTTLS", "EHLO myMail.local"])
        #expect(connection.sentLines.contains("AUTH XOAUTH2 \(credentials.xoauth2Token())"))
        #expect(!connection.sentLines.contains { $0.contains("AUTH PLAIN") })
    }

    @Test func imapClientAppendUsesLiteralAfterContinuation() throws {
        let connection = StubMailLineConnection(lines: [
            "* OK IMAP ready",
            "A1 OK LOGIN completed",
            "+ Ready for literal data",
            "A2 OK APPEND completed",
            "A3 OK LOGOUT completed"
        ])
        let mailbox = Mailbox(id: UUID(), accountId: UUID(), name: "Sent", role: .sent, uidValidity: 1, unreadCount: 0)
        let data = Data("Subject: Hi\r\n\r\nBody".utf8)
        let client = IMAPClient(
            endpoint: ServerEndpoint(host: "mail.fudan.edu.cn", port: 993, tlsMode: "SSL"),
            credentials: MailConnectionCredentials(username: "zpxu@fudan.edu.cn", password: "app-password"),
            connectionFactory: { connection }
        )

        try client.appendMessage(data, to: mailbox)

        #expect(connection.sentLines[0].contains("LOGIN"))
        #expect(connection.sentLines[1] == "A2 APPEND \"Sent\" (\\Seen) {19}")
        #expect(connection.writtenData.first == data)
        #expect(connection.writtenData.last == Data("\r\n".utf8))
    }

    @Test func imapClientDecodesModifiedUTF7MailboxNames() throws {
        let accountId = UUID()
        let connection = StubMailLineConnection(lines: [
            "* OK IMAP ready",
            "A1 OK LOGIN completed",
            "* LIST () \"/\" \"INBOX\"",
            "* LIST () \"/\" \"&W1hoYw-\"",
            "A2 OK LIST completed",
            "A3 OK LOGOUT completed"
        ])
        let client = IMAPClient(
            endpoint: ServerEndpoint(host: "mail.fudan.edu.cn", port: 993, tlsMode: "SSL"),
            credentials: MailConnectionCredentials(username: "zpxu@fudan.edu.cn", password: "app-password"),
            connectionFactory: { connection }
        )

        let mailboxes = try client.fetchMailboxes(accountId: accountId)

        #expect(mailboxes.map(\.name).contains("存档"))
        #expect(!mailboxes.map(\.name).contains("&W1hoYw-"))
    }

    @Test func imapClientRecognizesJunkMailboxes() throws {
        let accountId = UUID()
        let connection = StubMailLineConnection(lines: [
            "* OK IMAP ready",
            "A1 OK LOGIN completed",
            "* LIST (\\HasNoChildren \\Junk) \"/\" \"Junk Mail\"",
            "* LIST () \"/\" \"垃圾邮件\"",
            "A2 OK LIST completed",
            "A3 OK LOGOUT completed"
        ])
        let client = IMAPClient(
            endpoint: ServerEndpoint(host: "mail.example.com", port: 993, tlsMode: "SSL"),
            credentials: MailConnectionCredentials(username: "me@example.com", password: "app-password"),
            connectionFactory: { connection }
        )

        let mailboxes = try client.fetchMailboxes(accountId: accountId)

        #expect(mailboxes.first { $0.name == "Junk Mail" }?.role == .junk)
        #expect(mailboxes.first { $0.name == "垃圾邮件" }?.role == .junk)
    }

    @Test func imapClientFetchesLatestUIDsAndEncodesMailboxNames() throws {
        let mailbox = Mailbox(id: UUID(), accountId: UUID(), name: "存档", role: .archive, uidValidity: 1, unreadCount: 0)
        let connection = StubMailLineConnection(lines: [
            "* OK IMAP ready",
            "A1 OK LOGIN completed",
            "* 12 EXISTS",
            "A2 OK SELECT completed",
            "* SEARCH 3 50 1001 1002",
            "A3 OK SEARCH completed",
            "* 11 FETCH (UID 1001 FLAGS () INTERNALDATE \"22-Jun-2026 12:30:00 +0800\" BODY[HEADER.FIELDS (MESSAGE-ID SUBJECT FROM DATE)] {124}",
            "Message-ID: <1001@mail.fudan.edu.cn>",
            "Subject: 旧邮件一",
            "From: Sender One <one@example.com>",
            "Date: Mon, 22 Jun 2026 10:00:00 +0800",
            ")",
            "* 12 FETCH (UID 1002 FLAGS (\\Seen) INTERNALDATE \"22-Jun-2026 12:45:00 +0800\" BODY[HEADER.FIELDS (MESSAGE-ID SUBJECT FROM DATE)] {124}",
            "Message-ID: <1002@mail.fudan.edu.cn>",
            "Subject: 旧邮件二",
            "From: Sender Two <two@example.com>",
            "Date: Mon, 22 Jun 2026 11:00:00 +0800",
            ")",
            "A4 OK FETCH completed",
            "A5 OK LOGOUT completed"
        ])
        let client = IMAPClient(
            endpoint: ServerEndpoint(host: "mail.fudan.edu.cn", port: 993, tlsMode: "SSL"),
            credentials: MailConnectionCredentials(username: "zpxu@fudan.edu.cn", password: "app-password"),
            connectionFactory: { connection }
        )

        let headers = try client.fetchLatestHeaders(mailbox: mailbox, limit: 2)

        #expect(connection.sentLines.contains("A2 SELECT \"&W1hoYw-\""))
        #expect(connection.sentLines.contains("A3 UID SEARCH ALL"))
        #expect(connection.sentLines.contains { $0.hasPrefix("A4 UID FETCH 1001,1002 ") })
        #expect(connection.sentLines.contains { $0.contains("INTERNALDATE") })
        #expect(!connection.sentLines.contains { $0.contains("UID FETCH 1:2") })
        #expect(headers.map(\.uid) == [1001, 1002])
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss Z"
        #expect(headers.first?.receivedDate == formatter.date(from: "2026-06-22 12:30:00 +0800"))
    }

    @Test func imapClientFetchesPreviousUIDPageBeforeLocalOldest() throws {
        let mailbox = Mailbox(id: UUID(), accountId: UUID(), name: "INBOX", role: .inbox, uidValidity: 1, unreadCount: 0)
        let connection = StubMailLineConnection(lines: [
            "* OK IMAP ready",
            "A1 OK LOGIN completed",
            "* 30 EXISTS",
            "A2 OK SELECT completed",
            "* SEARCH 10 90 95 96 97 140",
            "A3 OK SEARCH completed",
            "* 20 FETCH (UID 96 FLAGS () BODY[HEADER.FIELDS (MESSAGE-ID SUBJECT FROM DATE)] {124}",
            "Message-ID: <96@example.com>",
            "Subject: 更早邮件一",
            "From: Sender One <one@example.com>",
            "Date: Mon, 22 Jun 2026 09:00:00 +0800",
            ")",
            "* 21 FETCH (UID 97 FLAGS () BODY[HEADER.FIELDS (MESSAGE-ID SUBJECT FROM DATE)] {124}",
            "Message-ID: <97@example.com>",
            "Subject: 更早邮件二",
            "From: Sender Two <two@example.com>",
            "Date: Mon, 22 Jun 2026 09:30:00 +0800",
            ")",
            "A4 OK FETCH completed",
            "A5 OK LOGOUT completed"
        ])
        let client = IMAPClient(
            endpoint: ServerEndpoint(host: "imap.example.com", port: 993, tlsMode: "SSL"),
            credentials: MailConnectionCredentials(username: "me@example.com", password: "app-password"),
            connectionFactory: { connection }
        )

        let headers = try client.fetchHeadersBefore(mailbox: mailbox, beforeUID: 100, limit: 2)

        #expect(connection.sentLines.contains("A3 UID SEARCH UID 1:99"))
        #expect(connection.sentLines.contains { $0.hasPrefix("A4 UID FETCH 96,97 ") })
        #expect(!connection.sentLines.contains { $0.contains("UID FETCH 1:2") })
        #expect(headers.map(\.uid) == [96, 97])
    }

    @Test func imapClientCanUseStartTLSOnLegacyPort() throws {
        let accountID = UUID()
        let connection = StubMailLineConnection(lines: [
            "* OK IMAP ready",
            "A1 OK Begin TLS negotiation",
            "A2 OK LOGIN completed",
            "* LIST (\\HasNoChildren) \"/\" \"INBOX\"",
            "A3 OK LIST completed",
            "A4 OK LOGOUT completed"
        ])
        let client = IMAPClient(
            endpoint: ServerEndpoint(host: "imap.example.com", port: 143, tlsMode: "STARTTLS"),
            credentials: MailConnectionCredentials(username: "me@example.com", password: "secret"),
            connectionFactory: { connection }
        )

        let mailboxes = try client.fetchMailboxes(accountId: accountID)

        #expect(connection.didOpen)
        #expect(connection.didUpgradeToTLS)
        #expect(connection.sentLines.prefix(3) == [
            "A1 STARTTLS",
            "A2 LOGIN \"me@example.com\" \"secret\"",
            "A3 LIST \"\" \"*\""
        ])
        #expect(mailboxes.map(\.name) == ["INBOX"])
    }

    @Test func imapClientDecodesEncodedWordHeaders() throws {
        let mailbox = Mailbox(id: UUID(), accountId: UUID(), name: "INBOX", role: .inbox, uidValidity: 1, unreadCount: 0)
        let connection = StubMailLineConnection(lines: [
            "* OK IMAP ready",
            "A1 OK LOGIN completed",
            "* 1 EXISTS",
            "A2 OK SELECT completed",
            "* SEARCH 2030029",
            "A3 OK SEARCH completed",
            "* 1 FETCH (UID 2030029 FLAGS () BODY[HEADER.FIELDS (MESSAGE-ID SUBJECT FROM DATE)] {220}",
            "Message-ID: <encoded-subject@mail.fudan.edu.cn>",
            "Subject: =?UTF-8?B?5b6Q5b+X5bmz?=",
            " =?UTF-8?Q?=E8=80=81=E5=B8=88-2030029?=",
            "From: =?UTF-8?B?5rWL6K+V5Y+R5Lu25Lq6?= <sender@example.com>",
            "Date: Mon, 22 Jun 2026 12:00:00 +0800",
            ")",
            "A4 OK FETCH completed",
            "A5 OK LOGOUT completed"
        ])
        let client = IMAPClient(
            endpoint: ServerEndpoint(host: "mail.fudan.edu.cn", port: 993, tlsMode: "SSL"),
            credentials: MailConnectionCredentials(username: "zpxu@fudan.edu.cn", password: "app-password"),
            connectionFactory: { connection }
        )

        let headers = try client.fetchLatestHeaders(mailbox: mailbox, limit: 1)

        #expect(headers.first?.subject == "徐志平老师-2030029")
        #expect(headers.first?.fromName == "测试发件人")
        #expect(headers.first?.fromAddress == "sender@example.com")
    }

    @Test func imapClientDecodesMalformedBase64SubjectHeaders() throws {
        let mailbox = Mailbox(id: UUID(), accountId: UUID(), name: "Junk Mail", role: .junk, uidValidity: 1, unreadCount: 0)
        let connection = StubMailLineConnection(lines: [
            "* OK IMAP ready",
            "A1 OK LOGIN completed",
            "* 1 EXISTS",
            "A2 OK SELECT completed",
            "* SEARCH 2030030",
            "A3 OK SEARCH completed",
            "* 1 FETCH (UID 2030030 FLAGS () BODY[HEADER.FIELDS (MESSAGE-ID SUBJECT FROM DATE)] {220}",
            "Message-ID: <malformed-subject@mail.fudan.edu.cn>",
            "Subject: =?UTF-8?B?5b6Q5b+X5bmz6ICB5biI77yM5pep5LiK5aW9",
            "From: Sender <sender@example.com>",
            "Date: Mon, 22 Jun 2026 12:00:00 +0800",
            ")",
            "A4 OK FETCH completed",
            "A5 OK LOGOUT completed"
        ])
        let client = IMAPClient(
            endpoint: ServerEndpoint(host: "mail.fudan.edu.cn", port: 993, tlsMode: "SSL"),
            credentials: MailConnectionCredentials(username: "zpxu@fudan.edu.cn", password: "app-password"),
            connectionFactory: { connection }
        )

        let headers = try client.fetchLatestHeaders(mailbox: mailbox, limit: 1)

        #expect(headers.first?.subject == "徐志平老师，早上好")
    }

    @Test func imapClientCanAuthenticateWithOAuth2() throws {
        let credentials = MailConnectionCredentials(username: "me@gmail.com", secret: "ya29.oauth-token", authType: .oauth2)
        let connection = StubMailLineConnection(lines: [
            "* OK IMAP ready",
            "A1 OK AUTHENTICATE completed",
            "A2 OK NOOP completed",
            "A3 OK LOGOUT completed"
        ])
        let client = IMAPClient(
            endpoint: ServerEndpoint(host: "imap.gmail.com", port: 993, tlsMode: "SSL"),
            credentials: credentials,
            connectionFactory: { connection }
        )

        try client.verify()

        #expect(connection.sentLines.first == "A1 AUTHENTICATE XOAUTH2 \(credentials.xoauth2Token())")
        #expect(!connection.sentLines.contains { $0.contains("LOGIN") })
    }

    @Test func imapClientIdleEmitsMailboxEventsAndSendsDone() throws {
        let connection = StubMailLineConnection(lines: [
            "* OK IMAP ready",
            "A1 OK LOGIN completed",
            "A2 OK SELECT completed",
            "+ idling",
            "* 4 EXISTS",
            "* 2 FETCH (UID 42 FLAGS (\\Seen \\Flagged))",
            "* 1 EXPUNGE",
            "A3 OK IDLE terminated",
            "A4 OK LOGOUT completed"
        ])
        let mailbox = Mailbox(id: UUID(), accountId: UUID(), name: "INBOX", role: .inbox, uidValidity: 1, unreadCount: 0)
        let client = IMAPClient(
            endpoint: ServerEndpoint(host: "mail.fudan.edu.cn", port: 993, tlsMode: "SSL"),
            credentials: MailConnectionCredentials(username: "zpxu@fudan.edu.cn", password: "app-password"),
            connectionFactory: { connection }
        )
        var events: [MailboxEvent] = []

        try client.idle(mailbox: mailbox) { event in
            events.append(event)
            return events.count < 3
        }

        #expect(events.count == 3)
        #expect(events[0] == .exists(4))
        #expect(events[1] == .flagsChanged(uid: 42, flags: [.seen, .flagged]))
        #expect(events[2] == .expunge(1))
        #expect(connection.sentLines.contains("A3 IDLE"))
        #expect(connection.sentLines.contains("DONE"))
    }

    @Test func pop3ClientAuthenticatesWithDedicatedPasswordAndParsesHeaders() throws {
        let connection = StubMailLineConnection(lines: [
            "+OK POP3 ready",
            "+OK begin TLS",
            "+OK user accepted",
            "+OK pass accepted",
            "+OK uid list follows",
            "1 fudan-uid-1",
            ".",
            "+OK size list follows",
            "1 512",
            ".",
            "+OK top follows",
            "Message-ID: <fudan-1@mail.fudan.edu.cn>",
            "Subject: 专用密码测试",
            "From: 复旦邮箱 <zpxu@fudan.edu.cn>",
            "Date: Mon, 22 Jun 2026 10:00:00 +0800",
            "",
            ".",
            "+OK bye"
        ])
        let client = POP3Client(
            endpoint: ServerEndpoint(host: "mail.fudan.edu.cn", port: 110, tlsMode: "STARTTLS"),
            credentials: MailConnectionCredentials(username: "zpxu@fudan.edu.cn", password: "app-password"),
            connectionFactory: { connection }
        )

        let headers = try client.fetchHeaders(limit: 20)

        #expect(connection.didOpen)
        #expect(connection.didUpgradeToTLS)
        #expect(connection.sentLines.prefix(3) == ["STLS", "USER zpxu@fudan.edu.cn", "PASS app-password"])
        #expect(headers.first?.messageId == "<fudan-1@mail.fudan.edu.cn>")
        #expect(headers.first?.subject == "专用密码测试")
        #expect(headers.first?.fromAddress == "zpxu@fudan.edu.cn")
    }

    @Test func pop3ClientCanAuthenticateWithOAuth2() throws {
        let credentials = MailConnectionCredentials(username: "me@gmail.com", secret: "ya29.oauth-token", authType: .oauth2)
        let connection = StubMailLineConnection(lines: [
            "+OK POP3 ready",
            "+OK auth accepted",
            "+OK bye"
        ])
        let client = POP3Client(
            endpoint: ServerEndpoint(host: "pop.gmail.com", port: 995, tlsMode: "SSL"),
            credentials: credentials,
            connectionFactory: { connection }
        )

        try client.verify()

        #expect(connection.sentLines.first == "AUTH XOAUTH2 \(credentials.xoauth2Token())")
        #expect(!connection.sentLines.contains { $0.hasPrefix("PASS ") })
    }

    @Test func vectorStoreRanksByCosineSimilarity() throws {
        let store = InMemoryVectorStore()
        let first = UUID()
        let second = UUID()
        try store.upsert(messageId: first, embedding: [1, 0, 0])
        try store.upsert(messageId: second, embedding: [0, 1, 0])

        let matches = try store.topK(query: [0.9, 0.1, 0], k: 2, allowedMessageIDs: nil)
        #expect(matches.first?.messageId == first)
        #expect(matches.count == 2)
    }


    @Test func sqliteVectorStorePersistsVectorsAcrossInstances() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("myMail-vector-store-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let databaseURL = directory.appendingPathComponent("Vectors.sqlite", isDirectory: false)
        let first = UUID()
        let second = UUID()

        do {
            let store = try SQLiteVectorStore(url: databaseURL, preferSQLiteVec: false)
            #expect(store.backend == .jsonFallback)
            try store.upsert(messageId: first, embedding: [1, 0, 0])
            try store.upsert(messageId: second, embedding: [0, 1, 0])
        }

        let reopened = try SQLiteVectorStore(url: databaseURL, preferSQLiteVec: false)
        #expect(reopened.backend == .jsonFallback)
        let matches = try reopened.topK(query: [0.9, 0.1, 0], k: 2, allowedMessageIDs: nil)
        #expect(matches.map(\.messageId) == [first, second])

        let filtered = try reopened.topK(query: [0.9, 0.1, 0], k: 2, allowedMessageIDs: [second])
        #expect(filtered.map(\.messageId) == [second])
    }

    @Test func sqliteVectorStoreFallsBackWhenSQLiteVecIsNotAvailable() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("myMail-vector-store-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let store = try SQLiteVectorStore(url: directory.appendingPathComponent("Vectors.sqlite", isDirectory: false), preferSQLiteVec: false)

        #expect(store.backend == .jsonFallback)
    }

    @Test func ragAnswerUsesVectorMatchesAsChatContextAndCitations() async throws {
        let account = MailAccount.demo()
        let mailboxes = Mailbox.demoSet(accountId: account.id)
        var messages = MailMessage.demoMessages(accountId: account.id, inboxId: mailboxes[0].id)
        messages[0].bodyPlain = "Alice 提醒发票金额是 42000 元，付款日期在下周五。"
        messages[1].bodyPlain = "产品评审安排在周三上午。"
        let embeddingService = StubEmbeddingService(result: .success([[0.7, 0.2, 0.1]]))
        let vectorStore = RecordingVectorStore()
        vectorStore.matches = [
            VectorMatch(messageId: messages[0].id, score: 0.92),
            VectorMatch(messageId: messages[1].id, score: 0.51)
        ]
        let attachment = MailAttachment(
            id: UUID(),
            messageId: messages[0].id,
            filename: "invoice-note.txt",
            mimeType: "text/plain",
            sizeBytes: 22,
            localPath: nil,
            contentId: nil,
            decodedContent: Data("附件说明：发票含税。".utf8)
        )
        let aiService = StubAIService(chunks: ["Alice 提到发票金额是 42000 元 [1]。"])
        let service = SearchService(embeddingService: embeddingService, vectorStore: vectorStore, aiService: aiService)

        let answer = try await service.answer(
            question: "Alice 的发票金额是多少？",
            messages: messages,
            attachments: [attachment],
            chatModel: "openai/gpt-5.4",
            topK: 2
        )

        #expect(embeddingService.requests == [["Alice 的发票金额是多少？"]])
        #expect(vectorStore.lastQuery == [0.7, 0.2, 0.1])
        #expect(vectorStore.lastK == 2)
        #expect(vectorStore.lastAllowedMessageIDs == Set(messages.map(\.id)))
        #expect(aiService.lastModel == "openai/gpt-5.4")
        #expect(aiService.lastStream == true)
        #expect(aiService.lastMessages.count == 2)
        #expect(aiService.lastMessages[1].content.contains("[1]"))
        #expect(aiService.lastMessages[1].content.contains(messages[0].subject))
        #expect(aiService.lastMessages[1].content.contains("42000"))
        #expect(aiService.lastMessages[1].content.contains("附件说明：发票含税。"))
        #expect(answer.answer == "Alice 提到发票金额是 42000 元 [1]。")
        #expect(answer.citations.map(\.id) == [messages[0].id, messages[1].id])
    }

    @MainActor
    @Test func ragAnswerPublishesStreamingPartials() async throws {
        let account = MailAccount.demo()
        let mailboxes = Mailbox.demoSet(accountId: account.id)
        var messages = MailMessage.demoMessages(accountId: account.id, inboxId: mailboxes[0].id)
        messages[0].bodyPlain = "Alice 提醒发票金额是 42000 元。"
        let embeddingService = StubEmbeddingService(result: .success([[0.7, 0.2, 0.1]]))
        let vectorStore = RecordingVectorStore()
        vectorStore.matches = [VectorMatch(messageId: messages[0].id, score: 0.92)]
        let aiService = StubAIService(chunks: ["Alice ", "提到 42000 元 [1]。"])
        let service = SearchService(embeddingService: embeddingService, vectorStore: vectorStore, aiService: aiService)
        var partials: [SearchAnswer] = []

        let answer = try await service.answer(
            question: "Alice 的发票金额是多少？",
            messages: messages,
            chatModel: "openai/gpt-5.4",
            topK: 1,
            onPartial: { partial in
                partials.append(partial)
            }
        )

        #expect(partials.map(\.answer) == ["Alice", "Alice 提到 42000 元 [1]。"])
        #expect(partials.allSatisfy { $0.citations.map(\.id) == [messages[0].id] })
        #expect(answer.answer == "Alice 提到 42000 元 [1]。")
    }

    @Test func ragAnswerUsesConfiguredResponseLanguage() async throws {
        let account = MailAccount.demo()
        let mailboxes = Mailbox.demoSet(accountId: account.id)
        var messages = MailMessage.demoMessages(accountId: account.id, inboxId: mailboxes[0].id)
        messages[0].bodyPlain = "Alice mentioned the invoice total is 42000."
        let embeddingService = StubEmbeddingService(result: .success([[0.7, 0.2, 0.1]]))
        let vectorStore = RecordingVectorStore()
        vectorStore.matches = [VectorMatch(messageId: messages[0].id, score: 0.92)]
        let aiService = StubAIService(chunks: ["Le montant est 42000 [1]."])
        let service = SearchService(embeddingService: embeddingService, vectorStore: vectorStore, aiService: aiService)

        let answer = try await service.answer(
            question: "Quel est le montant de la facture ?",
            messages: messages,
            chatModel: "openai/gpt-5.4",
            responseLanguage: .french
        )

        #expect(aiService.lastMessages.first?.content.contains("Answer in French.") == true)
        #expect(answer.answer == "Le montant est 42000 [1].")
    }

    @Test func ragAnswerRequiresVectorIndexBeforeCallingChatModel() async throws {
        let account = MailAccount.demo()
        let mailboxes = Mailbox.demoSet(accountId: account.id)
        let messages = MailMessage.demoMessages(accountId: account.id, inboxId: mailboxes[0].id)
        let embeddingService = StubEmbeddingService(result: .success([[0.7, 0.2, 0.1]]))
        let vectorStore = RecordingVectorStore()
        vectorStore.matches = []
        let aiService = StubAIService(chunks: ["不应该被调用"])
        let service = SearchService(embeddingService: embeddingService, vectorStore: vectorStore, aiService: aiService)

        let answer = try await service.answer(
            question: "期末论文在哪里？",
            messages: messages,
            chatModel: "openai/gpt-5.4"
        )

        #expect(embeddingService.requests == [["期末论文在哪里？"]])
        #expect(vectorStore.lastAllowedMessageIDs == Set(messages.map(\.id)))
        #expect(answer.answer == SearchService.missingVectorIndexMessage)
        #expect(answer.citations.isEmpty)
        #expect(aiService.lastMessages.isEmpty)
        #expect(aiService.lastModel == nil)
    }

    @Test func ragAnswerLocalizesMissingVectorIndexMessage() async throws {
        let account = MailAccount.demo()
        let mailboxes = Mailbox.demoSet(accountId: account.id)
        let messages = MailMessage.demoMessages(accountId: account.id, inboxId: mailboxes[0].id)
        let embeddingService = StubEmbeddingService(result: .success([[0.7, 0.2, 0.1]]))
        let vectorStore = RecordingVectorStore()
        vectorStore.matches = []
        let aiService = StubAIService(chunks: ["should not be called"])
        let service = SearchService(embeddingService: embeddingService, vectorStore: vectorStore, aiService: aiService)

        let answer = try await service.answer(
            question: "Missä on vektori-indeksi?",
            messages: messages,
            chatModel: "openai/gpt-5.4",
            responseLanguage: .finnish
        )

        #expect(answer.answer == SearchService.missingVectorIndexMessage(language: .finnish))
        #expect(answer.answer.contains("Vektori-indeksiä ei ole saatavilla"))
        #expect(aiService.lastMessages.isEmpty)
    }

    @Test func ragAnswerIncludesKeywordMatchesWhenVectorRankingMissesObviousSubject() async throws {
        let account = MailAccount.demo()
        let mailboxes = Mailbox.demoSet(accountId: account.id)
        var messages = MailMessage.demoMessages(accountId: account.id, inboxId: mailboxes[0].id)
        messages[0].subject = "院系干部选任通知"
        messages[0].snippet = "跨学科合作征集通知"
        messages[1].subject = "您的京东订单【327409736595】电子发票已开具"
        messages[1].fromName = "京东 JD.com"
        messages[1].snippet = "您的京东订单电子发票已开具"
        messages[1].bodyPlain = "电子发票已经开具，可在订单详情中查看。"
        messages[2].subject = "图书馆系统密码重置提醒"
        messages[2].snippet = "密码重置通知"
        let embeddingService = StubEmbeddingService(result: .success([[0.7, 0.2, 0.1]]))
        let vectorStore = RecordingVectorStore()
        vectorStore.matches = [
            VectorMatch(messageId: messages[0].id, score: 0.95),
            VectorMatch(messageId: messages[2].id, score: 0.91)
        ]
        let aiService = StubAIService(chunks: ["电子发票相关邮件是京东订单电子发票已开具 [1]。"])
        let service = SearchService(embeddingService: embeddingService, vectorStore: vectorStore, aiService: aiService)

        let answer = try await service.answer(
            question: "电子发票的邮件是哪些？",
            messages: messages,
            chatModel: "openai/gpt-5.4",
            topK: 3
        )

        #expect(answer.citations.first?.id == messages[1].id)
        #expect(aiService.lastMessages.last?.content.contains("[1]") == true)
        #expect(aiService.lastMessages.last?.content.contains("电子发票已开具") == true)
    }

    @MainActor
    @Test func aiQuestionUsesAllVectorizedMessagesNotOnlyVisibleMailbox() async throws {
        let account = MailAccount.demo()
        let inbox = Mailbox(id: UUID(), accountId: account.id, name: "INBOX", role: .inbox, uidValidity: 1, unreadCount: 0)
        let archive = Mailbox(id: UUID(), accountId: account.id, name: "Archive", role: .archive, uidValidity: 1, unreadCount: 0)
        var messages = MailMessage.demoMessages(accountId: account.id, inboxId: inbox.id)
        messages[0].mailboxId = inbox.id
        messages[0].subject = "当前收件箱邮件"
        messages[0].embeddingState = .done
        messages[1].mailboxId = archive.id
        messages[1].subject = "归档里的期末论文邮件"
        messages[1].bodyPlain = "期末论文提交截止日期是六月底。"
        messages[1].embeddingState = .done
        messages[2].mailboxId = archive.id
        messages[2].subject = "未向量化邮件"
        messages[2].embeddingState = .pending
        let vectorStore = RecordingVectorStore()
        vectorStore.matches = [VectorMatch(messageId: messages[1].id, score: 0.95)]
        let aiService = StubAIService(chunks: ["归档邮件提到期末论文提交截止日期是六月底 [1]。"])
        let viewModel = MailAppViewModel(
            secretStore: MemorySecretStore(),
            mailStore: MemoryMailStore(snapshot: MailStoreSnapshot(accounts: [account], mailboxes: [inbox, archive], messages: messages, attachments: [])),
            mailService: StubMailService(body: MessageBody(plain: "", html: nil, attachments: [])),
            aiService: aiService,
            vectorStore: vectorStore,
            embeddingService: StubEmbeddingService(result: .success([[0.7, 0.2, 0.1]])),
            autoBootstrapEmbeddings: false
        )
        viewModel.selectedMailboxID = inbox.id
        viewModel.aiQuestion = "期末论文什么时候提交？"

        await viewModel.runAIQuestion()

        #expect(viewModel.visibleMessages.map(\.id) == [messages[0].id])
        #expect(vectorStore.lastAllowedMessageIDs == Set([messages[0].id, messages[1].id]))
        #expect(vectorStore.lastAllowedMessageIDs?.contains(messages[2].id) == false)
        #expect(viewModel.aiAnswer?.citations.map(\.id) == [messages[1].id])
        #expect(aiService.lastMessages.last?.content.contains("归档里的期末论文邮件") == true)
    }

    @MainActor
    @Test func aiQuestionPromptsInitializationWhenVectorDatabaseIsEmpty() async throws {
        let account = MailAccount.demo()
        let inbox = Mailbox(id: UUID(), accountId: account.id, name: "INBOX", role: .inbox, uidValidity: 1, unreadCount: 0)
        var message = MailMessage.demoMessages(accountId: account.id, inboxId: inbox.id)[0]
        message.embeddingState = .done
        let aiService = StubAIService(chunks: ["不应该被调用"])
        let viewModel = MailAppViewModel(
            secretStore: MemorySecretStore(),
            mailStore: MemoryMailStore(snapshot: MailStoreSnapshot(accounts: [account], mailboxes: [inbox], messages: [message], attachments: [])),
            mailService: StubMailService(body: MessageBody(plain: "", html: nil, attachments: [])),
            aiService: aiService,
            vectorStore: InMemoryVectorStore(),
            embeddingService: StubEmbeddingService(result: .success([[0.7, 0.2, 0.1]])),
            autoBootstrapEmbeddings: false
        )
        viewModel.aiQuestion = "期末论文在哪里？"

        await viewModel.runAIQuestion()

        #expect(viewModel.aiAnswer?.answer == SearchService.missingVectorIndexMessage)
        #expect(viewModel.aiAnswer?.citations.isEmpty == true)
        #expect(aiService.lastMessages.isEmpty)
        #expect(aiService.lastModel == nil)
    }

    @MainActor
    @Test func selectingCitationSwitchesAccountMailboxAndMessage() async throws {
        let firstAccount = MailAccount.demo()
        var secondAccount = MailAccount.demo()
        secondAccount.id = UUID()
        secondAccount.emailAddress = "second@example.com"
        secondAccount.displayName = "Second Account"

        let firstInbox = Mailbox(id: UUID(), accountId: firstAccount.id, name: "INBOX", role: .inbox, uidValidity: 1, unreadCount: 0)
        let secondInbox = Mailbox(id: UUID(), accountId: secondAccount.id, name: "INBOX", role: .inbox, uidValidity: 1, unreadCount: 0)

        var firstMessage = MailMessage.demoMessages(accountId: firstAccount.id, inboxId: firstInbox.id)[0]
        firstMessage.subject = "第一账户邮件"
        var citationMessage = MailMessage.demoMessages(accountId: secondAccount.id, inboxId: secondInbox.id)[0]
        citationMessage.id = UUID()
        citationMessage.uid = 42
        citationMessage.messageId = "<citation@example.com>"
        citationMessage.subject = "引用邮件"

        let viewModel = MailAppViewModel(
            secretStore: MemorySecretStore(),
            mailStore: MemoryMailStore(snapshot: MailStoreSnapshot(
                accounts: [firstAccount, secondAccount],
                mailboxes: [firstInbox, secondInbox],
                messages: [firstMessage, citationMessage],
                attachments: []
            )),
            mailService: StubMailService(body: MessageBody(plain: "", html: nil, attachments: [])),
            aiService: StubAIService(chunks: []),
            vectorStore: InMemoryVectorStore(),
            embeddingService: LocalNLEmbeddingService(),
            autoBootstrapEmbeddings: false
        )
        viewModel.selectedAccountID = firstAccount.id
        viewModel.selectedMailboxID = nil

        #expect(viewModel.visibleMessages.map(\.id) == [firstMessage.id])

        viewModel.selectMessage(citationMessage)

        #expect(viewModel.selectedAccountID == secondAccount.id)
        #expect(viewModel.selectedMailboxID == secondInbox.id)
        #expect(viewModel.selectedMessageID == citationMessage.id)
        #expect(viewModel.visibleMessages.map(\.id) == [citationMessage.id])
    }

    @MainActor
    @Test func processPendingEmbeddingsOnlyIndexesPendingBatchAndPersistsDone() async throws {
        let account = MailAccount.demo()
        let mailboxes = Mailbox.demoSet(accountId: account.id)
        var messages = MailMessage.demoMessages(accountId: account.id, inboxId: mailboxes[0].id)
        messages[0].embeddingState = .pending
        messages[1].embeddingState = .pending
        messages[2].embeddingState = .done
        let mailStore = MemoryMailStore(snapshot: MailStoreSnapshot(accounts: [account], mailboxes: mailboxes, messages: messages, attachments: []))
        let embeddingService = StubEmbeddingService(result: .success([[0.25, 0.5, 0.75]]))
        let vectorStore = RecordingVectorStore()
        var settings = AppSettings()
        settings.vectorizationEnabled = true
        settings.vectorizationConsentAccepted = true
        let viewModel = MailAppViewModel(
            secretStore: MemorySecretStore(),
            mailStore: mailStore,
            settingsStore: MemorySettingsStore(settings: settings),
            mailService: StubMailService(body: MessageBody(plain: "", html: nil, attachments: [])),
            aiService: StubAIService(chunks: []),
            vectorStore: vectorStore,
            embeddingService: embeddingService,
            autoBootstrapEmbeddings: false
        )

        await viewModel.processPendingEmbeddings(batchSize: 1)

        #expect(embeddingService.requests.count == 1)
        #expect(embeddingService.requests.first?.count == 1)
        #expect(embeddingService.requests.first?.first?.contains(messages[0].subject) == true)
        #expect(vectorStore.upserts.count == 1)
        #expect(vectorStore.upserts.first?.messageId == messages[0].id)
        #expect(viewModel.messages[0].embeddingState == MessageEmbeddingState.done)
        #expect(viewModel.messages[1].embeddingState == MessageEmbeddingState.pending)
        #expect(viewModel.messages[2].embeddingState == MessageEmbeddingState.done)
        #expect(mailStore.savedSnapshots.last?.messages[0].embeddingState == MessageEmbeddingState.done)
        #expect(mailStore.savedSnapshots.last?.messages[1].embeddingState == MessageEmbeddingState.pending)
    }

    @MainActor
    @Test func processPendingEmbeddingsIncludesReadableAttachmentText() async throws {
        let account = MailAccount.demo()
        let mailboxes = Mailbox.demoSet(accountId: account.id)
        var messages = MailMessage.demoMessages(accountId: account.id, inboxId: mailboxes[0].id)
        messages[0].embeddingState = .pending
        let attachment = MailAttachment(
            id: UUID(),
            messageId: messages[0].id,
            filename: "contract.txt",
            mimeType: "text/plain",
            sizeBytes: 28,
            localPath: nil,
            contentId: nil,
            decodedContent: Data("附件合同金额 999 元。".utf8)
        )
        let mailStore = MemoryMailStore(snapshot: MailStoreSnapshot(accounts: [account], mailboxes: mailboxes, messages: messages, attachments: [attachment]))
        let embeddingService = StubEmbeddingService(result: .success([[0.1, 0.2, 0.3]]))
        let vectorStore = RecordingVectorStore()
        var settings = AppSettings()
        settings.vectorizationEnabled = true
        settings.vectorizationConsentAccepted = true
        let viewModel = MailAppViewModel(
            secretStore: MemorySecretStore(),
            mailStore: mailStore,
            settingsStore: MemorySettingsStore(settings: settings),
            mailService: StubMailService(body: MessageBody(plain: "", html: nil, attachments: [])),
            aiService: StubAIService(chunks: []),
            vectorStore: vectorStore,
            embeddingService: embeddingService,
            autoBootstrapEmbeddings: false
        )

        await viewModel.processPendingEmbeddings(batchSize: 1)

        let indexedText = try #require(embeddingService.requests.first?.first)
        #expect(indexedText.contains(messages[0].subject))
        #expect(indexedText.contains("Attachment: contract.txt"))
        #expect(indexedText.contains("附件合同金额 999 元。"))
        #expect(vectorStore.upserts.first?.messageId == messages[0].id)
    }

    @MainActor
    @Test func initializeVectorizationRequeuesExistingMessagesAndProcessesAttachments() async throws {
        let account = MailAccount.demo()
        let mailboxes = Mailbox.demoSet(accountId: account.id)
        var messages = MailMessage.demoMessages(accountId: account.id, inboxId: mailboxes[0].id)
        for index in messages.indices {
            messages[index].embeddingState = .done
        }
        let attachment = MailAttachment(
            id: UUID(),
            messageId: messages[1].id,
            filename: "review.txt",
            mimeType: "text/plain",
            sizeBytes: 25,
            localPath: nil,
            contentId: nil,
            decodedContent: Data("附件：评审在周三上午。".utf8)
        )
        let mailStore = MemoryMailStore(snapshot: MailStoreSnapshot(accounts: [account], mailboxes: mailboxes, messages: messages, attachments: [attachment]))
        let embeddingService = StubEmbeddingService(result: .success([
            [0.1, 0.2],
            [0.2, 0.3],
            [0.3, 0.4]
        ]))
        let vectorStore = RecordingVectorStore()
        var settings = AppSettings()
        settings.vectorizationEnabled = true
        settings.useLocalEmbedding = true
        let viewModel = MailAppViewModel(
            secretStore: MemorySecretStore(),
            mailStore: mailStore,
            settingsStore: MemorySettingsStore(settings: settings),
            mailService: StubMailService(body: MessageBody(plain: "", html: nil, attachments: [])),
            aiService: StubAIService(chunks: []),
            vectorStore: vectorStore,
            embeddingService: embeddingService,
            autoBootstrapEmbeddings: false
        )

        await viewModel.initializeVectorization(batchSize: 3)

        #expect(embeddingService.requests.first?.count == 3)
        #expect(embeddingService.requests.first?.contains { $0.contains("附件：评审在周三上午。") } == true)
        #expect(vectorStore.upserts.map(\.messageId) == messages.map(\.id))
        #expect(viewModel.messages.allSatisfy { $0.embeddingState == .done })
        #expect(mailStore.savedSnapshots.last?.messages.allSatisfy { $0.embeddingState == .done } == true)
        #expect(viewModel.vectorizationProgress?.isActive == false)
        #expect(viewModel.vectorizationProgress?.processed == 3)
        #expect(viewModel.vectorizationProgress?.total == 3)
        #expect(viewModel.vectorizationProgress?.fraction == 1)
        #expect(viewModel.statusMessage.contains("向量化初始化完成"))
    }

    @MainActor
    @Test func processPendingEmbeddingsUsesZenMuxEmbeddingWhenRemoteVectorizationEnabled() async throws {
        let account = MailAccount.demo()
        let mailboxes = Mailbox.demoSet(accountId: account.id)
        var messages = MailMessage.demoMessages(accountId: account.id, inboxId: mailboxes[0].id)
        messages[0].embeddingState = .pending
        let mailStore = MemoryMailStore(snapshot: MailStoreSnapshot(accounts: [account], mailboxes: mailboxes, messages: messages, attachments: []))
        let aiService = StubAIService(chunks: [])
        let vectorStore = RecordingVectorStore()
        var settings = AppSettings()
        settings.vectorizationEnabled = true
        settings.vectorizationConsentAccepted = true
        settings.useLocalEmbedding = false
        settings.embeddingModel = "remote/embedding-model"
        let viewModel = MailAppViewModel(
            secretStore: MemorySecretStore(),
            mailStore: mailStore,
            settingsStore: MemorySettingsStore(settings: settings),
            mailService: StubMailService(body: MessageBody(plain: "", html: nil, attachments: [])),
            aiService: aiService,
            vectorStore: vectorStore,
            autoBootstrapEmbeddings: false
        )

        await viewModel.processPendingEmbeddings(batchSize: 1)

        #expect(aiService.embeddedModels == ["remote/embedding-model"])
        #expect(aiService.embeddedTexts.first?.first?.contains(messages[0].subject) == true)
        #expect(vectorStore.upserts.first?.embedding == [1, 0, 0])
        #expect(viewModel.messages[0].embeddingState == MessageEmbeddingState.done)
    }

    @MainActor
    @Test func processPendingEmbeddingsFallsBackToLocalWhenRemoteEmbeddingFails() async throws {
        let account = MailAccount.demo()
        let mailboxes = Mailbox.demoSet(accountId: account.id)
        var messages = MailMessage.demoMessages(accountId: account.id, inboxId: mailboxes[0].id)
        messages[0].embeddingState = .pending
        let mailStore = MemoryMailStore(snapshot: MailStoreSnapshot(accounts: [account], mailboxes: mailboxes, messages: messages, attachments: []))
        let aiService = StubAIService(chunks: [])
        aiService.embeddingResult = .failure(StubAIService.EmbeddingFailure())
        let vectorStore = RecordingVectorStore()
        var settings = AppSettings()
        settings.vectorizationEnabled = true
        settings.vectorizationConsentAccepted = true
        settings.useLocalEmbedding = false
        settings.embeddingModel = "remote/unsupported-embedding"
        let viewModel = MailAppViewModel(
            secretStore: MemorySecretStore(),
            mailStore: mailStore,
            settingsStore: MemorySettingsStore(settings: settings),
            mailService: StubMailService(body: MessageBody(plain: "", html: nil, attachments: [])),
            aiService: aiService,
            vectorStore: vectorStore,
            autoBootstrapEmbeddings: false
        )

        await viewModel.processPendingEmbeddings(batchSize: 1)

        #expect(aiService.embeddedModels == ["remote/unsupported-embedding"])
        #expect(vectorStore.upserts.count == 1)
        #expect(viewModel.messages[0].embeddingState == MessageEmbeddingState.done)
        #expect(viewModel.statusMessage == "ZenMux 向量化失败，已降级为本地 NLEmbedding。")
    }

    @MainActor
    @Test func processPendingEmbeddingsMarksBatchFailedOnEmbeddingError() async throws {
        let account = MailAccount.demo()
        let mailboxes = Mailbox.demoSet(accountId: account.id)
        var messages = MailMessage.demoMessages(accountId: account.id, inboxId: mailboxes[0].id)
        messages[0].embeddingState = .pending
        messages[1].embeddingState = .pending
        messages[2].embeddingState = .pending
        let mailStore = MemoryMailStore(snapshot: MailStoreSnapshot(accounts: [account], mailboxes: mailboxes, messages: messages, attachments: []))
        let embeddingService = StubEmbeddingService(result: .failure(StubEmbeddingService.Failure()))
        let vectorStore = RecordingVectorStore()
        var settings = AppSettings()
        settings.vectorizationEnabled = true
        settings.vectorizationConsentAccepted = true
        let viewModel = MailAppViewModel(
            secretStore: MemorySecretStore(),
            mailStore: mailStore,
            settingsStore: MemorySettingsStore(settings: settings),
            mailService: StubMailService(body: MessageBody(plain: "", html: nil, attachments: [])),
            aiService: StubAIService(chunks: []),
            vectorStore: vectorStore,
            embeddingService: embeddingService,
            autoBootstrapEmbeddings: false
        )

        await viewModel.processPendingEmbeddings(batchSize: 2)

        #expect(vectorStore.upserts.isEmpty)
        #expect(viewModel.messages[0].embeddingState == MessageEmbeddingState.failed)
        #expect(viewModel.messages[1].embeddingState == MessageEmbeddingState.failed)
        #expect(viewModel.messages[2].embeddingState == MessageEmbeddingState.pending)
        #expect(viewModel.statusMessage.contains("向量化失败"))
        #expect(mailStore.savedSnapshots.last?.messages[0].embeddingState == MessageEmbeddingState.failed)
        #expect(mailStore.savedSnapshots.last?.messages[1].embeddingState == MessageEmbeddingState.failed)
        #expect(mailStore.savedSnapshots.last?.messages[2].embeddingState == MessageEmbeddingState.pending)
    }

    @Test func coreDataModelContainsRequiredEntitiesAndIndexes() {
        let model = MailCoreDataModelFactory.makeModel()
        #expect(model.entitiesByName["Account"] != nil)
        #expect(model.entitiesByName["Mailbox"] != nil)
        #expect(model.entitiesByName["Message"] != nil)
        #expect(model.entitiesByName["Attachment"] != nil)

        let message = model.entitiesByName["Message"]
        #expect(message?.uniquenessConstraints.first as? [String] == ["messageId"])
        #expect(message?.indexes.contains { $0.name == "message_account_mailbox_uid" } == true)
    }

    @MainActor
    @Test func coreDataMailStoreRoundTripsSnapshot() throws {
        let store = CoreDataMailStore(stack: CoreDataStack(inMemory: true))
        let account = MailAccount.demo()
        let mailboxes = Mailbox.demoSet(accountId: account.id)
        let messages = MailMessage.demoMessages(accountId: account.id, inboxId: mailboxes[0].id)
        let attachment = MailAttachment(
            id: UUID(),
            messageId: messages[0].id,
            filename: "invoice.pdf",
            mimeType: "application/pdf",
            sizeBytes: 42_000,
            localPath: nil,
            contentId: nil
        )
        let snapshot = MailStoreSnapshot(accounts: [account], mailboxes: mailboxes, messages: messages, attachments: [attachment])

        try store.saveSnapshot(snapshot)
        let loaded = try store.loadSnapshot()

        #expect(loaded.accounts.first?.authType == .appPassword)
        #expect(loaded.mailboxes.count == mailboxes.count)
        #expect(loaded.messages.first?.messageId == messages.first?.messageId)
        #expect(loaded.attachments.first?.filename == "invoice.pdf")
    }
}

final class StubAIService: AIService {
    struct EmbeddingFailure: LocalizedError {
        var errorDescription: String? { "stub remote embedding failure" }
    }

    let chunks: [String]
    var lastModel: String?
    var lastMessages: [ChatMessage] = []
    var lastStream: Bool?
    var embeddedModels: [String] = []
    var embeddedTexts: [[String]] = []
    var embeddingResult: Result<[[Float]], Error>?

    init(chunks: [String]) {
        self.chunks = chunks
    }

    func chat(model: String, messages: [ChatMessage], stream: Bool) -> AsyncThrowingStream<String, Error> {
        lastModel = model
        lastMessages = messages
        lastStream = stream
        return AsyncThrowingStream { continuation in
            for chunk in chunks {
                continuation.yield(chunk)
            }
            continuation.finish()
        }
    }

    func embed(model: String, texts: [String]) async throws -> [[Float]] {
        embeddedModels.append(model)
        embeddedTexts.append(texts)
        if let embeddingResult {
            return try embeddingResult.get()
        }
        return texts.map { _ in [1, 0, 0] }
    }
}

final class StubEmbeddingService: EmbeddingService {
    struct Failure: LocalizedError {
        var errorDescription: String? { "stub embedding failure" }
    }

    var requests: [[String]] = []
    private let result: Result<[[Float]], Error>

    init(result: Result<[[Float]], Error>) {
        self.result = result
    }

    func embed(texts: [String]) async throws -> [[Float]] {
        requests.append(texts)
        return try result.get()
    }
}

final class RecordingVectorStore: VectorStore {
    var upserts: [(messageId: UUID, embedding: [Float])] = []
    var matches: [VectorMatch] = []
    var lastQuery: [Float] = []
    var lastK: Int?
    var lastAllowedMessageIDs: Set<UUID>?

    func upsert(messageId: UUID, embedding: [Float]) throws {
        upserts.append((messageId, embedding))
    }

    func topK(query: [Float], k: Int, allowedMessageIDs: Set<UUID>?) throws -> [VectorMatch] {
        lastQuery = query
        lastK = k
        lastAllowedMessageIDs = allowedMessageIDs
        return matches
    }
}

@MainActor
final class MemoryMailStore: MailStore {
    private var snapshot: MailStoreSnapshot
    var savedSnapshots: [MailStoreSnapshot] = []

    init(snapshot: MailStoreSnapshot) {
        self.snapshot = snapshot
    }

    func loadSnapshot() throws -> MailStoreSnapshot {
        snapshot
    }

    func saveSnapshot(_ snapshot: MailStoreSnapshot) throws {
        self.snapshot = snapshot
        savedSnapshots.append(snapshot)
    }
}

final class MemorySettingsStore: SettingsStore {
    var savedSettings: [AppSettings] = []
    private var settings: AppSettings?

    init(settings: AppSettings? = nil) {
        self.settings = settings
    }

    func loadSettings() -> AppSettings? {
        settings
    }

    func saveSettings(_ settings: AppSettings) {
        self.settings = settings
        savedSettings.append(settings)
    }
}

final class StubMailService: MailService {
    private let body: MessageBody
    var connectedAccountID: UUID?
    var fetchedMailboxID: UUID?
    var fetchedUID: Int64?
    var sentDrafts: [OutgoingMessage] = []
    var savedDrafts: [OutgoingMessage] = []
    var savedDraftMailboxID: UUID?
    var sentMailboxID: UUID?
    var setFlagsMailboxID: UUID?
    var setFlagsUID: Int64?
    var setFlagsValue: MessageFlags?
    var movedUID: Int64?
    var movedSourceMailboxID: UUID?
    var movedMailboxID: UUID?
    var deletedUID: Int64?
    var deletedMailboxID: UUID?
    var testedAccount: MailAccount?
    var testedPassword: String?
    var mailboxesToReturn: [Mailbox] = []
    var headersToReturn: [MessageHeader] = []
    var olderHeadersToReturn: [MessageHeader] = []
    var headersByMailboxID: [UUID: [MessageHeader]] = [:]
    var olderHeaderBatchesByMailboxID: [UUID: [[MessageHeader]]] = [:]
    var fetchedHeaderMailboxIDs: [UUID] = []
    var fetchedHeaderRanges: [ClosedRange<Int64>] = []
    var fetchedOlderHeaderRequests: [(mailboxID: UUID, beforeUID: Int64, limit: Int)] = []
    var connectAttempts = 0
    var fetchMailboxAttempts = 0
    var fetchHeaderAttempts = 0
    var connectFailuresRemaining = 0
    var fetchMailboxFailuresRemaining = 0
    var fetchHeaderFailuresRemaining = 0
    var connectFailureMessage = "stub connect failure"
    var outgoingTestFailureMessage: String?
    var fetchMailboxFailureMessage = "stub mailbox failure"
    var fetchHeaderFailureMessage = "stub header failure"
    var idleMailboxID: UUID?
    var idleEvents: [MailboxEvent] = []

    init(body: MessageBody) {
        self.body = body
    }

    func connect(_ account: MailAccount) async throws {
        connectAttempts += 1
        if connectFailuresRemaining > 0 {
            connectFailuresRemaining -= 1
            throw MailServiceError.connectionFailed(connectFailureMessage)
        }
        connectedAccountID = account.id
    }

    func testConnection(_ account: MailAccount, password: String) async throws {
        testedAccount = account
        testedPassword = password
    }

    func testIncomingConnection(_ account: MailAccount, password: String) async throws {
        testedAccount = account
        testedPassword = password
    }

    func testOutgoingConnection(_ account: MailAccount, password: String) async throws {
        testedAccount = account
        testedPassword = password
        if let outgoingTestFailureMessage {
            throw MailServiceError.connectionFailed(outgoingTestFailureMessage)
        }
    }

    func fetchMailboxes() async throws -> [Mailbox] {
        fetchMailboxAttempts += 1
        if fetchMailboxFailuresRemaining > 0 {
            fetchMailboxFailuresRemaining -= 1
            throw MailServiceError.connectionFailed(fetchMailboxFailureMessage)
        }
        return mailboxesToReturn
    }

    func fetchHeaders(mailbox: Mailbox, uidRange: ClosedRange<Int64>) async throws -> [MessageHeader] {
        fetchHeaderAttempts += 1
        if fetchHeaderFailuresRemaining > 0 {
            fetchHeaderFailuresRemaining -= 1
            throw MailServiceError.connectionFailed(fetchHeaderFailureMessage)
        }
        fetchedHeaderMailboxIDs.append(mailbox.id)
        fetchedHeaderRanges.append(uidRange)
        return headersByMailboxID[mailbox.id] ?? headersToReturn
    }

    func fetchLatestHeaders(mailbox: Mailbox, limit: Int) async throws -> [MessageHeader] {
        try await fetchHeaders(mailbox: mailbox, uidRange: 1...Int64(limit))
    }

    func fetchHeadersBefore(mailbox: Mailbox, beforeUID: Int64, limit: Int) async throws -> [MessageHeader] {
        fetchHeaderAttempts += 1
        if fetchHeaderFailuresRemaining > 0 {
            fetchHeaderFailuresRemaining -= 1
            throw MailServiceError.connectionFailed(fetchHeaderFailureMessage)
        }
        fetchedOlderHeaderRequests.append((mailbox.id, beforeUID, limit))
        if var batches = olderHeaderBatchesByMailboxID[mailbox.id], !batches.isEmpty {
            let result = batches.removeFirst()
            olderHeaderBatchesByMailboxID[mailbox.id] = batches
            return result
        }
        return olderHeadersToReturn
    }

    func fetchBody(mailbox: Mailbox, uid: Int64) async throws -> MessageBody {
        fetchedMailboxID = mailbox.id
        fetchedUID = uid
        return body
    }

    func setFlags(mailbox: Mailbox, uid: Int64, flags: MessageFlags) async throws {
        setFlagsMailboxID = mailbox.id
        setFlagsUID = uid
        setFlagsValue = flags
    }

    func moveMessage(uid: Int64, from sourceMailbox: Mailbox, to targetMailbox: Mailbox) async throws {
        movedUID = uid
        movedSourceMailboxID = sourceMailbox.id
        movedMailboxID = targetMailbox.id
    }

    func deleteMessage(uid: Int64, from mailbox: Mailbox) async throws {
        deletedUID = uid
        deletedMailboxID = mailbox.id
    }

    func saveDraft(_ draft: OutgoingMessage, to draftsMailbox: Mailbox) async throws -> Int64? {
        savedDrafts.append(draft)
        savedDraftMailboxID = draftsMailbox.id
        return nil
    }

    func sendMessage(_ draft: OutgoingMessage, appendTo sentMailbox: Mailbox?) async throws {
        sentDrafts.append(draft)
        sentMailboxID = sentMailbox?.id
    }

    func idle(mailbox: Mailbox) -> AsyncStream<MailboxEvent> {
        idleMailboxID = mailbox.id
        let events = idleEvents
        return AsyncStream { continuation in
            Task {
                for event in events {
                    continuation.yield(event)
                    await Task.yield()
                }
                continuation.finish()
            }
        }
    }
}

final class OAuthMockURLProtocol: URLProtocol {
    typealias StubPredicate = (URLRequest, String) -> Bool
    typealias StubHandler = (URLRequest, String) throws -> (HTTPURLResponse, Data)

    private struct Stub {
        var id: UUID
        var predicate: StubPredicate
        var handler: StubHandler
    }

    private nonisolated(unsafe) static var stubs: [Stub] = []
    private static let lock = NSLock()

    static func registerStub(matching predicate: @escaping StubPredicate, handler: @escaping StubHandler) -> UUID {
        let id = UUID()
        lock.withLock {
            stubs.append(Stub(id: id, predicate: predicate, handler: handler))
        }
        return id
    }

    static func unregisterStub(_ id: UUID) {
        lock.withLock {
            stubs.removeAll { $0.id == id }
        }
    }

    override class func canInit(with request: URLRequest) -> Bool {
        true
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        let body = Self.bodyString(for: request)
        let handler = Self.lock.withLock {
            Self.stubs.first { $0.predicate(request, body) }?.handler
        }
        guard let handler else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }

        do {
            let (response, data) = try handler(request, body)
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}

    private static func bodyString(for request: URLRequest) -> String {
        if let data = request.httpBody {
            return String(data: data, encoding: .utf8) ?? ""
        }
        guard let stream = request.httpBodyStream else { return "" }
        stream.open()
        defer { stream.close() }

        var data = Data()
        let bufferSize = 1024
        let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: bufferSize)
        defer { buffer.deallocate() }

        while stream.hasBytesAvailable {
            let count = stream.read(buffer, maxLength: bufferSize)
            if count <= 0 { break }
            data.append(buffer, count: count)
        }
        return String(data: data, encoding: .utf8) ?? ""
    }
}

final class StubMailLineConnection: MailLineConnection {
    private var lines: [String]
    var sentLines: [String] = []
    var writtenData: [Data] = []
    var didOpen = false
    var didClose = false
    var didUpgradeToTLS = false

    init(lines: [String]) {
        self.lines = lines
    }

    func open() throws {
        didOpen = true
    }

    func close() {
        didClose = true
    }

    func upgradeToTLS() throws {
        didUpgradeToTLS = true
    }

    func sendLine(_ line: String) throws {
        sentLines.append(line)
    }

    func write(_ data: Data) throws {
        writtenData.append(data)
    }

    func readLine(timeout: TimeInterval) throws -> String {
        guard !lines.isEmpty else {
            throw MailServiceError.connectionFailed("stub response exhausted")
        }
        return lines.removeFirst()
    }
}
