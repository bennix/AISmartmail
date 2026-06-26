//
//  MailAppViewModel.swift
//  myMail
//

import Combine
import Foundation
import Network

enum APIKeyTestState {
    case idle
    case missing
    case testing
    case success
    case failure
}

@MainActor
final class MailAppViewModel: ObservableObject {
    @Published var accounts: [MailAccount]
    @Published var mailboxes: [Mailbox]
    @Published var messages: [MailMessage] {
        didSet { messagesRevision &+= 1 }
    }
    @Published var attachments: [MailAttachment]
    @Published var selectedAccountID: UUID?
    @Published var selectedMailboxID: UUID?
    @Published var selectedSmartMailbox: SmartMailbox? = nil
    @Published var selectedMessageID: UUID?
    @Published var searchText = ""
    @Published var searchMode: SearchMode = .filter
    @Published var messageSortField: MessageSortField = .date {
        didSet { postponeAutomaticLoadMore() }
    }
    @Published var messageSortAscending = false {
        didSet { postponeAutomaticLoadMore() }
    }
    @Published var aiQuestion = ""
    @Published var aiAnswer: SearchAnswer?
    @Published var isSearchingAI = false
    @Published var statusMessage = ""
    @Published var composeDraft = ComposeDraft() {
        didSet { scheduleDraftSync() }
    }
    @Published var isTestingAPIKey = false
    @Published var apiKeyTestState: APIKeyTestState = .idle
    @Published private var apiKeyTestDetail: String?
    @Published var vectorizationProgress: VectorizationProgress?
    @Published var settings = AppSettings() {
        didSet {
            persistSettings()
            if statusMessage == AppLocalizer.text(.ready, language: oldValue.interfaceLanguage) {
                statusMessage = localized(.ready)
            }
            refreshAPIKeyMask()
        }
    }
    @Published var apiKeyMask = ""
    @Published var isAPIKeyVisible = false
    @Published var showsVectorizationPrivacyPrompt = false

    private let secretStore: SecretStore
    private let mailStore: MailStore?
    private let settingsStore: SettingsStore
    private let sharedMailService: MailService?
    private let mailServiceFactory: () -> MailService
    private let aiService: AIService
    private let vectorStore: VectorStore
    private let injectedEmbeddingService: EmbeddingService?
    private let localEmbeddingService = LocalNLEmbeddingService()
    private let oauth2Service: OAuth2Service
    private let attachmentCacheRoot: URL
    private var pop3PollingTask: Task<Void, Never>?
    private var imapIdleTask: Task<Void, Never>?
    private var draftAttachmentAccess: [URL: Bool] = [:]
    private var pendingOAuthLogin: PendingOAuthLogin?
    private let retryDelayNanoseconds: UInt64
    private var mailServicesByAccount: [UUID: MailService] = [:]
    private let accountOperationQueue = MailAccountOperationQueue()
    @Published private(set) var loadingMoreMailboxIDs: Set<UUID> = []
    private var exhaustedOlderMailboxIDs: Set<UUID> = []
    private var messagesRevision = 0
    private var visibleMessagesCacheKey: VisibleMessagesCacheKey?
    private var visibleMessagesCache: [MailMessage] = []
    private var starredMessageCountCacheRevision = -1
    private var starredMessageCountCache = 0
    private var automaticLoadMoreSuppressedUntil = Date.distantPast
    private var delayedSnapshotPersistTask: Task<Void, Never>?
    private var delayedDraftSyncTask: Task<Void, Never>?
    private var cachedDraftMessageID: UUID?
    private var lastSyncedDraft: ComposeDraft?
    private var isResettingDraft = false

    private struct VisibleMessagesCacheKey: Equatable {
        var messagesRevision: Int
        var selectedAccountID: UUID?
        var selectedMailboxID: UUID?
        var selectedSmartMailbox: SmartMailbox?
        var searchMode: SearchMode
        var searchText: String
        var messageSortField: MessageSortField
        var messageSortAscending: Bool
    }

    init(
        secretStore: SecretStore? = nil,
        mailStore: MailStore? = nil,
        settingsStore: SettingsStore? = nil,
        mailService: MailService? = nil,
        mailServiceFactory: (() -> MailService)? = nil,
        aiService: AIService? = nil,
        vectorStore: VectorStore? = nil,
        embeddingService: EmbeddingService? = nil,
        oauth2Service: OAuth2Service? = nil,
        attachmentCacheRoot: URL? = nil,
        autoBootstrapEmbeddings: Bool = true,
        retryDelayNanoseconds: UInt64 = 250_000_000
    ) {
        let resolvedSecretStore = secretStore ?? KeychainStore()
        let resolvedSettingsStore = settingsStore ?? UserDefaultsSettingsStore()
        let resolvedOAuth2Service = oauth2Service ?? OAuth2Service()
        let resolvedAIService = aiService ?? ZenMuxAIService(secretStore: resolvedSecretStore)
        let oauthClientIDProvider: OAuthClientIDProvider = { provider in
            (resolvedSettingsStore.loadSettings() ?? AppSettings()).oauthClientID(for: provider)
        }
        self.secretStore = resolvedSecretStore
        self.mailStore = mailStore
        self.settingsStore = resolvedSettingsStore
        self.sharedMailService = mailService
        if let mailServiceFactory {
            self.mailServiceFactory = mailServiceFactory
        } else if let mailService {
            self.mailServiceFactory = { mailService }
        } else {
            self.mailServiceFactory = {
                NativeMailService(
                    secretStore: resolvedSecretStore,
                    oauth2Service: resolvedOAuth2Service,
                    oauthClientIDProvider: oauthClientIDProvider
                )
            }
        }
        self.aiService = resolvedAIService
        self.vectorStore = vectorStore ?? Self.defaultVectorStore()
        self.injectedEmbeddingService = embeddingService
        self.oauth2Service = resolvedOAuth2Service
        self.attachmentCacheRoot = attachmentCacheRoot ?? Self.defaultAttachmentCacheRoot()
        self.retryDelayNanoseconds = retryDelayNanoseconds

        let seed = Self.makeSeedSnapshot()
        var snapshot = seed
        var persistenceStatus: String?
        if let mailStore {
            do {
                let loaded = try mailStore.loadSnapshot()
                if loaded.accounts.isEmpty {
                    try mailStore.saveSnapshot(seed)
                } else {
                    snapshot = loaded
                }
            } catch {
                persistenceStatus = "本地缓存读取失败，已加载演示数据：\(error.localizedDescription)"
            }
        }

        self.accounts = snapshot.accounts
        self.mailboxes = snapshot.mailboxes
        self.messages = snapshot.messages.map(Self.normalizedHeaderFields).sorted(by: Self.orderedByNewestReceivedDate)
        self.attachments = snapshot.attachments
        normalizeBuiltInProviderEndpoints()
        var loadedSettings = resolvedSettingsStore.loadSettings() ?? AppSettings()
        loadedSettings.embeddingModel = ""
        loadedSettings.useLocalEmbedding = true
        loadedSettings.vectorizationConsentAccepted = true
        self.settings = loadedSettings
        resolvedSettingsStore.saveSettings(loadedSettings)
        self.selectedAccountID = snapshot.accounts.first?.id
        self.selectedMailboxID = snapshot.mailboxes.first?.id
        self.selectedMessageID = self.messages.first { message in
            (selectedAccountID == nil || message.accountId == selectedAccountID)
            && (selectedMailboxID == nil || message.mailboxId == selectedMailboxID)
        }?.id

        statusMessage = localized(.ready)
        if autoBootstrapEmbeddings {
            Task { await bootstrapEmbeddings() }
        }
        refreshAPIKeyMask()
        if let persistenceStatus {
            statusMessage = persistenceStatus
        }
    }

    private func normalizeBuiltInProviderEndpoints() {
        var didChange = false
        for index in accounts.indices {
            switch accounts[index].provider {
            case .gmail, .icloud, .outlook:
                let preset = ProviderPreset.preset(for: accounts[index].provider)
                if accounts[index].imap != preset.imap || accounts[index].smtp != preset.smtp || accounts[index].pop3 != preset.pop3 {
                    accounts[index].imap = preset.imap
                    accounts[index].smtp = preset.smtp
                    accounts[index].pop3 = preset.pop3
                    didChange = true
                }
            case .generic, .fudan, .custom:
                continue
            }
        }
        if didChange {
            persistSnapshot()
        }
    }

    deinit {
        delayedDraftSyncTask?.cancel()
        delayedSnapshotPersistTask?.cancel()
        for (url, didStartAccess) in draftAttachmentAccess where didStartAccess {
            url.stopAccessingSecurityScopedResource()
        }
    }

    var selectedAccount: MailAccount? {
        accounts.first { $0.id == selectedAccountID }
    }

    var selectedMailbox: Mailbox? {
        mailboxes.first { $0.id == selectedMailboxID }
    }

    var selectedMessage: MailMessage? {
        messages.first { $0.id == selectedMessageID }
    }

    var selectedMessageIsDraft: Bool {
        guard let selectedMessage else { return false }
        return isDraftMessage(selectedMessage)
    }

    var isLoadingMoreSelectedMailbox: Bool {
        guard let selectedMailboxID else { return false }
        return loadingMoreMailboxIDs.contains(selectedMailboxID)
    }

    var showsLoadMoreSelectedMailboxControl: Bool {
        guard let selectedMailbox,
              let account = accounts.first(where: { $0.id == selectedMailbox.accountId }),
              account.useProtocol == .imap else { return false }
        return visibleMessages.contains { $0.mailboxId == selectedMailbox.id }
            || exhaustedOlderMailboxIDs.contains(selectedMailbox.id)
            || loadingMoreMailboxIDs.contains(selectedMailbox.id)
    }

    var canLoadMoreSelectedMailbox: Bool {
        guard let selectedMailbox,
              let account = accounts.first(where: { $0.id == selectedMailbox.accountId }),
              account.useProtocol == .imap,
              !loadingMoreMailboxIDs.contains(selectedMailbox.id),
              !exhaustedOlderMailboxIDs.contains(selectedMailbox.id) else { return false }
        let mailboxMessages = messages.filter { $0.accountId == account.id && $0.mailboxId == selectedMailbox.id }
        guard let oldestUID = mailboxMessages.map(\.uid).min() else { return false }
        return oldestUID > 1
    }

    var visibleMailboxes: [Mailbox] {
        guard let selectedAccountID else { return [] }
        return mailboxes.filter { $0.accountId == selectedAccountID }
    }

    var messageListResetID: String {
        [
            selectedAccountID?.uuidString ?? "all-accounts",
            selectedMailboxID?.uuidString ?? "all-mailboxes",
            selectedSmartMailbox?.id ?? "mailbox",
            searchMode.id,
            messageSortField.id,
            messageSortAscending ? "ascending" : "descending"
        ].joined(separator: "|")
    }

    var visibleMessages: [MailMessage] {
        let key = VisibleMessagesCacheKey(
            messagesRevision: messagesRevision,
            selectedAccountID: selectedAccountID,
            selectedMailboxID: selectedMailboxID,
            selectedSmartMailbox: selectedSmartMailbox,
            searchMode: searchMode,
            searchText: searchText,
            messageSortField: messageSortField,
            messageSortAscending: messageSortAscending
        )
        guard visibleMessagesCacheKey != key else {
            return visibleMessagesCache
        }

        visibleMessagesCache = computeVisibleMessages()
        visibleMessagesCacheKey = key
        return visibleMessagesCache
    }

    var starredMessageCount: Int {
        guard starredMessageCountCacheRevision != messagesRevision else {
            return starredMessageCountCache
        }
        starredMessageCountCache = messages.reduce(0) { count, message in
            count + (message.flags.contains(.flagged) ? 1 : 0)
        }
        starredMessageCountCacheRevision = messagesRevision
        return starredMessageCountCache
    }

    var hasSavedAPIKey: Bool {
        guard let value = try? secretStore.read(account: "zenmux.apikey") else { return false }
        return !value.isEmpty
    }

    var apiKeyTestFeedback: String {
        switch apiKeyTestState {
        case .idle:
            return localized(.apiKeyInitialFeedback)
        case .missing:
            return localized(.apiKeyMissingSavedKey)
        case .testing:
            return localized(.apiKeyTesting)
        case .success:
            if let apiKeyTestDetail, !apiKeyTestDetail.isEmpty {
                return localized(.apiKeyValidationPassedWithResponse, apiKeyTestDetail)
            }
            return localized(.apiKeyValidationPassed)
        case .failure:
            return localized(.apiKeyValidationFailed, apiKeyTestDetail ?? "")
        }
    }

    private var trimmedSelectedChatModel: String {
        settings.selectedChatModel.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func chatAIConfigurationMessage() -> String? {
        guard hasSavedAPIKey else {
            return localized(.apiKeyMissingSavedKey)
        }
        guard !trimmedSelectedChatModel.isEmpty else {
            return localized(.chatModelMissing)
        }
        return nil
    }

    private func normalizedAppPassword(_ password: String, provider: MailProvider) -> String {
        let trimmed = password.trimmingCharacters(in: .whitespacesAndNewlines)
        guard provider == .gmail else { return trimmed }
        return trimmed.filter { !$0.isWhitespace }
    }

    private func computeVisibleMessages() -> [MailMessage] {
        let scoped = messages.filter { message in
            if selectedSmartMailbox == .starred {
                return message.flags.contains(.flagged)
            }
            if let selectedAccountID, message.accountId != selectedAccountID {
                return false
            }
            if let selectedMailboxID, message.mailboxId != selectedMailboxID {
                return false
            }
            return true
        }
        let filtered = searchMode == .filter && !searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? makeSearchService().filter(messages: scoped, query: searchText)
            : scoped
        return sortMessages(filtered)
    }

    private func sortMessages(_ messages: [MailMessage]) -> [MailMessage] {
        switch messageSortField {
        case .date:
            return messages.sorted { lhs, rhs in
                if lhs.sortDate != rhs.sortDate {
                    return messageSortAscending ? lhs.sortDate < rhs.sortDate : lhs.sortDate > rhs.sortDate
                }
                return lhs.uid > rhs.uid
            }
        case .sender:
            let locale = settings.interfaceLanguage.formatLocale
            return messages.map { message in
                (
                    message: message,
                    senderKey: message.senderDisplayName.folding(
                        options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive],
                        locale: locale
                    )
                )
            }
            .sorted { lhs, rhs in
                if lhs.senderKey != rhs.senderKey {
                    return messageSortAscending ? lhs.senderKey < rhs.senderKey : lhs.senderKey > rhs.senderKey
                }
                if lhs.message.sortDate != rhs.message.sortDate {
                    return lhs.message.sortDate > rhs.message.sortDate
                }
                return lhs.message.uid > rhs.message.uid
            }
            .map(\.message)
        }
    }

    func localized(_ key: AppText) -> String {
        AppLocalizer.text(key, language: settings.interfaceLanguage)
    }

    func localized(_ key: AppText, _ arguments: CVarArg...) -> String {
        String(
            format: localized(key),
            locale: settings.interfaceLanguage.formatLocale,
            arguments: arguments
        )
    }

    func localized(_ mode: SearchMode) -> String {
        switch (settings.interfaceLanguage, mode) {
        case (_, .ai): return localized(.aiQuestionHelp)
        case (.traditionalChinese, .filter): return "篩選"
        case (.japanese, .filter): return "フィルター"
        case (.korean, .filter): return "필터"
        case (.english, .filter): return "Filter"
        case (.french, .filter): return "Filtrer"
        case (.russian, .filter): return "Фильтр"
        case (.swedish, .filter): return "Filter"
        case (.ukrainian, .filter): return "Фільтр"
        case (.finnish, .filter): return "Suodatus"
        case (.simplifiedChinese, .filter): return "过滤"
        }
    }

    func localized(_ field: MessageSortField) -> String {
        switch (settings.interfaceLanguage, field) {
        case (.traditionalChinese, .date): return "收件時間"
        case (.traditionalChinese, .sender): return "寄件者"
        case (.japanese, .date): return "受信日時"
        case (.japanese, .sender): return "差出人"
        case (.korean, .date): return "받은 시간"
        case (.korean, .sender): return "보낸 사람"
        case (.english, .date): return "Received date"
        case (.english, .sender): return "Sender"
        case (.french, .date): return "Date de réception"
        case (.french, .sender): return "Expéditeur"
        case (.russian, .date): return "Дата получения"
        case (.russian, .sender): return "Отправитель"
        case (.swedish, .date): return "Mottagningsdatum"
        case (.swedish, .sender): return "Avsändare"
        case (.ukrainian, .date): return "Дата отримання"
        case (.ukrainian, .sender): return "Відправник"
        case (.finnish, .date): return "Vastaanottoaika"
        case (.finnish, .sender): return "Lähettäjä"
        case (.simplifiedChinese, .date): return "收件时间"
        case (.simplifiedChinese, .sender): return "发件人"
        }
    }

    func localizedSortTitle(field: MessageSortField, ascending: Bool) -> String {
        switch field {
        case .date:
            switch settings.interfaceLanguage {
            case .simplifiedChinese: return ascending ? "旧到新" : "新到旧"
            case .traditionalChinese: return ascending ? "舊到新" : "新到舊"
            case .japanese: return ascending ? "古い順" : "新しい順"
            case .korean: return ascending ? "오래된 순" : "최신 순"
            case .english: return ascending ? "Oldest first" : "Newest first"
            case .french: return ascending ? "Ancien d'abord" : "Récent d'abord"
            case .russian: return ascending ? "Сначала старые" : "Сначала новые"
            case .swedish: return ascending ? "Äldst först" : "Nyast först"
            case .ukrainian: return ascending ? "Спочатку старі" : "Спочатку нові"
            case .finnish: return ascending ? "Vanhimmat ensin" : "Uusimmat ensin"
            }
        case .sender:
            return ascending ? "A → Z" : "Z → A"
        }
    }

    func localizedProviderTitle(_ provider: MailProvider) -> String {
        switch provider {
        case .generic, .fudan:
            return localized(.genericProvider)
        case .custom:
            return localized(.customProvider)
        case .gmail:
            return "Gmail"
        case .icloud:
            return "iCloud"
        case .outlook:
            return "Outlook"
        }
    }

    func localizedProviderInlineNote(_ provider: MailProvider) -> String {
        switch provider {
        case .generic, .fudan, .custom:
            return localized(.providerInlineGeneric)
        case .gmail:
            return localized(.oauthBrowserLoginNote)
        case .icloud, .outlook:
            return localized(.appPasswordVisibilityNote)
        }
    }

    func localizedEndpointLabel(_ endpoint: ServerEndpoint) -> String {
        let tls = endpoint.normalizedTLSMode == "NONE" ? localized(.noEncryption) : endpoint.normalizedTLSMode
        return "\(endpoint.host):\(endpoint.port) \(tls)"
    }

    func localizedProgress(_ progress: VectorizationProgress) -> String {
        if progress.failed > 0 {
            return localized(.vectorizationProgressProcessedFailed, progress.processed, progress.total, progress.failed)
        }
        return localized(.vectorizationProgressProcessed, progress.processed, progress.total)
    }

    func attachments(for message: MailMessage) -> [MailAttachment] {
        attachments.filter { $0.messageId == message.id }
    }

    var trackedDraftAttachmentCount: Int {
        draftAttachmentAccess.count
    }

    func addDraftAttachments(_ urls: [URL]) {
        for url in urls where !composeDraft.attachmentURLs.contains(url) {
            composeDraft.attachmentURLs.append(url)
            draftAttachmentAccess[url] = url.startAccessingSecurityScopedResource()
        }
    }

    func removeDraftAttachment(_ url: URL) {
        composeDraft.attachmentURLs.removeAll { $0 == url }
        releaseDraftAttachment(url)
    }

    func updateComposeDraft(_ update: (inout ComposeDraft) -> Void) {
        var draft = composeDraft
        update(&draft)
        composeDraft = draft
    }

    func selectMailbox(_ mailbox: Mailbox) {
        postponeAutomaticLoadMore()
        selectedSmartMailbox = nil
        selectedAccountID = mailbox.accountId
        selectedMailboxID = mailbox.id
        selectedMessageID = visibleMessages.first?.id
    }

    func selectSmartMailbox(_ smartMailbox: SmartMailbox) {
        postponeAutomaticLoadMore()
        selectedSmartMailbox = smartMailbox
        selectedAccountID = nil
        selectedMailboxID = nil
        selectedMessageID = visibleMessages.first?.id
    }

    func selectMessage(_ message: MailMessage) {
        selectedSmartMailbox = nil
        selectedAccountID = message.accountId
        selectedMailboxID = message.mailboxId
        selectedMessageID = message.id
    }

    func selectMessage(id messageID: UUID) {
        guard let message = messages.first(where: { $0.id == messageID }) else { return }
        selectMessage(message)
    }

    func deleteAccount(accountID: UUID) {
        guard let account = accounts.first(where: { $0.id == accountID }) else {
            statusMessage = "未找到账户。"
            return
        }

        do {
            try secretStore.delete(account: "account.\(accountID.uuidString).password")
            if let oauthRef = account.oauthRefreshTokenRef {
                try secretStore.delete(account: oauthRef)
            }
        } catch {
            statusMessage = error.localizedDescription
            return
        }

        let deletedMessageIDs = Set(messages.filter { $0.accountId == accountID }.map(\.id))
        removeCachedAttachmentDirectories(for: deletedMessageIDs)
        accounts.removeAll { $0.id == accountID }
        mailboxes.removeAll { $0.accountId == accountID }
        messages.removeAll { $0.accountId == accountID }
        attachments.removeAll { deletedMessageIDs.contains($0.messageId) }
        mailServicesByAccount.removeValue(forKey: accountID)
        if selectedAccountID == accountID {
            selectedAccountID = accounts.first?.id
        }
        selectedMailboxID = selectedAccountID.flatMap { accountID in
            mailboxes.first { $0.accountId == accountID }?.id
        }
        selectedMessageID = visibleMessages.first?.id
        if accounts.isEmpty {
            stopInboxIdle()
            selectedMailboxID = nil
            selectedMessageID = nil
        }
        persistSnapshot()
        statusMessage = "账户配置已删除。"
    }

    private func removeCachedAttachmentDirectories(for messageIDs: Set<UUID>) {
        for messageID in messageIDs {
            let directory = attachmentCacheRoot.appendingPathComponent(messageID.uuidString, isDirectory: true)
            try? FileManager.default.removeItem(at: directory)
        }
    }

    @discardableResult
    func openSelectedDraftForEditing() -> Bool {
        guard let selectedMessageID else { return false }
        return openDraftForEditing(messageID: selectedMessageID)
    }

    @discardableResult
    func openDraftForEditing(messageID: UUID) -> Bool {
        guard let message = messages.first(where: { $0.id == messageID }), isDraftMessage(message) else { return false }
        releaseAllDraftAttachments()
        let draftAttachmentURLs = attachments(for: message).compactMap { attachment -> URL? in
            guard let localPath = attachment.localPath else { return nil }
            return URL(fileURLWithPath: localPath)
        }

        let restoredDraft = ComposeDraft(
            to: decodeAddressList(message.toRecipientsJSON).joined(separator: ", "),
            cc: decodeAddressList(message.ccRecipientsJSON).joined(separator: ", "),
            subject: message.subject == "(无主题)" ? "" : message.subject,
            body: message.bodyPlain ?? message.snippet,
            instruction: "",
            attachmentURLs: draftAttachmentURLs
        )

        isResettingDraft = true
        composeDraft = restoredDraft
        isResettingDraft = false
        cachedDraftMessageID = message.id
        lastSyncedDraft = restoredDraft
        for url in draftAttachmentURLs {
            draftAttachmentAccess[url] = url.startAccessingSecurityScopedResource()
        }
        statusMessage = "草稿已打开，可继续编辑。"
        return true
    }

    private func isDraftMessage(_ message: MailMessage) -> Bool {
        if message.flags.contains(.draft) { return true }
        guard let mailbox = mailboxes.first(where: { $0.id == message.mailboxId }) else { return false }
        return mailbox.role == .drafts
    }

    func loadSelectedMessageBodyIfNeeded() async {
        markSelectedSeen()

        guard let selectedMessageID,
              let messageIndex = messages.firstIndex(where: { $0.id == selectedMessageID }),
              !messages[messageIndex].isBodyDownloaded,
              let account = accounts.first(where: { $0.id == messages[messageIndex].accountId }),
              let mailbox = mailboxes.first(where: { $0.id == messages[messageIndex].mailboxId }) else { return }

        let messageID = messages[messageIndex].id
        let uid = messages[messageIndex].uid
        statusMessage = "正在下载邮件正文..."
        do {
            let body = try await withAccountOperation(accountID: account.id) {
                let service = service(for: account)
                try await service.connect(account)
                return try await service.fetchBody(mailbox: mailbox, uid: uid)
            }
            guard let updateIndex = messages.firstIndex(where: { $0.id == messageID }) else { return }
            let snippet = String(body.plain.prefix(200))
            let materialized = materializeDownloadedAttachments(body.attachments, messageID: messageID)
            let downloadedAttachments = materialized.attachments

            messages[updateIndex].bodyPlain = body.plain
            messages[updateIndex].bodyHTML = body.html
            messages[updateIndex].snippet = snippet.isEmpty ? messages[updateIndex].snippet : snippet
            messages[updateIndex].hasAttachments = !downloadedAttachments.isEmpty
            messages[updateIndex].isBodyDownloaded = true
            messages[updateIndex].embeddingState = .pending
            attachments.removeAll { $0.messageId == messageID }
            attachments.append(contentsOf: downloadedAttachments)
            persistSnapshot()
            if materialized.failedFilenames.isEmpty {
                statusMessage = "正文已缓存。"
            } else {
                statusMessage = "正文已缓存，部分附件保存失败：\(materialized.failedFilenames.joined(separator: ", "))"
            }
        } catch {
            markNeedsReauthIfAuthenticationFailed(accountID: account.id, error: error)
            statusMessage = error.localizedDescription
        }
    }

    private func materializeDownloadedAttachments(_ incoming: [MailAttachment], messageID: UUID) -> (attachments: [MailAttachment], failedFilenames: [String]) {
        var failedFilenames: [String] = []
        let attachments = incoming.map { source in
            var attachment = source
            attachment.messageId = messageID

            if attachment.localPath == nil, let decodedContent = attachment.decodedContent {
                do {
                    attachment.localPath = try saveAttachmentData(decodedContent, attachment: attachment)
                } catch {
                    failedFilenames.append(attachment.filename)
                }
            }

            attachment.decodedContent = nil
            return attachment
        }
        return (attachments, failedFilenames)
    }

    private func saveAttachmentData(_ data: Data, attachment: MailAttachment) throws -> String {
        let messageDirectory = attachmentCacheRoot.appendingPathComponent(attachment.messageId.uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: messageDirectory, withIntermediateDirectories: true)
        let filename = sanitizedAttachmentFilename(attachment.filename)
        let fileURL = messageDirectory.appendingPathComponent("\(attachment.id.uuidString)-\(filename)", isDirectory: false)
        try data.write(to: fileURL, options: .atomic)
        return fileURL.path
    }

    private func sanitizedAttachmentFilename(_ filename: String) -> String {
        var invalidCharacters = CharacterSet(charactersIn: "/:")
        invalidCharacters.insert(charactersIn: "\\")
        let cleaned = filename
            .components(separatedBy: invalidCharacters)
            .joined(separator: "_")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return cleaned.isEmpty ? "attachment" : cleaned
    }

    private static func defaultAttachmentCacheRoot() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first ?? FileManager.default.temporaryDirectory
        return base
            .appendingPathComponent("myMail", isDirectory: true)
            .appendingPathComponent("Attachments", isDirectory: true)
    }

    private static func defaultVectorStore() -> VectorStore {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first ?? FileManager.default.temporaryDirectory
        let directory = base.appendingPathComponent("myMail", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            return try SQLiteVectorStore(url: directory.appendingPathComponent("Vectors.sqlite", isDirectory: false))
        } catch {
            return InMemoryVectorStore()
        }
    }

    func refresh() {
        guard let account = selectedAccount else {
            statusMessage = "请先选择账户。"
            return
        }
        statusMessage = "正在收取新邮件..."
        Task {
            await synchronize(account: account, preferredMailboxID: selectedMailboxID, successMessage: "新邮件同步完成。")
        }
    }

    func pollPOP3Once() async {
        let pop3Accounts = accounts.filter { $0.useProtocol == .pop3 }
        guard !pop3Accounts.isEmpty else {
            statusMessage = "没有需要 POP3 轮询的账户。"
            return
        }

        for account in pop3Accounts {
            await synchronize(account: account, preferredMailboxID: nil, successMessage: "POP3 轮询完成。")
        }
    }

    func startPOP3Polling() {
        stopPOP3Polling()
        pop3PollingTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.pollPOP3Once()
                let minutes = self?.settings.pop3PollingMinutes ?? 5
                let seconds = UInt64(max(minutes, 1) * 60)
                try? await Task.sleep(nanoseconds: seconds * 1_000_000_000)
            }
        }
    }

    func stopPOP3Polling() {
        pop3PollingTask?.cancel()
        pop3PollingTask = nil
    }

    func startInboxIdle() {
        stopInboxIdle()
        guard let account = selectedAccount, account.useProtocol == .imap else {
            statusMessage = "请选择 IMAP 账户以启用 IDLE。"
            return
        }
        let mailbox = mailboxes.first { $0.accountId == account.id && $0.role == .inbox } ?? selectedMailbox
        guard let mailbox else {
            statusMessage = "没有可监听的收件箱。"
            return
        }

        imapIdleTask = Task { [weak self] in
            guard let self else { return }
            let service = self.service(for: account)
            do {
                try await self.withAccountOperation(accountID: account.id) {
                    try await service.connect(account)
                }
            } catch {
                self.markNeedsReauthIfAuthenticationFailed(accountID: account.id, error: error)
                self.statusMessage = error.localizedDescription
                return
            }
            for await event in service.idle(mailbox: mailbox) {
                if Task.isCancelled { break }
                await self.handleIdleEvent(event, account: account, mailbox: mailbox)
            }
        }
        statusMessage = "正在监听 \(mailbox.name) 新邮件..."
    }

    func stopInboxIdle() {
        imapIdleTask?.cancel()
        imapIdleTask = nil
    }

    private func handleIdleEvent(_ event: MailboxEvent, account: MailAccount, mailbox: Mailbox) async {
        switch event {
        case .exists:
            await synchronize(account: account, preferredMailboxID: mailbox.id, successMessage: "IDLE 收到新邮件，已同步。")
        case .flagsChanged(let uid, let flags):
            if let index = messages.firstIndex(where: { $0.accountId == account.id && $0.mailboxId == mailbox.id && $0.uid == uid }) {
                messages[index].flags = flags
                persistSnapshot()
            }
        case .expunge(let sequence):
            statusMessage = "服务器移除了一封邮件（序号 \(sequence)），下次同步会更新列表。"
        }
    }

    private func withRetry<T>(_ operation: () async throws -> T) async throws -> T {
        var lastError: Error?
        for attempt in 1...3 {
            do {
                return try await operation()
            } catch {
                lastError = error
                if attempt < 3 {
                    let delay = retryDelayNanoseconds * UInt64(attempt)
                    if delay > 0 {
                        try? await Task.sleep(nanoseconds: delay)
                    }
                }
            }
        }
        throw lastError ?? MailServiceError.connectionFailed("同步失败")
    }

    private func service(for account: MailAccount) -> MailService {
        if let sharedMailService {
            return sharedMailService
        }
        if let existing = mailServicesByAccount[account.id] {
            return existing
        }
        let created = mailServiceFactory()
        mailServicesByAccount[account.id] = created
        return created
    }

    private func withAccountOperation<T>(accountID: UUID, _ operation: () async throws -> T) async throws -> T {
        await accountOperationQueue.acquire(accountID)
        do {
            let result = try await operation()
            await accountOperationQueue.release(accountID)
            return result
        } catch {
            await accountOperationQueue.release(accountID)
            throw error
        }
    }

    private func synchronize(account: MailAccount, preferredMailboxID: UUID?, successMessage: String) async {
        statusMessage = "正在连接 \(account.emailAddress)..."
        do {
            try await withAccountOperation(accountID: account.id) {
                let service = service(for: account)
                try await withRetry {
                    try await service.connect(account)
                }
                let remoteMailboxes = try await withRetry {
                    try await service.fetchMailboxes()
                }
                if !remoteMailboxes.isEmpty {
                    let mergedMailboxes = mergeMailboxes(remoteMailboxes, account: account)
                    mailboxes.removeAll { $0.accountId == account.id }
                    mailboxes.append(contentsOf: mergedMailboxes)
                    if account.id == selectedAccountID {
                        selectedMailboxID = preferredMailboxID.flatMap { id in mergedMailboxes.first { $0.id == id }?.id }
                        ?? mergedMailboxes.first(where: { $0.role == .inbox })?.id
                        ?? mergedMailboxes.first?.id
                    }
                }

                let targetMailboxes = mailboxesToSynchronize(for: account, preferredMailboxID: preferredMailboxID)
                guard !targetMailboxes.isEmpty else {
                    persistSnapshot()
                    statusMessage = successMessage
                    return
                }

                for mailbox in targetMailboxes {
                    let latestHeaders = try await withRetry {
                        try await service.fetchLatestHeaders(mailbox: mailbox, limit: settings.cacheMessageLimit)
                    }
                    let headers = try await completeIMAPHeaderSyncIfNeeded(
                        initialHeaders: latestHeaders,
                        account: account,
                        mailbox: mailbox,
                        service: service
                    )
                    merge(headers: headers, account: account, mailbox: mailbox, enforceLimit: account.useProtocol != .imap)
                }
                persistSnapshot()
                statusMessage = successMessage
            }
        } catch {
            markNeedsReauthIfAuthenticationFailed(accountID: account.id, error: error)
            statusMessage = error.localizedDescription
        }
    }

    private func mailboxesToSynchronize(for account: MailAccount, preferredMailboxID: UUID?) -> [Mailbox] {
        guard account.useProtocol == .imap else {
            return mailboxToSync(for: account, preferredMailboxID: preferredMailboxID).map { [$0] } ?? []
        }

        let accountMailboxes = mailboxes.filter { $0.accountId == account.id }
        var targets: [Mailbox] = []
        if let primary = mailboxToSync(for: account, preferredMailboxID: preferredMailboxID) {
            targets.append(primary)
        }
        for mailbox in accountMailboxes
        where mailbox.role != .drafts
            && mailbox.role != .trash
            && !targets.contains(where: { $0.id == mailbox.id }) {
            targets.append(mailbox)
        }
        return targets
    }

    private func completeIMAPHeaderSyncIfNeeded(
        initialHeaders: [MessageHeader],
        account: MailAccount,
        mailbox: Mailbox,
        service: MailService
    ) async throws -> [MessageHeader] {
        guard account.useProtocol == .imap else { return initialHeaders }
        exhaustedOlderMailboxIDs.remove(mailbox.id)
        _ = service
        return initialHeaders
    }

    func loadMoreSelectedMailboxMessages() async {
        guard let selectedMailboxID,
              let message = visibleMessages.last(where: { $0.mailboxId == selectedMailboxID }) else { return }
        await loadMoreMessagesIfNeeded(currentMessage: message, requiresNearEnd: false)
    }

    func loadMoreMessagesIfNeeded(currentMessage message: MailMessage, requiresNearEnd: Bool = true) async {
        guard !requiresNearEnd || visibleMessages.suffix(8).contains(where: { $0.id == message.id }) else { return }
        guard !requiresNearEnd || Date() >= automaticLoadMoreSuppressedUntil else { return }
        guard let mailbox = selectedMailbox, mailbox.id == message.mailboxId else { return }
        guard let account = accounts.first(where: { $0.id == mailbox.accountId }), account.useProtocol == .imap else { return }
        guard !loadingMoreMailboxIDs.contains(mailbox.id), !exhaustedOlderMailboxIDs.contains(mailbox.id) else { return }

        let mailboxMessages = messages.filter { $0.accountId == account.id && $0.mailboxId == mailbox.id }
        guard let oldestUID = mailboxMessages.map(\.uid).min(), oldestUID > 1 else {
            exhaustedOlderMailboxIDs.insert(mailbox.id)
            return
        }

        loadingMoreMailboxIDs.insert(mailbox.id)
        statusMessage = "正在加载更早的邮件..."
        defer { loadingMoreMailboxIDs.remove(mailbox.id) }

        do {
            try await withAccountOperation(accountID: account.id) {
                let service = service(for: account)
                try await withRetry {
                    try await service.connect(account)
                }
                let headers = try await withRetry {
                    try await service.fetchHeadersBefore(mailbox: mailbox, beforeUID: oldestUID, limit: min(max(settings.cacheMessageLimit, 1), 50))
                }
                guard !headers.isEmpty else {
                    exhaustedOlderMailboxIDs.insert(mailbox.id)
                    statusMessage = "已到达该邮箱最早的邮件。"
                    return
                }
                let insertedCount = merge(headers: headers, account: account, mailbox: mailbox, enforceLimit: false)
                if insertedCount > 0 {
                    statusMessage = "已加载 \(insertedCount) 封更早的邮件。"
                } else {
                    exhaustedOlderMailboxIDs.insert(mailbox.id)
                    statusMessage = "没有更多可加载的历史邮件。"
                }
                scheduleSnapshotPersist()
            }
        } catch {
            markNeedsReauthIfAuthenticationFailed(accountID: account.id, error: error)
            statusMessage = error.localizedDescription
        }
    }

    private func postponeAutomaticLoadMore() {
        automaticLoadMoreSuppressedUntil = Date().addingTimeInterval(0.8)
    }

    private func mailboxToSync(for account: MailAccount, preferredMailboxID: UUID?) -> Mailbox? {
        let accountMailboxes = mailboxes.filter { $0.accountId == account.id }
        if account.useProtocol == .pop3 {
            return accountMailboxes.first(where: { $0.role == .inbox }) ?? accountMailboxes.first
        }
        if let preferredMailboxID, let mailbox = accountMailboxes.first(where: { $0.id == preferredMailboxID }) {
            return mailbox
        }
        return accountMailboxes.first(where: { $0.role == .inbox }) ?? accountMailboxes.first
    }

    private func mergeMailboxes(_ remoteMailboxes: [Mailbox], account: MailAccount) -> [Mailbox] {
        remoteMailboxes.map { remote in
            var mailbox = remote
            if let existing = mailboxes.first(where: {
                $0.accountId == account.id
                && $0.name.caseInsensitiveCompare(remote.name) == .orderedSame
                && $0.role == remote.role
            }) {
                mailbox.id = existing.id
            }
            return mailbox
        }
    }

    func markSelectedSeen() {
        guard let selectedMessageID,
              let index = messages.firstIndex(where: { $0.id == selectedMessageID }),
              !messages[index].flags.contains(.seen),
              let account = accounts.first(where: { $0.id == messages[index].accountId }),
              let mailbox = mailboxes.first(where: { $0.id == messages[index].mailboxId }) else { return }
        let uid = messages[index].uid
        messages[index].flags.insert(.seen)
        updateUnreadCount(for: mailbox.id)
        persistSnapshot()

        guard account.useProtocol == .imap else { return }
        let updatedFlags = messages[index].flags
        Task { [weak self] in
            guard let self else { return }
            let service = self.service(for: account)
            do {
                try await self.withAccountOperation(accountID: account.id) {
                    try await service.connect(account)
                    try await service.setFlags(mailbox: mailbox, uid: uid, flags: updatedFlags)
                }
            } catch {
                self.markNeedsReauthIfAuthenticationFailed(accountID: account.id, error: error)
                self.statusMessage = error.localizedDescription
            }
        }
    }

    func toggleStar(messageID: UUID) {
        guard let index = messages.firstIndex(where: { $0.id == messageID }),
              let account = accounts.first(where: { $0.id == messages[index].accountId }),
              let mailbox = mailboxes.first(where: { $0.id == messages[index].mailboxId }) else { return }

        let uid = messages[index].uid
        if messages[index].flags.contains(.flagged) {
            messages[index].flags.remove(.flagged)
            statusMessage = "已取消星标。"
        } else {
            messages[index].flags.insert(.flagged)
            statusMessage = "已添加星标。"
        }
        let updatedFlags = messages[index].flags
        persistSnapshot()

        if selectedSmartMailbox == .starred,
           selectedMessageID == messageID,
           !updatedFlags.contains(.flagged) {
            selectedMessageID = visibleMessages.first?.id
        }

        guard account.useProtocol == .imap else { return }
        Task { [weak self] in
            guard let self else { return }
            let service = self.service(for: account)
            do {
                try await self.withAccountOperation(accountID: account.id) {
                    try await service.connect(account)
                    try await service.setFlags(mailbox: mailbox, uid: uid, flags: updatedFlags)
                }
            } catch {
                self.markNeedsReauthIfAuthenticationFailed(accountID: account.id, error: error)
                self.statusMessage = error.localizedDescription
            }
        }
    }

    func archiveSelectedMessage() {
        guard let selectedMessageID,
              let message = messages.first(where: { $0.id == selectedMessageID }),
              let account = accounts.first(where: { $0.id == message.accountId }),
              let sourceMailbox = mailboxes.first(where: { $0.id == message.mailboxId }) else { return }

        let archiveMailbox = ensureArchiveMailbox(for: account)
        guard sourceMailbox.id != archiveMailbox.id else {
            statusMessage = "邮件已经在 Archive。"
            return
        }

        guard account.useProtocol == .imap else {
            if let index = messages.firstIndex(where: { $0.id == selectedMessageID }) {
                messages[index].mailboxId = archiveMailbox.id
                updateUnreadCount(for: sourceMailbox.id)
                updateUnreadCount(for: archiveMailbox.id)
                self.selectedMessageID = visibleMessages.first?.id
                scheduleSnapshotPersist()
                statusMessage = "邮件已移动到本地 Archive。"
            }
            return
        }

        statusMessage = "正在移动到 \(archiveMailbox.name)..."
        Task { [weak self] in
            guard let self else { return }
            let service = self.service(for: account)
            do {
                try await self.withAccountOperation(accountID: account.id) {
                    try await service.connect(account)
                    try await service.moveMessage(uid: message.uid, from: sourceMailbox, to: archiveMailbox)
                }
                if let index = self.messages.firstIndex(where: { $0.id == selectedMessageID }) {
                    self.messages[index].mailboxId = archiveMailbox.id
                    self.updateUnreadCount(for: sourceMailbox.id)
                    self.updateUnreadCount(for: archiveMailbox.id)
                    self.selectedMessageID = self.visibleMessages.first?.id
                    self.scheduleSnapshotPersist()
                    self.statusMessage = "邮件已移动到 \(archiveMailbox.name)。"
                }
            } catch {
                self.markNeedsReauthIfAuthenticationFailed(accountID: account.id, error: error)
                self.statusMessage = error.localizedDescription
            }
        }
    }

    func deleteSelectedMessage() {
        guard let selectedMessageID,
              let message = messages.first(where: { $0.id == selectedMessageID }),
              let account = accounts.first(where: { $0.id == message.accountId }),
              let sourceMailbox = mailboxes.first(where: { $0.id == message.mailboxId }) else { return }

        if isDraftMessage(message) {
            deleteDraftMessage(message, account: account, mailbox: sourceMailbox)
            return
        }

        guard account.useProtocol == .imap,
              sourceMailbox.role != .trash,
              let trashMailbox = mailboxes.first(where: { $0.accountId == account.id && $0.role == .trash }) else {
            removeMessageLocally(messageID: selectedMessageID, status: "邮件已从本地缓存删除。")
            return
        }

        statusMessage = "正在移动到 \(trashMailbox.name)..."
        Task { [weak self] in
            guard let self else { return }
            let service = self.service(for: account)
            do {
                try await self.withAccountOperation(accountID: account.id) {
                    try await service.connect(account)
                    try await service.moveMessage(uid: message.uid, from: sourceMailbox, to: trashMailbox)
                }
                if let index = self.messages.firstIndex(where: { $0.id == selectedMessageID }) {
                    self.messages[index].mailboxId = trashMailbox.id
                    self.updateUnreadCount(for: sourceMailbox.id)
                    self.updateUnreadCount(for: trashMailbox.id)
                    self.selectedMessageID = self.visibleMessages.first?.id
                    self.persistSnapshot()
                    self.statusMessage = "邮件已移动到 \(trashMailbox.name)。"
                }
            } catch {
                self.markNeedsReauthIfAuthenticationFailed(accountID: account.id, error: error)
                self.statusMessage = error.localizedDescription
            }
        }
    }

    private func deleteDraftMessage(_ message: MailMessage, account: MailAccount, mailbox: Mailbox) {
        delayedDraftSyncTask?.cancel()
        statusMessage = account.useProtocol == .imap ? "正在删除服务器草稿..." : "正在删除本地草稿..."
        Task { [weak self] in
            guard let self else { return }
            do {
                if account.useProtocol == .imap, message.uid > 0 {
                    let service = self.service(for: account)
                    try await self.withAccountOperation(accountID: account.id) {
                        try await service.connect(account)
                        try await service.deleteMessage(uid: message.uid, from: mailbox)
                    }
                }
                self.removeMessageLocally(messageID: message.id, status: "草稿已删除。")
                if self.cachedDraftMessageID == message.id {
                    self.cachedDraftMessageID = nil
                    self.lastSyncedDraft = nil
                    self.releaseAllDraftAttachments()
                    self.isResettingDraft = true
                    self.composeDraft = ComposeDraft()
                    self.isResettingDraft = false
                }
                self.updateUnreadCount(for: mailbox.id)
            } catch {
                self.markNeedsReauthIfAuthenticationFailed(accountID: account.id, error: error)
                self.statusMessage = "草稿删除失败：\(error.localizedDescription)"
            }
        }
    }

    private func removeMessageLocally(messageID: UUID, status: String) {
        messages.removeAll { $0.id == messageID }
        attachments.removeAll { $0.messageId == messageID }
        self.selectedMessageID = visibleMessages.first?.id
        statusMessage = status
        persistSnapshot()
    }

    private var trimmedSignature: String {
        settings.signature.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func bodyWithSignature(_ body: String) -> String {
        let signature = trimmedSignature
        guard !signature.isEmpty else { return body }
        guard !body.contains(signature) else { return body }
        let trimmedBody = body.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmedBody.isEmpty ? signature : "\(body)\n\n\(signature)"
    }

    private func bodyWithSignature(before quote: String) -> String {
        let signature = trimmedSignature
        return signature.isEmpty ? quote : "\(signature)\n\(quote)"
    }

    func startCompose() {
        releaseAllDraftAttachments()
        composeDraft = ComposeDraft(body: bodyWithSignature(""))
    }

    func replyToSelected() {
        guard let message = selectedMessage else { return }
        releaseAllDraftAttachments()
        composeDraft = ComposeDraft(
            to: message.fromAddress,
            cc: "",
            subject: message.subject.hasPrefix("Re:") ? message.subject : "Re: \(message.subject)",
            body: bodyWithSignature(before: "\n\n---- 原邮件 ----\n\(message.bodyPlain ?? message.snippet)"),
            instruction: ""
        )
    }

    func forwardSelected() {
        guard let message = selectedMessage else { return }
        releaseAllDraftAttachments()
        let forwardedAttachmentURLs = attachments(for: message).compactMap { attachment -> URL? in
            guard let localPath = attachment.localPath else { return nil }
            return URL(fileURLWithPath: localPath)
        }
        let normalizedSubject = message.subject.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let subject = normalizedSubject.hasPrefix("fwd:") || normalizedSubject.hasPrefix("fw:")
            ? message.subject
            : "Fwd: \(message.subject)"
        composeDraft = ComposeDraft(
            to: "",
            cc: "",
            subject: subject,
            body: bodyWithSignature(before: """

            ---- 转发邮件 ----
            发件人: \(message.senderDisplayName) <\(message.fromAddress)>
            日期: \(message.date.formatted(date: .abbreviated, time: .shortened))
            主题: \(message.subject)

            \(message.bodyPlain ?? message.snippet)
            """),
            instruction: "",
            attachmentURLs: forwardedAttachmentURLs
        )
    }

    func generateAIReplyDraft() async {
        let replyMessage = selectedMessage.flatMap { message -> MailMessage? in
            let recipient = composeDraft.to.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            let subject = composeDraft.subject.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            let originalSubject = message.subject.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            let looksLikeReply = recipient == message.fromAddress.lowercased()
                || (!originalSubject.isEmpty && subject.contains(originalSubject))
            return looksLikeReply ? message : nil
        }

        if let configurationMessage = chatAIConfigurationMessage() {
            statusMessage = configurationMessage
            return
        }

        if let message = replyMessage {
            let localDraft = localizedFallbackReplyDraft(recipientName: message.fromName)
            let originalQuote = "\n\n---- 原邮件 ----\n\(message.bodyPlain ?? message.snippet)"
            composeDraft.body = ""
            statusMessage = "正在生成 AI 回复草稿..."

            let system = ChatMessage(
                role: "system",
                content: """
                You are an email assistant.
                Generate a polite, appropriate, directly editable reply draft based on the original message.
                Do not send the message and do not add explanations.
                Write the draft in \(settings.interfaceLanguage.aiInstructionName).
                """
            )
            let user = ChatMessage(
                role: "user",
                content: """
                Original subject: \(message.subject)
                Sender: \(message.senderDisplayName) <\(message.fromAddress)>
                Body:
                \(message.bodyPlain ?? message.snippet)
                User instruction: \(composeDraft.instruction.isEmpty ? "None" : composeDraft.instruction)
                """
            )

            do {
                var generated = ""
                for try await token in aiService.chat(model: trimmedSelectedChatModel, messages: [system, user], stream: true) {
                    generated += token
                    composeDraft.body = generated
                }
                let trimmed = generated.trimmingCharacters(in: .whitespacesAndNewlines)
                composeDraft.body = bodyWithSignature(trimmed.isEmpty ? localDraft : trimmed)
                if !composeDraft.body.contains("---- 原邮件 ----") {
                    composeDraft.body += originalQuote
                }
                statusMessage = "AI 回复草稿已生成到撰写窗口。"
            } catch {
                composeDraft.body = bodyWithSignature(localDraft) + originalQuote
                statusMessage = "AI 生成失败，已使用本地草稿：\(error.localizedDescription)"
            }
            return
        }

        statusMessage = "正在生成 AI 邮件草稿..."
        let currentDraft = composeDraft
        let fallback = localizedFallbackNewDraft()
        let system = ChatMessage(
            role: "system",
            content: """
            You are an email assistant.
            Generate a polite, directly editable email draft.
            Do not send the message and do not add explanations.
            Write the draft in \(settings.interfaceLanguage.aiInstructionName).
            """
        )
        let user = ChatMessage(
            role: "user",
            content: """
            To: \(currentDraft.to.isEmpty ? "Not specified" : currentDraft.to)
            Cc: \(currentDraft.cc.isEmpty ? "None" : currentDraft.cc)
            Subject: \(currentDraft.subject.isEmpty ? "Not specified" : currentDraft.subject)
            Existing body:
            \(bodyWithoutSignature(currentDraft.body).isEmpty ? "None" : currentDraft.body)
            User instruction:
            \(currentDraft.instruction.isEmpty ? "Draft a clear, concise email based on the subject and recipients." : currentDraft.instruction)
            """
        )

        do {
            var generated = ""
            for try await token in aiService.chat(model: trimmedSelectedChatModel, messages: [system, user], stream: true) {
                generated += token
                composeDraft.body = generated
            }
            let trimmed = generated.trimmingCharacters(in: .whitespacesAndNewlines)
            composeDraft.body = bodyWithSignature(trimmed.isEmpty ? fallback : trimmed)
            statusMessage = "AI 邮件草稿已生成到撰写窗口。"
        } catch {
            composeDraft.body = bodyWithSignature(fallback)
            statusMessage = "AI 生成失败，已使用本地草稿：\(error.localizedDescription)"
        }
    }

    private func localizedFallbackReplyDraft(recipientName: String) -> String {
        let name = recipientName.trimmingCharacters(in: .whitespacesAndNewlines)
        switch settings.interfaceLanguage {
        case .simplifiedChinese:
            return "你好 \(name)，\n\n谢谢你的邮件。我已收到并会尽快确认相关内容。如有需要补充的信息，我会再回复你。\n\n祝好"
        case .traditionalChinese:
            return "你好 \(name)，\n\n謝謝你的郵件。我已收到並會盡快確認相關內容。如有需要補充的資訊，我會再回覆你。\n\n祝好"
        case .japanese:
            return "\(name) 様\n\nご連絡ありがとうございます。内容を確認し、必要があれば改めてご返信いたします。\n\nよろしくお願いいたします。"
        case .korean:
            return "\(name) 님,\n\n메일 감사합니다. 내용을 확인했으며 필요한 사항이 있으면 다시 답변드리겠습니다.\n\n감사합니다."
        case .english:
            return "Hi \(name),\n\nThank you for your email. I have received it and will review the details. I will follow up if anything else is needed.\n\nBest regards"
        case .french:
            return "Bonjour \(name),\n\nMerci pour votre message. Je l'ai bien reçu et vais vérifier les éléments concernés. Je reviendrai vers vous si des informations complémentaires sont nécessaires.\n\nCordialement"
        case .russian:
            return "Здравствуйте, \(name),\n\nСпасибо за письмо. Я получил его и проверю детали. Если потребуется дополнительная информация, я отвечу отдельно.\n\nС уважением"
        case .swedish:
            return "Hej \(name),\n\nTack för ditt mejl. Jag har tagit emot det och går igenom detaljerna. Jag återkommer om något behöver kompletteras.\n\nVänliga hälsningar"
        case .ukrainian:
            return "Вітаю, \(name),\n\nДякую за ваш лист. Я отримав його й перевірю деталі. Якщо знадобиться додаткова інформація, я відповім окремо.\n\nЗ повагою"
        case .finnish:
            return "Hei \(name),\n\nKiitos viestistäsi. Olen vastaanottanut sen ja tarkistan tiedot. Palaan asiaan, jos tarvitsen lisätietoja.\n\nYstävällisin terveisin"
        }
    }

    private func localizedFallbackNewDraft() -> String {
        switch settings.interfaceLanguage {
        case .simplifiedChinese:
            return "你好，\n\n请根据你的具体需求补充邮件内容。\n"
        case .traditionalChinese:
            return "你好，\n\n請根據你的具體需求補充郵件內容。\n"
        case .japanese:
            return "こんにちは。\n\n必要な内容をここに追記してください。\n"
        case .korean:
            return "안녕하세요.\n\n필요한 내용을 여기에 추가해 주세요.\n"
        case .english:
            return "Hello,\n\nPlease add the details you want to include in this message.\n"
        case .french:
            return "Bonjour,\n\nVeuillez ajouter les détails à inclure dans ce message.\n"
        case .russian:
            return "Здравствуйте,\n\nДобавьте детали, которые нужно включить в это письмо.\n"
        case .swedish:
            return "Hej,\n\nLägg till de detaljer du vill ha med i meddelandet.\n"
        case .ukrainian:
            return "Вітаю,\n\nДодайте деталі, які потрібно включити до цього листа.\n"
        case .finnish:
            return "Hei,\n\nLisää tähän viestiin tarvittavat tiedot.\n"
        }
    }

    func sendDraft() {
        delayedDraftSyncTask?.cancel()
        let outgoing = draftOutgoingMessage(from: composeDraft)
        guard let draftAccount = selectedAccount else {
            statusMessage = "请先选择发件账户。"
            return
        }
        let sendingAccount = composeDraft.sendingAccountID.flatMap { sendingID in
            accounts.first { $0.id == sendingID }
        } ?? draftAccount
        let sentMailbox = ensureSentMailbox(for: sendingAccount)
        let syncedDraftMessage = cachedDraftMessageID.flatMap { id in
            messages.first { $0.id == id }
        }
        let syncedDraftMailbox = syncedDraftMessage.flatMap { draftMessage in
            mailboxes.first { $0.id == draftMessage.mailboxId }
        }
        statusMessage = "正在通过 \(sendingAccount.emailAddress) SMTP 发送，附件 \(outgoing.attachmentURLs.count) 个..."
        Task {
            do {
                try await withAccountOperation(accountID: sendingAccount.id) {
                    let service = service(for: sendingAccount)
                    try await service.connect(sendingAccount)
                    try await service.sendMessage(outgoing, appendTo: sentMailbox)
                }
                if draftAccount.useProtocol == .imap,
                   let syncedDraftMessage,
                   let syncedDraftMailbox,
                   syncedDraftMessage.uid > 0 {
                    try? await withAccountOperation(accountID: draftAccount.id) {
                        let draftService = service(for: draftAccount)
                        try await draftService.connect(draftAccount)
                        try await draftService.deleteMessage(uid: syncedDraftMessage.uid, from: syncedDraftMailbox)
                    }
                }
                removeCachedDraftMessage()
                cacheSentMessage(outgoing, account: sendingAccount, mailbox: sentMailbox)
                releaseAllDraftAttachments()
                isResettingDraft = true
                composeDraft = ComposeDraft()
                isResettingDraft = false
                statusMessage = "邮件已发送，并已保存到 Sent。"
            } catch {
                markNeedsReauthIfAuthenticationFailed(accountID: sendingAccount.id, error: error)
                statusMessage = error.localizedDescription
            }
        }
    }

    private func scheduleDraftSync(delayNanoseconds: UInt64 = 1_500_000_000) {
        guard !isResettingDraft else { return }
        guard draftHasSyncableContent(composeDraft) else {
            delayedDraftSyncTask?.cancel()
            return
        }
        guard composeDraft != lastSyncedDraft else { return }

        delayedDraftSyncTask?.cancel()
        delayedDraftSyncTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: delayNanoseconds)
            guard !Task.isCancelled else { return }
            await self?.synchronizeDraftNow()
        }
    }

    func synchronizeDraftImmediately() async {
        delayedDraftSyncTask?.cancel()
        await synchronizeDraftNow()
    }

    private func synchronizeDraftNow() async {
        guard let account = selectedAccount else { return }
        let draft = composeDraft
        guard draftHasSyncableContent(draft), draft != lastSyncedDraft else { return }
        let draftsMailbox = ensureDraftsMailbox(for: account)
        let previousDraftMessageID = cachedDraftMessageID
        let previousRemoteUID = previousDraftMessageID.flatMap { id in
            messages.first { $0.id == id }?.uid
        }
        cacheDraftMessage(draft, account: account, mailbox: draftsMailbox)
        let currentDraftMessageID = cachedDraftMessageID

        guard account.useProtocol == .imap else {
            lastSyncedDraft = draft
            statusMessage = "草稿已保存到本地 Drafts。"
            return
        }

        do {
            var appendedUID: Int64?
            try await withAccountOperation(accountID: account.id) {
                let service = service(for: account)
                try await service.connect(account)
                appendedUID = try await service.saveDraft(draftOutgoingMessage(from: draft), to: draftsMailbox)
                if let previousRemoteUID,
                   let appendedUID,
                   previousRemoteUID > 0,
                   previousRemoteUID != appendedUID {
                    try await service.deleteMessage(uid: previousRemoteUID, from: draftsMailbox)
                }
            }
            if let currentDraftMessageID,
               let appendedUID,
               let index = messages.firstIndex(where: { $0.id == currentDraftMessageID }) {
                messages[index].uid = appendedUID
                scheduleSnapshotPersist()
            }
            lastSyncedDraft = draft
            statusMessage = "草稿已同步到 Drafts。"
        } catch {
            markNeedsReauthIfAuthenticationFailed(accountID: account.id, error: error)
            statusMessage = "草稿同步失败：\(error.localizedDescription)"
        }
    }

    private func draftHasSyncableContent(_ draft: ComposeDraft) -> Bool {
        !draft.to.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        || !draft.cc.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        || !draft.subject.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        || !bodyWithoutSignature(draft.body).isEmpty
        || !draft.instruction.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        || !draft.attachmentURLs.isEmpty
    }

    private func bodyWithoutSignature(_ body: String) -> String {
        let signature = trimmedSignature
        var trimmed = body.trimmingCharacters(in: .whitespacesAndNewlines)
        if !signature.isEmpty, trimmed == signature {
            trimmed = ""
        }
        return trimmed
    }

    private func draftOutgoingMessage(from draft: ComposeDraft) -> OutgoingMessage {
        OutgoingMessage(
            to: splitAddresses(draft.to),
            cc: splitAddresses(draft.cc),
            bcc: [],
            subject: draft.subject,
            bodyPlain: bodyWithSignature(draft.body),
            attachmentURLs: draft.attachmentURLs
        )
    }

    private func ensureDraftsMailbox(for account: MailAccount) -> Mailbox {
        if let mailbox = mailboxes.first(where: { $0.accountId == account.id && $0.role == .drafts }) {
            return mailbox
        }
        let mailbox = Mailbox(id: UUID(), accountId: account.id, name: "Drafts", role: .drafts, uidValidity: 1, unreadCount: 0)
        mailboxes.append(mailbox)
        return mailbox
    }

    private func ensureArchiveMailbox(for account: MailAccount) -> Mailbox {
        if let mailbox = mailboxes.first(where: { $0.accountId == account.id && $0.role == .archive }) {
            return mailbox
        }
        let mailbox = Mailbox(id: UUID(), accountId: account.id, name: "Archive", role: .archive, uidValidity: 1, unreadCount: 0)
        mailboxes.append(mailbox)
        return mailbox
    }

    private func cacheDraftMessage(_ draft: ComposeDraft, account: MailAccount, mailbox: Mailbox) {
        let messageID = cachedDraftMessageID ?? UUID()
        cachedDraftMessageID = messageID
        let now = Date()
        let outgoing = draftOutgoingMessage(from: draft)
        let localUID = messages.first(where: { $0.id == messageID })?.uid ?? 0
        var flags: MessageFlags = [.draft]
        flags.insert(.seen)
        let draftAttachments = draft.attachmentURLs.map { url in
            MailAttachment(
                id: UUID(),
                messageId: messageID,
                filename: url.lastPathComponent,
                mimeType: mimeType(for: url.lastPathComponent),
                sizeBytes: fileSize(for: url),
                localPath: url.path,
                contentId: nil
            )
        }
        let message = MailMessage(
            id: messageID,
            accountId: account.id,
            mailboxId: mailbox.id,
            uid: localUID,
            messageId: "<\(messageID.uuidString.lowercased())@mymail.draft>",
            subject: draft.subject.isEmpty ? "(无主题)" : draft.subject,
            fromAddress: account.emailAddress,
            fromName: account.displayName,
            toRecipientsJSON: jsonArray(outgoing.to),
            ccRecipientsJSON: jsonArray(outgoing.cc),
            bccRecipientsJSON: "[]",
            date: now,
            receivedDate: now,
            snippet: String(outgoing.bodyPlain.prefix(200)),
            bodyPlain: outgoing.bodyPlain,
            bodyHTML: nil,
            flags: flags,
            hasAttachments: !draftAttachments.isEmpty,
            isBodyDownloaded: true,
            embeddingState: .pending
        )

        if let index = messages.firstIndex(where: { $0.id == messageID }) {
            messages[index] = message
        } else {
            messages.append(message)
        }
        attachments.removeAll { $0.messageId == messageID }
        attachments.append(contentsOf: draftAttachments)
        normalizeMessageOrder()
        scheduleSnapshotPersist()
    }

    private func removeCachedDraftMessage() {
        guard let cachedDraftMessageID else { return }
        messages.removeAll { $0.id == cachedDraftMessageID }
        attachments.removeAll { $0.messageId == cachedDraftMessageID }
        self.cachedDraftMessageID = nil
        lastSyncedDraft = nil
        scheduleSnapshotPersist()
    }

    private func ensureSentMailbox(for account: MailAccount) -> Mailbox {
        if let mailbox = mailboxes.first(where: { $0.accountId == account.id && $0.role == .sent }) {
            return mailbox
        }
        let mailbox = Mailbox(id: UUID(), accountId: account.id, name: "Sent", role: .sent, uidValidity: 1, unreadCount: 0)
        mailboxes.append(mailbox)
        return mailbox
    }

    private func releaseDraftAttachment(_ url: URL) {
        if draftAttachmentAccess.removeValue(forKey: url) == true {
            url.stopAccessingSecurityScopedResource()
        }
    }

    private func releaseAllDraftAttachments() {
        for (url, didStartAccess) in draftAttachmentAccess where didStartAccess {
            url.stopAccessingSecurityScopedResource()
        }
        draftAttachmentAccess.removeAll()
    }

    private func cacheSentMessage(_ outgoing: OutgoingMessage, account: MailAccount, mailbox: Mailbox) {
        var flags = MessageFlags()
        flags.insert(.seen)
        let messageID = UUID()
        let sentUID = (messages.filter { $0.mailboxId == mailbox.id }.map(\.uid).max() ?? 0) + 1
        let sentDate = Date()
        let sentAttachments = outgoing.attachmentURLs.map { url in
            MailAttachment(
                id: UUID(),
                messageId: messageID,
                filename: url.lastPathComponent,
                mimeType: mimeType(for: url.lastPathComponent),
                sizeBytes: fileSize(for: url),
                localPath: url.path,
                contentId: nil
            )
        }
        let message = MailMessage(
            id: messageID,
            accountId: account.id,
            mailboxId: mailbox.id,
            uid: sentUID,
            messageId: "<\(messageID.uuidString.lowercased())@mymail.local>",
            subject: outgoing.subject.isEmpty ? "(无主题)" : outgoing.subject,
            fromAddress: account.emailAddress,
            fromName: account.displayName,
            toRecipientsJSON: jsonArray(outgoing.to),
            ccRecipientsJSON: jsonArray(outgoing.cc),
            bccRecipientsJSON: jsonArray(outgoing.bcc),
            date: sentDate,
            receivedDate: sentDate,
            snippet: String(outgoing.bodyPlain.prefix(200)),
            bodyPlain: outgoing.bodyPlain,
            bodyHTML: nil,
            flags: flags,
            hasAttachments: !sentAttachments.isEmpty,
            isBodyDownloaded: true,
            embeddingState: .pending
        )
        messages.append(message)
        normalizeMessageOrder()
        attachments.append(contentsOf: sentAttachments)
        selectedMailboxID = mailbox.id
        selectedMessageID = message.id
        persistSnapshot()
    }

    private func jsonArray(_ values: [String]) -> String {
        guard let data = try? JSONEncoder().encode(values), let string = String(data: data, encoding: .utf8) else { return "[]" }
        return string
    }

    private func decodeAddressList(_ json: String) -> [String] {
        guard let data = json.data(using: .utf8),
              let values = try? JSONDecoder().decode([String].self, from: data) else {
            return []
        }
        return values
    }

    private func fileSize(for url: URL) -> Int64 {
        let didStartAccess = url.startAccessingSecurityScopedResource()
        defer {
            if didStartAccess {
                url.stopAccessingSecurityScopedResource()
            }
        }
        let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.int64Value
        return size ?? 0
    }

    private func mimeType(for filename: String) -> String {
        switch (filename as NSString).pathExtension.lowercased() {
        case "pdf": return "application/pdf"
        case "png": return "image/png"
        case "jpg", "jpeg": return "image/jpeg"
        case "gif": return "image/gif"
        case "txt": return "text/plain; charset=utf-8"
        case "html", "htm": return "text/html; charset=utf-8"
        case "doc": return "application/msword"
        case "docx": return "application/vnd.openxmlformats-officedocument.wordprocessingml.document"
        case "xls": return "application/vnd.ms-excel"
        case "xlsx": return "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet"
        case "zip": return "application/zip"
        default: return "application/octet-stream"
        }
    }

    func runAIQuestion() async {
        let question = aiQuestion.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !question.isEmpty else { return }
        if let configurationMessage = chatAIConfigurationMessage() {
            statusMessage = configurationMessage
            aiAnswer = SearchAnswer(question: question, answer: configurationMessage, citations: [])
            return
        }
        let vectorizedMessages = messages.filter { $0.embeddingState == .done }
        guard !vectorizedMessages.isEmpty else {
            let message = SearchService.missingVectorIndexMessage(language: settings.interfaceLanguage)
            statusMessage = message
            aiAnswer = SearchAnswer(question: question, answer: message, citations: [])
            return
        }

        isSearchingAI = true
        aiAnswer = nil
        defer { isSearchingAI = false }

        do {
            aiAnswer = try await makeSearchService().answer(
                question: question,
                messages: vectorizedMessages,
                attachments: attachments,
                chatModel: trimmedSelectedChatModel,
                responseLanguage: settings.interfaceLanguage,
                onPartial: { [weak self] partial in
                    self?.aiAnswer = partial
                }
            )
        } catch {
            aiAnswer = SearchAnswer(question: question, answer: error.localizedDescription, citations: [])
        }
    }

    private func makeSearchService() -> SearchService {
        SearchService(embeddingService: resolvedEmbeddingService(), vectorStore: vectorStore, aiService: aiService)
    }

    private func resolvedEmbeddingService() -> EmbeddingService {
        injectedEmbeddingService ?? localEmbeddingService
    }

    



    private func resolvedPreset(
        provider: MailProvider,
        useProtocol: MailProtocolChoice,
        customIMAP: ServerEndpoint?,
        customSMTP: ServerEndpoint?,
        customPOP3: ServerEndpoint?
    ) throws -> ProviderPreset {
        if provider != .custom && provider != .generic && provider != .fudan {
            let preset = ProviderPreset.preset(for: provider)
            if useProtocol == .pop3 && preset.pop3 == nil {
                throw MailServiceError.malformedServerResponse("该服务商不支持 POP3，请改用 IMAP。")
            }
            return preset
        }

        guard let smtp = sanitizedEndpoint(customSMTP) else {
            throw MailServiceError.malformedServerResponse("请填写 IMAP 与 SMTP 服务器。")
        }
        let imap = sanitizedEndpoint(customIMAP)
        let pop3 = sanitizedEndpoint(customPOP3)
        if useProtocol == .imap && imap == nil {
            throw MailServiceError.malformedServerResponse("请填写 IMAP 与 SMTP 服务器。")
        }
        if useProtocol == .pop3 && pop3 == nil {
            throw MailServiceError.malformedServerResponse("选择 POP3 时请填写 POP3 服务器。")
        }
        let resolvedIMAP = imap ?? ServerEndpoint(host: "", port: 993, tlsMode: "SSL")
        try validateKnownEndpointCombination(useProtocol: useProtocol, imap: resolvedIMAP, smtp: smtp, pop3: pop3)
        return ProviderPreset(
            provider: provider,
            imap: resolvedIMAP,
            smtp: smtp,
            pop3: pop3,
            appPasswordHelpURL: nil,
            inlineNote: ProviderPreset.preset(for: provider).inlineNote
        )
    }

    private func sanitizedEndpoint(_ endpoint: ServerEndpoint?) -> ServerEndpoint? {
        guard let endpoint else { return nil }
        let host = endpoint.host.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !host.isEmpty, endpoint.port > 0 else { return nil }
        return ServerEndpoint(host: host, port: endpoint.port, tlsMode: endpoint.normalizedTLSMode)
    }

    private func validateKnownEndpointCombination(
        useProtocol: MailProtocolChoice,
        imap: ServerEndpoint,
        smtp: ServerEndpoint,
        pop3: ServerEndpoint?
    ) throws {
        let hosts = [imap.host, smtp.host, pop3?.host]
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
        guard hosts.contains("mail.fudan.edu.cn") else { return }

        if smtp.tlsMode != "SSL" || smtp.port != 465 {
            throw MailServiceError.malformedServerResponse("复旦 SMTP 请使用 mail.fudan.edu.cn:465 SSL。")
        }
        switch useProtocol {
        case .imap:
            if imap.tlsMode != "SSL" || imap.port != 993 {
                throw MailServiceError.malformedServerResponse("复旦 IMAP 请使用 mail.fudan.edu.cn:993 SSL。")
            }
        case .pop3:
            if pop3?.tlsMode != "SSL" || pop3?.port != 995 {
                throw MailServiceError.malformedServerResponse("复旦 POP3 请使用 mail.fudan.edu.cn:995 SSL。")
            }
        }
    }

    func saveAPIKey(_ value: String) {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            statusMessage = localized(.apiKeyEnterValue)
            return
        }

        do {
            try secretStore.save(trimmed, account: "zenmux.apikey")
            isAPIKeyVisible = false
            apiKeyTestState = .idle
            apiKeyTestDetail = nil
            refreshAPIKeyMask()
            statusMessage = localized(.apiKeySavedToKeychain)
        } catch {
            statusMessage = error.localizedDescription
        }
    }

    func refreshAPIKeyMask() {
        let value = try? secretStore.read(account: "zenmux.apikey")
        guard let value, !value.isEmpty else {
            apiKeyMask = localized(.apiKeyNotSaved)
            isAPIKeyVisible = false
            return
        }
        apiKeyMask = isAPIKeyVisible ? value : SecretMaskFormatter.maskAPIKey(value)
    }

    func toggleAPIKeyVisibility() {
        guard hasSavedAPIKey else { return }
        isAPIKeyVisible.toggle()
        refreshAPIKeyMask()
    }

    func addChatModel(_ modelName: String) {
        let trimmed = modelName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        settings.chatModels.removeAll { $0.caseInsensitiveCompare(trimmed) == .orderedSame }
        settings.chatModels.append(trimmed)
        settings.selectedChatModel = trimmed
    }

    func removeSelectedChatModel() {
        guard settings.chatModels.count > 1 else { return }
        let removed = settings.selectedChatModel
        settings.chatModels.removeAll { $0 == removed }
        if settings.chatModels.isEmpty {
            settings = AppSettings()
        } else if !settings.chatModels.contains(settings.selectedChatModel) {
            settings.selectedChatModel = settings.chatModels.first ?? AppSettings().selectedChatModel
        }
    }

    func setUseLocalEmbedding(_ enabled: Bool) {
        settings.useLocalEmbedding = true
        settings.embeddingModel = ""
        settings.vectorizationConsentAccepted = true
        showsVectorizationPrivacyPrompt = false
        if !enabled {
            statusMessage = localized(.vectorizationEnabledLocal)
        }
    }

    func setVectorizationEnabled(_ enabled: Bool) {
        settings.useLocalEmbedding = true
        settings.embeddingModel = ""
        settings.vectorizationConsentAccepted = true
        showsVectorizationPrivacyPrompt = false

        if !enabled {
            settings.vectorizationEnabled = false
            statusMessage = localized(.vectorizationDisabledStatus)
            return
        }

        settings.vectorizationEnabled = true
        statusMessage = localized(.vectorizationEnabledLocal)
        Task { await initializeVectorization() }
    }

    func startOrRebuildVectorization() {
        guard vectorizationProgress?.isActive != true else { return }
        settings.useLocalEmbedding = true
        settings.embeddingModel = ""
        settings.vectorizationConsentAccepted = true
        settings.vectorizationEnabled = true
        showsVectorizationPrivacyPrompt = false
        statusMessage = localized(.vectorizationRebuildingLocal)
        Task { await initializeVectorization() }
    }

    func acceptRemoteVectorization() {
        useLocalVectorization()
    }

    func useLocalVectorization() {
        settings.useLocalEmbedding = true
        settings.embeddingModel = ""
        settings.vectorizationConsentAccepted = true
        settings.vectorizationEnabled = true
        showsVectorizationPrivacyPrompt = false
        statusMessage = localized(.vectorizationEnabledLocal)
        Task { await initializeVectorization() }
    }

    func cancelVectorizationEnablement() {
        settings.vectorizationEnabled = false
        showsVectorizationPrivacyPrompt = false
        statusMessage = localized(.vectorizationCancelled)
    }

    func testAPIKey() async {
        guard !isTestingAPIKey else { return }
        if !hasSavedAPIKey {
            apiKeyTestDetail = nil
            apiKeyTestState = .missing
            let message = apiKeyTestFeedback
            statusMessage = message
        } else if trimmedSelectedChatModel.isEmpty {
            apiKeyTestDetail = localized(.chatModelMissing)
            apiKeyTestState = .failure
            let message = apiKeyTestFeedback
            statusMessage = message
        } else {
            isTestingAPIKey = true
            apiKeyTestDetail = nil
            apiKeyTestState = .testing
            let testingMessage = apiKeyTestFeedback
            statusMessage = testingMessage
            defer { isTestingAPIKey = false }
            do {
                var received = ""
                let messages = [
                    ChatMessage(role: "system", content: "你只用于连通性测试。"),
                    ChatMessage(role: "user", content: "请回复 OK")
                ]
                for try await token in aiService.chat(model: trimmedSelectedChatModel, messages: messages, stream: false) {
                    received += token
                }
                let trimmed = received.trimmingCharacters(in: .whitespacesAndNewlines)
                apiKeyTestDetail = trimmed.isEmpty ? nil : trimmed
                apiKeyTestState = .success
                statusMessage = apiKeyTestFeedback
            } catch {
                apiKeyTestDetail = error.localizedDescription
                apiKeyTestState = .failure
                statusMessage = apiKeyTestFeedback
            }
        }
    }

    @discardableResult
    func testAccountConnection(
        provider: MailProvider,
        email: String,
        password: String,
        useProtocol: MailProtocolChoice = .imap,
        customIMAP: ServerEndpoint? = nil,
        customSMTP: ServerEndpoint? = nil,
        customPOP3: ServerEndpoint? = nil
    ) async -> Bool {
        let trimmedEmail = email.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedPassword = normalizedAppPassword(password, provider: provider)
        guard !trimmedEmail.isEmpty, !normalizedPassword.isEmpty else {
            statusMessage = provider == .gmail ? localized(.gmailAppPasswordRequired) : "请填写邮箱地址和客户端专用密码。"
            return false
        }
        do {
            let preset = try resolvedPreset(provider: provider, useProtocol: useProtocol, customIMAP: customIMAP, customSMTP: customSMTP, customPOP3: customPOP3)
            let account = MailAccount(
                id: UUID(),
                displayName: trimmedEmail,
                emailAddress: trimmedEmail,
                provider: provider,
                authType: .appPassword,
                imap: preset.imap,
                smtp: preset.smtp,
                pop3: preset.pop3,
                useProtocol: useProtocol,
                oauthRefreshTokenRef: nil,
                createdAt: Date(),
                needsReauth: false
            )
            let service = mailServiceFactory()
            statusMessage = "正在测试 \(useProtocol.rawValue.uppercased()) 收信..."
            try await service.testIncomingConnection(account, password: normalizedPassword)
            statusMessage = "收信测试通过，正在测试 SMTP 发信..."
            do {
                try await service.testOutgoingConnection(account, password: normalizedPassword)
                statusMessage = "连接测试通过。"
                return true
            } catch {
                if provider == .gmail {
                    statusMessage = "Gmail 收信测试通过；SMTP 发信测试失败：\(error.localizedDescription)。可以先保存账户用于收信；若要发送邮件，请确认当前网络允许连接 smtp.gmail.com:587 STARTTLS 或 465 SSL/TLS。"
                    return true
                }
                throw error
            }
        } catch {
            if provider == .gmail {
                statusMessage = localized(.gmailConnectionFailedHint, error.localizedDescription)
            } else {
                statusMessage = error.localizedDescription
            }
            return false
        }
    }

    func addAccount(
        provider: MailProvider,
        email: String,
        password: String,
        useProtocol: MailProtocolChoice = .imap,
        customIMAP: ServerEndpoint? = nil,
        customSMTP: ServerEndpoint? = nil,
        customPOP3: ServerEndpoint? = nil
    ) {
        do {
            let preset = try resolvedPreset(provider: provider, useProtocol: useProtocol, customIMAP: customIMAP, customSMTP: customSMTP, customPOP3: customPOP3)
            let trimmedEmail = email.trimmingCharacters(in: .whitespacesAndNewlines)
            let normalizedPassword = normalizedAppPassword(password, provider: provider)
            guard !trimmedEmail.isEmpty, !normalizedPassword.isEmpty else {
                statusMessage = provider == .gmail ? localized(.gmailAppPasswordRequired) : "请填写邮箱地址和客户端专用密码。"
                return
            }
            let account = MailAccount(
                id: UUID(),
                displayName: trimmedEmail,
                emailAddress: trimmedEmail,
                provider: provider,
                authType: .appPassword,
                imap: preset.imap,
                smtp: preset.smtp,
                pop3: preset.pop3,
                useProtocol: useProtocol,
                oauthRefreshTokenRef: nil,
                createdAt: Date(),
                needsReauth: false
            )
            try secretStore.save(normalizedPassword, account: "account.\(account.id.uuidString).password")
            accounts.append(account)
            if useProtocol == .pop3 {
                mailboxes.append(Mailbox(id: UUID(), accountId: account.id, name: "INBOX", role: .inbox, uidValidity: 1, unreadCount: 0))
            } else {
                mailboxes.append(contentsOf: Mailbox.demoSet(accountId: account.id))
            }
            selectedAccountID = account.id
            selectedMailboxID = visibleMailboxes.first?.id
            statusMessage = "账户已保存，密码仅写入 Keychain。"
            persistSnapshot()
        } catch {
            statusMessage = error.localizedDescription
        }
    }

    func addOAuthAccount(
        provider: MailProvider,
        email: String,
        oauthToken: String,
        useProtocol: MailProtocolChoice = .imap
    ) {
        do {
            let preset = ProviderPreset.preset(for: provider)
            guard preset.supportsOAuth2 else {
                statusMessage = "\(provider.title) 暂未提供 OAuth2 登录路径。"
                return
            }
            let trimmedToken = oauthToken.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !email.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, !trimmedToken.isEmpty else {
                statusMessage = "请填写邮箱地址和 OAuth2 token。"
                return
            }
            let tokenSet = OAuthTokenSet(accessToken: trimmedToken, refreshToken: nil, tokenType: "Bearer", scope: nil, expiresAt: nil)
            try saveOAuthAccount(provider: provider, email: email, tokenSet: tokenSet, useProtocol: useProtocol)
        } catch {
            statusMessage = error.localizedDescription
        }
    }

    func startOAuthLogin(
        provider: MailProvider,
        email: String,
        clientID: String,
        useProtocol: MailProtocolChoice = .imap
    ) -> URL? {
        do {
            let preset = ProviderPreset.preset(for: provider)
            guard preset.supportsOAuth2 else {
                statusMessage = "\(provider.title) 暂未提供 OAuth2 登录路径。"
                return nil
            }
            let trimmedEmail = email.trimmingCharacters(in: .whitespacesAndNewlines)
            let trimmedClientID = clientID.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmedEmail.isEmpty, !trimmedClientID.isEmpty else {
                statusMessage = "请填写邮箱地址和 OAuth Client ID。"
                return nil
            }
            if provider == .gmail && !trimmedClientID.lowercased().hasSuffix(".apps.googleusercontent.com") {
                statusMessage = "Google OAuth Client ID 无效：请填写 Google Cloud 中 Desktop app / Installed app 类型的 Client ID，通常以 .apps.googleusercontent.com 结尾；不要填写邮箱、项目名称或 Client Secret。"
                return nil
            }
            guard useProtocol == .imap || preset.pop3 != nil else {
                statusMessage = "\(provider.title) 不支持 POP3。"
                return nil
            }

            pendingOAuthLogin?.loopbackServer?.stop()
            let state = UUID().uuidString
            let pkce = oauth2Service.makePKCEPair()
            let loopbackServer = try OAuthLoopbackServer(path: "/oauth/\(provider.rawValue)") { [weak self] url in
                Task { @MainActor in
                    await self?.handleOAuthCallback(url)
                }
            }
            loopbackServer.start()
            let redirectURI = loopbackServer.redirectURI
            let url = try oauth2Service.makeAuthorizationURL(
                provider: provider,
                clientID: trimmedClientID,
                redirectURI: redirectURI,
                state: state,
                codeChallenge: pkce.challenge
            )
            pendingOAuthLogin = PendingOAuthLogin(
                provider: provider,
                email: trimmedEmail,
                useProtocol: useProtocol,
                clientID: trimmedClientID,
                redirectURI: redirectURI,
                state: state,
                codeVerifier: pkce.verifier,
                loopbackServer: loopbackServer
            )
            statusMessage = "已打开 \(provider.title) OAuth 登录，请在浏览器完成授权。"
            return url
        } catch {
            statusMessage = error.localizedDescription
            return nil
        }
    }

    func handleOAuthCallback(_ url: URL) async {
        guard isSupportedOAuthCallback(url) else { return }
        guard let pendingOAuthLogin else {
            statusMessage = "没有正在进行的 OAuth 登录。"
            return
        }
        let callbackProvider = oauthCallbackProvider(from: url)
        guard callbackProvider == pendingOAuthLogin.provider else {
            statusMessage = "OAuth 回调服务商不匹配。"
            pendingOAuthLogin.loopbackServer?.stop()
            self.pendingOAuthLogin = nil
            return
        }
        let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        let items = components?.queryItems ?? []
        if let error = items.first(where: { $0.name == "error" })?.value {
            statusMessage = "OAuth 登录失败：\(error)"
            pendingOAuthLogin.loopbackServer?.stop()
            self.pendingOAuthLogin = nil
            return
        }
        guard items.first(where: { $0.name == "state" })?.value == pendingOAuthLogin.state else {
            statusMessage = "OAuth state 校验失败，请重新登录。"
            pendingOAuthLogin.loopbackServer?.stop()
            self.pendingOAuthLogin = nil
            return
        }
        guard let code = items.first(where: { $0.name == "code" })?.value, !code.isEmpty else {
            statusMessage = "OAuth 回调缺少授权码。"
            pendingOAuthLogin.loopbackServer?.stop()
            self.pendingOAuthLogin = nil
            return
        }

        do {
            let tokenSet = try await oauth2Service.exchangeCode(
                provider: pendingOAuthLogin.provider,
                clientID: pendingOAuthLogin.clientID,
                code: code,
                redirectURI: pendingOAuthLogin.redirectURI,
                codeVerifier: pendingOAuthLogin.codeVerifier
            )
            try saveOAuthAccount(
                provider: pendingOAuthLogin.provider,
                email: pendingOAuthLogin.email,
                tokenSet: tokenSet,
                useProtocol: pendingOAuthLogin.useProtocol
            )
            pendingOAuthLogin.loopbackServer?.stop()
            self.pendingOAuthLogin = nil
            statusMessage = "OAuth2 登录完成，凭据仅写入 Keychain。"
        } catch {
            statusMessage = error.localizedDescription
        }
    }

    private func isSupportedOAuthCallback(_ url: URL) -> Bool {
        if url.scheme == "mymail", url.host == "oauth" {
            return true
        }
        return url.scheme == "http" && (url.host == "127.0.0.1" || url.host == "localhost")
    }

    private func oauthCallbackProvider(from url: URL) -> MailProvider? {
        if url.scheme == "mymail", url.host == "oauth" {
            return url.pathComponents.dropFirst().first.flatMap(MailProvider.init(rawValue:))
        }
        guard url.scheme == "http" else { return nil }
        return url.pathComponents.dropFirst().dropFirst().first.flatMap(MailProvider.init(rawValue:))
    }

    private func saveOAuthAccount(
        provider: MailProvider,
        email: String,
        tokenSet: OAuthTokenSet,
        useProtocol: MailProtocolChoice
    ) throws {
        let preset = ProviderPreset.preset(for: provider)
        guard preset.supportsOAuth2 else {
            throw OAuth2Error.unsupportedProvider
        }
        let trimmedEmail = email.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedEmail.isEmpty else {
            throw MailServiceError.malformedServerResponse("请填写邮箱地址。")
        }
        guard useProtocol == .imap || preset.pop3 != nil else {
            throw MailServiceError.malformedServerResponse("\(provider.title) 不支持 POP3。")
        }

        let accountID = UUID()
        let tokenRef = "account.\(accountID.uuidString).oauth"
        let account = MailAccount(
            id: accountID,
            displayName: trimmedEmail,
            emailAddress: trimmedEmail,
            provider: provider,
            authType: .oauth2,
            imap: preset.imap,
            smtp: preset.smtp,
            pop3: preset.pop3,
            useProtocol: useProtocol,
            oauthRefreshTokenRef: tokenRef,
            createdAt: Date(),
            needsReauth: false
        )
        try secretStore.save(tokenSet.storageString, account: tokenRef)
        accounts.append(account)
        if useProtocol == .pop3 {
            mailboxes.append(Mailbox(id: UUID(), accountId: account.id, name: "INBOX", role: .inbox, uidValidity: 1, unreadCount: 0))
        } else {
            mailboxes.append(contentsOf: Mailbox.demoSet(accountId: account.id))
        }
        selectedAccountID = account.id
        selectedMailboxID = visibleMailboxes.first?.id
        persistSnapshot()
    }

    func updateAccountPassword(accountID: UUID, password: String) {
        guard let index = accounts.firstIndex(where: { $0.id == accountID }) else {
            statusMessage = "未找到账户。"
            return
        }
        let trimmedPassword = normalizedAppPassword(password, provider: accounts[index].provider)
        guard !trimmedPassword.isEmpty else {
            statusMessage = "请填写新的客户端专用密码。"
            return
        }
        do {
            try secretStore.save(trimmedPassword, account: "account.\(accountID.uuidString).password")
            accounts[index].needsReauth = false
            statusMessage = "账户密码已更新，凭据仅写入 Keychain。"
            persistSnapshot()
        } catch {
            statusMessage = error.localizedDescription
        }
    }

    private func persistSnapshot() {
        guard let mailStore else { return }
        do {
            try mailStore.saveSnapshot(currentSnapshot())
        } catch {
            statusMessage = "本地缓存保存失败：\(error.localizedDescription)"
        }
    }

    private func scheduleSnapshotPersist(delayNanoseconds: UInt64 = 400_000_000) {
        guard mailStore != nil else { return }
        delayedSnapshotPersistTask?.cancel()
        delayedSnapshotPersistTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: delayNanoseconds)
            guard !Task.isCancelled else { return }
            self?.persistSnapshot()
        }
    }

    private func persistSettings() {
        settingsStore.saveSettings(settings)
    }

    private func currentSnapshot() -> MailStoreSnapshot {
        MailStoreSnapshot(accounts: accounts, mailboxes: mailboxes, messages: messages, attachments: attachments)
    }

    @discardableResult
    private func merge(headers: [MessageHeader], account: MailAccount, mailbox: Mailbox, enforceLimit: Bool = true) -> Int {
        guard !headers.isEmpty else { return 0 }
        let normalizedHeaders = headers.map(Self.normalizedHeaderFields)

        var updatedMessages = messages
        let scopedIndices = updatedMessages.indices.filter {
            updatedMessages[$0].accountId == account.id && updatedMessages[$0].mailboxId == mailbox.id
        }
        var indexByUID: [Int64: Int] = [:]
        var indexByMessageID: [String: Int] = [:]
        indexByUID.reserveCapacity(scopedIndices.count)
        indexByMessageID.reserveCapacity(scopedIndices.count)

        for index in scopedIndices {
            let message = updatedMessages[index]
            indexByUID[message.uid] = index
            indexByMessageID[message.messageId] = index
        }

        for header in normalizedHeaders {
            guard let index = indexByUID[header.uid] ?? indexByMessageID[header.messageId] else { continue }

            let metadataChanged = updatedMessages[index].subject != header.subject
                || updatedMessages[index].fromAddress != header.fromAddress
                || updatedMessages[index].fromName != header.fromName
                || updatedMessages[index].date != header.date
                || updatedMessages[index].receivedDate != header.receivedDate

            updatedMessages[index].uid = header.uid
            updatedMessages[index].messageId = header.messageId
            updatedMessages[index].subject = header.subject
            updatedMessages[index].fromAddress = header.fromAddress
            updatedMessages[index].fromName = header.fromName
            updatedMessages[index].date = header.date
            updatedMessages[index].receivedDate = header.receivedDate
            updatedMessages[index].flags = header.flags
            if !updatedMessages[index].isBodyDownloaded {
                updatedMessages[index].snippet = header.subject
            }
            if metadataChanged, updatedMessages[index].isBodyDownloaded {
                updatedMessages[index].embeddingState = .pending
            }
        }

        let existingMailboxMessages = updatedMessages.filter { $0.accountId == account.id && $0.mailboxId == mailbox.id }
        let existingUIDs = Set(existingMailboxMessages.map(\.uid))
        let existingMessageIDs = Set(existingMailboxMessages.map(\.messageId))
        let newMessages = UIDSyncPlanner.headersToInsert(
            normalizedHeaders,
            existingUIDs: existingUIDs,
            existingMessageIDs: existingMessageIDs
        ).map { header in
            MailMessage(
                id: UUID(),
                accountId: account.id,
                mailboxId: mailbox.id,
                uid: header.uid,
                messageId: header.messageId,
                subject: header.subject,
                fromAddress: header.fromAddress,
                fromName: header.fromName,
                toRecipientsJSON: "[]",
                ccRecipientsJSON: "[]",
                bccRecipientsJSON: "[]",
                date: header.date,
                receivedDate: header.receivedDate,
                snippet: header.subject,
                bodyPlain: nil,
                bodyHTML: nil,
                flags: header.flags,
                hasAttachments: false,
                isBodyDownloaded: false,
                embeddingState: .pending
            )
        }

        updatedMessages.append(contentsOf: newMessages)
        updatedMessages.sort(by: Self.orderedByNewestReceivedDate)
        if enforceLimit {
            let limit = max(settings.cacheMessageLimit, 1)
            let mailboxMessages = updatedMessages
                .filter { $0.accountId == mailbox.accountId && $0.mailboxId == mailbox.id }
            let removedIDs = Set(mailboxMessages.dropFirst(limit).map(\.id))
            if !removedIDs.isEmpty {
                updatedMessages.removeAll { removedIDs.contains($0.id) }
                attachments.removeAll { removedIDs.contains($0.messageId) }
                if let selectedMessageID, removedIDs.contains(selectedMessageID) {
                    self.selectedMessageID = updatedMessages
                        .filter { $0.accountId == mailbox.accountId && $0.mailboxId == mailbox.id }
                        .first?.id
                }
            }
        }

        messages = updatedMessages
        updateUnreadCount(for: mailbox.id)
        if selectedMessageID == nil || !visibleMessages.contains(where: { $0.id == selectedMessageID }) {
            selectedMessageID = visibleMessages.first?.id
        }
        return newMessages.count
    }

    private func enforceCacheLimit(for mailbox: Mailbox) {
        let limit = max(settings.cacheMessageLimit, 1)
        let mailboxMessages = messages
            .filter { $0.accountId == mailbox.accountId && $0.mailboxId == mailbox.id }
        let removedIDs = Set(mailboxMessages.dropFirst(limit).map(\.id))
        guard !removedIDs.isEmpty else { return }

        messages.removeAll { removedIDs.contains($0.id) }
        attachments.removeAll { removedIDs.contains($0.messageId) }
        if let selectedMessageID, removedIDs.contains(selectedMessageID) {
            self.selectedMessageID = messages
                .filter { $0.accountId == mailbox.accountId && $0.mailboxId == mailbox.id }
                .first?.id
        }
    }



    private static func normalizedHeaderFields(_ header: MessageHeader) -> MessageHeader {
        MessageHeader(
            uid: header.uid,
            messageId: header.messageId,
            subject: MIMEParser.decodeHeaderValue(header.subject),
            fromAddress: header.fromAddress,
            fromName: MIMEParser.decodeHeaderValue(header.fromName),
            date: header.date,
            receivedDate: header.receivedDate,
            flags: header.flags
        )
    }

    private static func normalizedHeaderFields(_ message: MailMessage) -> MailMessage {
        var normalized = message
        normalized.subject = MIMEParser.decodeHeaderValue(message.subject)
        normalized.fromName = MIMEParser.decodeHeaderValue(message.fromName)
        if !message.isBodyDownloaded {
            normalized.snippet = MIMEParser.decodeHeaderValue(message.snippet)
        }
        return normalized
    }

    private func normalizeMessageOrder() {
        messages.sort(by: Self.orderedByNewestReceivedDate)
    }

    private func newestMessageFirst(_ lhs: MailMessage, _ rhs: MailMessage) -> Bool {
        Self.orderedByNewestReceivedDate(lhs, rhs)
    }

    private static func orderedByNewestReceivedDate(_ lhs: MailMessage, _ rhs: MailMessage) -> Bool {
        if lhs.sortDate != rhs.sortDate {
            return lhs.sortDate > rhs.sortDate
        }
        return lhs.uid > rhs.uid
    }

    private func updateUnreadCount(for mailboxID: UUID) {
        guard let index = mailboxes.firstIndex(where: { $0.id == mailboxID }) else { return }
        mailboxes[index].unreadCount = messages.filter { $0.mailboxId == mailboxID && !$0.flags.contains(.seen) }.count
    }

    private func markNeedsReauthIfAuthenticationFailed(accountID: UUID, error: Error) {
        let message = error.localizedDescription.lowercased()
        guard message.contains("auth") || message.contains("login") || message.contains("password") || message.contains("认证") || message.contains("密码") else {
            return
        }
        if let index = accounts.firstIndex(where: { $0.id == accountID }) {
            accounts[index].needsReauth = true
            persistSnapshot()
        }
    }

    private static func makeSeedSnapshot() -> MailStoreSnapshot {
        let account = MailAccount.demo()
        let folders = Mailbox.demoSet(accountId: account.id)
        let messages = MailMessage.demoMessages(accountId: account.id, inboxId: folders[0].id)
        return MailStoreSnapshot(
            accounts: [account],
            mailboxes: folders,
            messages: messages,
            attachments: demoAttachments(for: messages)
        )
    }

    private func splitAddresses(_ value: String) -> [String] {
        value
            .split { $0 == "," || $0 == ";" || $0.isNewline }
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    private static func demoAttachments(for messages: [MailMessage]) -> [MailAttachment] {
        guard let invoice = messages.first(where: { $0.messageId == "<invoice-alice@example.com>" }) else { return [] }
        return [
            MailAttachment(
                id: UUID(uuidString: "E7D40215-B908-47F7-8B68-051E34198E65") ?? UUID(),
                messageId: invoice.id,
                filename: "invoice-2026-06.pdf",
                mimeType: "application/pdf",
                sizeBytes: 248_320,
                localPath: nil,
                contentId: nil
            ),
            MailAttachment(
                id: UUID(uuidString: "66E88DB4-2F18-41D7-9AD9-A3426C38CE13") ?? UUID(),
                messageId: invoice.id,
                filename: "contract-draft.docx",
                mimeType: "application/vnd.openxmlformats-officedocument.wordprocessingml.document",
                sizeBytes: 91_420,
                localPath: nil,
                contentId: nil
            )
        ]
    }

    private func bootstrapEmbeddings() async {
        await processPendingEmbeddings()
    }

    func initializeVectorization(batchSize: Int = 16) async {
        guard settings.vectorizationEnabled else {
            statusMessage = localized(.vectorizationMustEnable)
            vectorizationProgress = nil
            return
        }
        settings.useLocalEmbedding = true
        settings.embeddingModel = ""
        settings.vectorizationConsentAccepted = true
        showsVectorizationPrivacyPrompt = false

        guard !messages.isEmpty else {
            statusMessage = localized(.vectorizationNoMessages)
            vectorizationProgress = nil
            return
        }

        let total = messages.count
        vectorizationProgress = VectorizationProgress(total: total, completed: 0, failed: 0, isActive: true)
        for index in messages.indices {
            messages[index].embeddingState = .pending
        }
        persistSnapshot()

        statusMessage = localized(.vectorizationQueueInitialized, total)
        await processAllPendingEmbeddings(batchSize: batchSize, progressTotal: total)

        let failedCount = messages.filter { $0.embeddingState == .failed }.count
        vectorizationProgress = VectorizationProgress(total: total, completed: total - failedCount, failed: failedCount, isActive: false)
        if failedCount > 0 {
            statusMessage = localized(.vectorizationCompletedWithFailures, failedCount)
        } else {
            statusMessage = localized(.vectorizationCompleted, total)
        }
    }

    private func processAllPendingEmbeddings(batchSize: Int = 16, progressTotal: Int? = nil) async {
        let safeBatchSize = max(batchSize, 1)
        while messages.contains(where: { $0.embeddingState == .pending }) {
            let pendingCount = messages.filter { $0.embeddingState == .pending }.count
            if let progressTotal {
                let failedCount = messages.filter { $0.embeddingState == .failed }.count
                let completedCount = max(progressTotal - pendingCount - failedCount, 0)
                vectorizationProgress = VectorizationProgress(total: progressTotal, completed: completedCount, failed: failedCount, isActive: true)
            }
            await Task.yield()
            await processPendingEmbeddings(batchSize: safeBatchSize)
            let remainingCount = messages.filter { $0.embeddingState == .pending }.count
            if let progressTotal {
                let failedCount = messages.filter { $0.embeddingState == .failed }.count
                let completedCount = max(progressTotal - remainingCount - failedCount, 0)
                vectorizationProgress = VectorizationProgress(total: progressTotal, completed: completedCount, failed: failedCount, isActive: remainingCount > 0)
            }
            await Task.yield()
            if remainingCount >= pendingCount {
                break
            }
        }
    }

    func processPendingEmbeddings(batchSize: Int = 16) async {
        guard settings.vectorizationEnabled else { return }
        settings.useLocalEmbedding = true
        settings.embeddingModel = ""
        settings.vectorizationConsentAccepted = true

        let pendingIDs = messages
            .filter { $0.embeddingState == .pending }
            .prefix(max(batchSize, 1))
            .map(\.id)
        guard !pendingIDs.isEmpty else { return }

        let pendingMessages = pendingIDs.compactMap { id in messages.first { $0.id == id } }
        let attachmentsByMessageID = Dictionary(grouping: attachments, by: \.messageId)
        let texts = pendingMessages.map { message in
            SearchService.indexText(for: message, attachments: attachmentsByMessageID[message.id] ?? [])
        }

        do {
            let vectors = try await resolvedEmbeddingService().embed(texts: texts)
            for (message, vector) in zip(pendingMessages, vectors) {
                try vectorStore.upsert(messageId: message.id, embedding: vector)
                if let index = messages.firstIndex(where: { $0.id == message.id }) {
                    messages[index].embeddingState = .done
                }
            }
        } catch {
            for id in pendingIDs {
                if let index = messages.firstIndex(where: { $0.id == id }) {
                    messages[index].embeddingState = .failed
                }
            }
            statusMessage = localized(.vectorizationFailedStatus, error.localizedDescription)
        }
        persistSnapshot()
    }
}

enum SearchMode: String, CaseIterable, Identifiable {
    case filter = "过滤"
    case ai = "AI 问答"

    var id: String { rawValue }
}

enum SmartMailbox: String, CaseIterable, Identifiable {
    case starred = "星标邮件"

    var id: String { rawValue }

    var symbolName: String {
        switch self {
        case .starred:
            return "star.fill"
        }
    }
}

enum MessageSortField: String, CaseIterable, Identifiable {
    case date = "收件时间"
    case sender = "发件人"

    var id: String { rawValue }

    var ascendingTitle: String {
        switch self {
        case .date:
            return "旧到新"
        case .sender:
            return "A 到 Z"
        }
    }

    var descendingTitle: String {
        switch self {
        case .date:
            return "新到旧"
        case .sender:
            return "Z 到 A"
        }
    }
}

struct VectorizationProgress: Equatable {
    var total: Int
    var completed: Int
    var failed: Int
    var isActive: Bool

    var processed: Int {
        min(completed + failed, total)
    }

    var fraction: Double {
        guard total > 0 else { return 0 }
        return Double(processed) / Double(total)
    }

    var label: String {
        if failed > 0 {
            return "已处理 \(processed)/\(total)，失败 \(failed)"
        }
        return "已处理 \(processed)/\(total)"
    }
}

actor MailAccountOperationQueue {
    private var activeAccountIDs: Set<UUID> = []
    private var waiters: [UUID: [CheckedContinuation<Void, Never>]] = [:]

    func acquire(_ accountID: UUID) async {
        if !activeAccountIDs.contains(accountID) {
            activeAccountIDs.insert(accountID)
            return
        }
        await withCheckedContinuation { continuation in
            waiters[accountID, default: []].append(continuation)
        }
    }

    func release(_ accountID: UUID) {
        guard var queued = waiters[accountID], !queued.isEmpty else {
            activeAccountIDs.remove(accountID)
            waiters[accountID] = nil
            return
        }
        let next = queued.removeFirst()
        waiters[accountID] = queued.isEmpty ? nil : queued
        next.resume()
    }
}

enum AppLanguage: String, Codable, CaseIterable, Identifiable, Hashable {
    case simplifiedChinese = "zh-Hans"
    case traditionalChinese = "zh-Hant"
    case japanese = "ja"
    case korean = "ko"
    case english = "en"
    case french = "fr"
    case russian = "ru"
    case swedish = "sv"
    case ukrainian = "uk"
    case finnish = "fi"

    var id: String { rawValue }

    var nativeName: String {
        switch self {
        case .simplifiedChinese: return "简体中文"
        case .traditionalChinese: return "繁體中文"
        case .japanese: return "日本語"
        case .korean: return "한국어"
        case .english: return "English"
        case .french: return "Français"
        case .russian: return "Русский"
        case .swedish: return "Svenska"
        case .ukrainian: return "Українська"
        case .finnish: return "Suomi"
        }
    }

    var aiInstructionName: String {
        switch self {
        case .simplifiedChinese: return "Simplified Chinese"
        case .traditionalChinese: return "Traditional Chinese"
        case .japanese: return "Japanese"
        case .korean: return "Korean"
        case .english: return "English"
        case .french: return "French"
        case .russian: return "Russian"
        case .swedish: return "Swedish"
        case .ukrainian: return "Ukrainian"
        case .finnish: return "Finnish"
        }
    }

    var formatLocale: Locale {
        Locale(identifier: rawValue)
    }
}

enum AppText: String, CaseIterable {
    case ready
    case smartMailboxes
    case starredMail
    case settings
    case receiveNewMail
    case refreshHelp
    case compose
    case composeHelp
    case searchMode
    case searchPlaceholder
    case sort
    case sortHelp
    case sortField
    case sortOrder
    case aiQuestionPlaceholder
    case aiQuestionHelp
    case relatedMessages
    case openOriginalMessage
    case selectMessage
    case messageBodyPlaceholder
    case reply
    case forward
    case aiReply
    case delete
    case archive
    case addStar
    case removeStar
    case noAttachments
    case accounts
    case aiModel
    case general
    case interfaceLanguage
    case pop3PollingInterval
    case initialCacheMessageCount
    case signature
    case enableVectorization
    case useZenMuxEmbeddings
    case useLocalEmbedding
    case cancel
    case vectorizationPrivacyMessage
    case missingVectorIndex
    case emptyAIAnswer
    case attachmentNotSaved
    case openAttachment
    case saveAs
    case recipient
    case sendingRoute
    case loadMoreMessages
    case loadingOlderMessages
    case noMoreMessages
    case cc
    case subject
    case aiInstruction
    case composeInstructionPlaceholder
    case generateAIDraft
    case addAttachment
    case send
    case removeAttachment
    case pendingToSend
    case needsReauth
    case deleteAccountConfig
    case newAppPassword
    case updatePassword
    case provider
    case genericProvider
    case customProvider
    case receivingProtocol
    case oauthBrowserLoginNote
    case appPasswordVisibilityNote
    case emailAddress
    case appPassword
    case browserLogin
    case documentation
    case saveToken
    case appPasswordHelp
    case testingMailConnection
    case connectionTestPassedCanSave
    case testConnection
    case save
    case oauthClientID
    case oauthAccessToken
    case oauthAdvancedTitle
    case oauthAdvancedHelp
    case oauthClientIDNotEmail
    case oauthAccessTokenNotAppPassword
    case gmailAppPassword
    case gmailAppPasswordGuideTitle
    case gmailAppPasswordGuideSteps
    case gmailAppPasswordOpenGoogle
    case gmailAppPasswordSecurityNote
    case gmailAppPasswordRequired
    case gmailConnectionFailedHint
    case tlsMode
    case apiKeyLabel
    case deleteAccountQuestion
    case deleteAccountButton
    case deleteAccountWarning
    case port
    case noEncryption
    case legacyServerHelp
    case commonPortsSummary
    case pop3Unsupported
    case accountInfoChangedRetest
    case showAPIKey
    case hideAPIKey
    case newZenMuxAPIKey
    case update
    case noAPIKeyYet
    case openInviteLink
    case testAPIKey
    case aiOptionalInfo
    case chatModel
    case addModelName
    case addModel
    case removeSelectedModel
    case embeddingModel
    case useLocalNLEmbeddingOffline
    case indexingProgress
    case initializeVectorIndex
    case rebuildVectorIndexHelp
    case vectorIndexOptionalInfo
    case vectorizationDisabledStatus
    case vectorizationEnabledZen
    case vectorizationEnabledLocal
    case vectorizationRebuildingZen
    case vectorizationRebuildingLocal
    case vectorizationChooseMode
    case vectorizationCancelled
    case vectorizationMustEnable
    case vectorizationNoMessages
    case vectorizationQueueInitialized
    case vectorizationCompletedWithFailures
    case vectorizationCompleted
    case vectorizationRemoteFallback
    case vectorizationFailedStatus
    case vectorizationProgressProcessed
    case vectorizationProgressProcessedFailed
    case accountConnectionInitialFeedback
    case apiKeyInitialFeedback
    case apiKeyNotSaved
    case apiKeyEnterValue
    case apiKeySavedToKeychain
    case apiKeyMissingSavedKey
    case chatModelMissing
    case embeddingModelMissing
    case apiKeyTesting
    case apiKeyValidationPassed
    case apiKeyValidationPassedWithResponse
    case apiKeyValidationFailed
    case composeMailWindowTitle
    case manualServerNoteGeneric
    case providerInlineGeneric
}

struct AppLocalizer {
    static func text(_ key: AppText, language: AppLanguage) -> String {
        table[language]?[key]
        ?? extraTable[language]?[key]
        ?? table[.english]?[key]
        ?? extraTable[.english]?[key]
        ?? table[.simplifiedChinese]?[key]
        ?? extraTable[.simplifiedChinese]?[key]
        ?? key.rawValue
    }

    private static let table: [AppLanguage: [AppText: String]] = [
        .simplifiedChinese: [
            .smartMailboxes: "智能邮箱",
            .starredMail: "星标邮件",
            .settings: "设置",
            .receiveNewMail: "收取新邮件",
            .refreshHelp: "刷新当前账户并接收新邮件",
            .compose: "撰写",
            .composeHelp: "撰写并通过当前账户 SMTP 发送邮件",
            .searchMode: "搜索模式",
            .searchPlaceholder: "搜索发件人、主题或正文",
            .sort: "排序",
            .sortHelp: "邮件排序",
            .sortField: "排序字段",
            .sortOrder: "顺序",
            .aiQuestionPlaceholder: "询问本地邮件，例如：上周 Alice 关于发票的邮件",
            .aiQuestionHelp: "AI 问答",
            .relatedMessages: "相关邮件",
            .openOriginalMessage: "打开原始邮件",
            .selectMessage: "选择一封邮件",
            .messageBodyPlaceholder: "邮件正文会显示在这里",
            .reply: "回复",
            .forward: "转发",
            .aiReply: "AI 回复",
            .delete: "删除",
            .archive: "存档",
            .addStar: "添加星标",
            .removeStar: "取消星标",
            .noAttachments: "无附件",
            .accounts: "账户",
            .aiModel: "AI 模型",
            .general: "通用",
            .interfaceLanguage: "界面与 AI 语言",
            .pop3PollingInterval: "POP3 轮询间隔：%d 分钟",
            .initialCacheMessageCount: "首次缓存邮件数：%d",
            .signature: "签名",
            .enableVectorization: "开启向量化",
            .useZenMuxEmbeddings: "使用 ZenMux 生成向量",
            .useLocalEmbedding: "改用本地 NLEmbedding",
            .cancel: "取消",
            .vectorizationPrivacyMessage: "向量化仅在本机使用 NLEmbedding 生成，用于 AI 检索和问答；邮件正文与附件文本不会因为向量化上传。",
            .missingVectorIndex: "没有可用的向量索引。请先在设置中初始化/重建向量索引；AI 问答只会基于已向量化的邮件回答。",
            .emptyAIAnswer: "模型没有返回可用回答。"
        ],
        .traditionalChinese: [
            .smartMailboxes: "智慧信箱",
            .starredMail: "星標郵件",
            .settings: "設定",
            .receiveNewMail: "收取新郵件",
            .refreshHelp: "重新整理目前帳戶並接收新郵件",
            .compose: "撰寫",
            .composeHelp: "撰寫並透過目前帳戶 SMTP 傳送郵件",
            .searchMode: "搜尋模式",
            .searchPlaceholder: "搜尋寄件者、主旨或正文",
            .sort: "排序",
            .sortHelp: "郵件排序",
            .sortField: "排序欄位",
            .sortOrder: "順序",
            .aiQuestionPlaceholder: "詢問本機郵件，例如：上週 Alice 關於發票的郵件",
            .aiQuestionHelp: "AI 問答",
            .relatedMessages: "相關郵件",
            .openOriginalMessage: "開啟原始郵件",
            .selectMessage: "選擇一封郵件",
            .messageBodyPlaceholder: "郵件正文會顯示在這裡",
            .reply: "回覆",
            .forward: "轉寄",
            .aiReply: "AI 回覆",
            .delete: "刪除",
            .archive: "封存",
            .addStar: "加入星標",
            .removeStar: "取消星標",
            .noAttachments: "無附件",
            .accounts: "帳戶",
            .aiModel: "AI 模型",
            .general: "一般",
            .interfaceLanguage: "介面與 AI 語言",
            .pop3PollingInterval: "POP3 輪詢間隔：%d 分鐘",
            .initialCacheMessageCount: "首次快取郵件數：%d",
            .signature: "簽名",
            .enableVectorization: "啟用向量化",
            .useZenMuxEmbeddings: "使用 ZenMux 產生向量",
            .useLocalEmbedding: "改用本機 NLEmbedding",
            .cancel: "取消",
            .vectorizationPrivacyMessage: "向量化只會在本機使用 NLEmbedding 產生，用於 AI 檢索和問答；郵件正文與附件文字不會因向量化上傳。",
            .missingVectorIndex: "沒有可用的向量索引。請先在設定中初始化/重建向量索引；AI 問答只會根據已向量化的郵件回答。",
            .emptyAIAnswer: "模型沒有返回可用回答。"
        ],
        .japanese: [
            .smartMailboxes: "スマートメールボックス",
            .starredMail: "スター付きメール",
            .settings: "設定",
            .receiveNewMail: "新着メールを受信",
            .refreshHelp: "現在のアカウントを更新して新着メールを受信",
            .compose: "作成",
            .composeHelp: "現在のアカウントの SMTP でメールを送信",
            .searchMode: "検索モード",
            .searchPlaceholder: "差出人、件名、本文を検索",
            .sort: "並べ替え",
            .sortHelp: "メールの並べ替え",
            .sortField: "並べ替え項目",
            .sortOrder: "順序",
            .aiQuestionPlaceholder: "ローカルメールに質問。例：先週 Alice が請求書について送ったメール",
            .aiQuestionHelp: "AI 質問応答",
            .relatedMessages: "関連メール",
            .openOriginalMessage: "元のメールを開く",
            .selectMessage: "メールを選択",
            .messageBodyPlaceholder: "メール本文がここに表示されます",
            .reply: "返信",
            .forward: "転送",
            .aiReply: "AI 返信",
            .delete: "削除",
            .archive: "アーカイブ",
            .addStar: "スターを付ける",
            .removeStar: "スターを外す",
            .noAttachments: "添付なし",
            .accounts: "アカウント",
            .aiModel: "AI モデル",
            .general: "一般",
            .interfaceLanguage: "UI と AI の言語",
            .pop3PollingInterval: "POP3 ポーリング間隔：%d 分",
            .initialCacheMessageCount: "初回キャッシュ件数：%d",
            .signature: "署名",
            .enableVectorization: "ベクトル化を有効化",
            .useZenMuxEmbeddings: "ZenMux でベクトルを生成",
            .useLocalEmbedding: "ローカル NLEmbedding を使う",
            .cancel: "キャンセル",
            .vectorizationPrivacyMessage: "ベクトル化はローカルの NLEmbedding のみを使用し、AI 検索と質問応答に使われます。メール本文や添付テキストはベクトル化のためにアップロードされません。",
            .missingVectorIndex: "利用できるベクトル索引がありません。設定で索引を初期化/再構築してください。AI 質問応答はベクトル化済みメールだけに基づきます。",
            .emptyAIAnswer: "モデルから有効な回答が返りませんでした。"
        ],
        .korean: [
            .smartMailboxes: "스마트 메일함",
            .starredMail: "별표 메일",
            .settings: "설정",
            .receiveNewMail: "새 메일 받기",
            .refreshHelp: "현재 계정을 새로고침하고 새 메일을 받습니다",
            .compose: "작성",
            .composeHelp: "현재 계정의 SMTP로 메일을 보냅니다",
            .searchMode: "검색 모드",
            .searchPlaceholder: "보낸 사람, 제목 또는 본문 검색",
            .sort: "정렬",
            .sortHelp: "메일 정렬",
            .sortField: "정렬 필드",
            .sortOrder: "순서",
            .aiQuestionPlaceholder: "로컬 메일에 질문. 예: 지난주 Alice의 인보이스 메일",
            .aiQuestionHelp: "AI 질의응답",
            .relatedMessages: "관련 메일",
            .openOriginalMessage: "원본 메일 열기",
            .selectMessage: "메일 선택",
            .messageBodyPlaceholder: "메일 본문이 여기에 표시됩니다",
            .reply: "답장",
            .forward: "전달",
            .aiReply: "AI 답장",
            .delete: "삭제",
            .archive: "보관",
            .addStar: "별표 추가",
            .removeStar: "별표 제거",
            .noAttachments: "첨부 없음",
            .accounts: "계정",
            .aiModel: "AI 모델",
            .general: "일반",
            .interfaceLanguage: "UI 및 AI 언어",
            .pop3PollingInterval: "POP3 폴링 간격: %d분",
            .initialCacheMessageCount: "초기 캐시 메일 수: %d",
            .signature: "서명",
            .enableVectorization: "벡터화 사용",
            .useZenMuxEmbeddings: "ZenMux로 벡터 생성",
            .useLocalEmbedding: "로컬 NLEmbedding 사용",
            .cancel: "취소",
            .vectorizationPrivacyMessage: "벡터화는 로컬 NLEmbedding만 사용하며 AI 검색과 질의응답에 쓰입니다. 메일 본문과 첨부 텍스트는 벡터화를 위해 업로드되지 않습니다.",
            .missingVectorIndex: "사용 가능한 벡터 인덱스가 없습니다. 설정에서 벡터 인덱스를 초기화/재구성하세요. AI 질의응답은 벡터화된 메일만 기반으로 합니다.",
            .emptyAIAnswer: "모델이 유효한 답변을 반환하지 않았습니다."
        ],
        .english: [
            .smartMailboxes: "Smart Mailboxes",
            .starredMail: "Starred Mail",
            .settings: "Settings",
            .receiveNewMail: "Get New Mail",
            .refreshHelp: "Refresh the current account and receive new mail",
            .compose: "Compose",
            .composeHelp: "Compose and send through the current account SMTP",
            .searchMode: "Search Mode",
            .searchPlaceholder: "Search sender, subject, or body",
            .sort: "Sort",
            .sortHelp: "Sort mail",
            .sortField: "Sort Field",
            .sortOrder: "Order",
            .aiQuestionPlaceholder: "Ask local mail, e.g. Alice's invoice messages from last week",
            .aiQuestionHelp: "AI Q&A",
            .relatedMessages: "Related Messages",
            .openOriginalMessage: "Open original message",
            .selectMessage: "Select a message",
            .messageBodyPlaceholder: "The message body will appear here",
            .reply: "Reply",
            .forward: "Forward",
            .aiReply: "AI Reply",
            .delete: "Delete",
            .archive: "Archive",
            .addStar: "Add star",
            .removeStar: "Remove star",
            .noAttachments: "No attachments",
            .accounts: "Accounts",
            .aiModel: "AI Model",
            .general: "General",
            .interfaceLanguage: "Interface and AI Language",
            .pop3PollingInterval: "POP3 polling interval: %d minutes",
            .initialCacheMessageCount: "Initial cached messages: %d",
            .signature: "Signature",
            .enableVectorization: "Enable vectorization",
            .useZenMuxEmbeddings: "Use ZenMux embeddings",
            .useLocalEmbedding: "Use local NLEmbedding",
            .cancel: "Cancel",
            .vectorizationPrivacyMessage: "Vectorization uses only local NLEmbedding for AI search and Q&A. Mail body text and readable attachment text are not uploaded for vectorization.",
            .missingVectorIndex: "No vector index is available. Initialize or rebuild the vector index in Settings first; AI Q&A only answers from vectorized mail.",
            .emptyAIAnswer: "The model did not return a usable answer."
        ],
        .french: [
            .smartMailboxes: "Boîtes intelligentes",
            .starredMail: "Messages suivis",
            .settings: "Réglages",
            .receiveNewMail: "Relever le courrier",
            .refreshHelp: "Actualiser le compte actuel et recevoir les nouveaux messages",
            .compose: "Rédiger",
            .composeHelp: "Rédiger et envoyer via le SMTP du compte actuel",
            .searchMode: "Mode de recherche",
            .searchPlaceholder: "Rechercher expéditeur, objet ou corps",
            .sort: "Trier",
            .sortHelp: "Trier les messages",
            .sortField: "Champ de tri",
            .sortOrder: "Ordre",
            .aiQuestionPlaceholder: "Interroger les mails locaux, ex. les factures d'Alice la semaine dernière",
            .aiQuestionHelp: "Questions IA",
            .relatedMessages: "Messages liés",
            .openOriginalMessage: "Ouvrir le message d'origine",
            .selectMessage: "Sélectionnez un message",
            .messageBodyPlaceholder: "Le corps du message s'affichera ici",
            .reply: "Répondre",
            .forward: "Transférer",
            .aiReply: "Réponse IA",
            .delete: "Supprimer",
            .archive: "Archiver",
            .addStar: "Ajouter une étoile",
            .removeStar: "Retirer l'étoile",
            .noAttachments: "Aucune pièce jointe",
            .accounts: "Comptes",
            .aiModel: "Modèle IA",
            .general: "Général",
            .interfaceLanguage: "Langue de l'interface et de l'IA",
            .pop3PollingInterval: "Intervalle POP3 : %d min",
            .initialCacheMessageCount: "Messages mis en cache au départ : %d",
            .signature: "Signature",
            .enableVectorization: "Activer la vectorisation",
            .useZenMuxEmbeddings: "Utiliser ZenMux pour les vecteurs",
            .useLocalEmbedding: "Utiliser NLEmbedding local",
            .cancel: "Annuler",
            .vectorizationPrivacyMessage: "La vectorisation utilise uniquement NLEmbedding local pour la recherche IA et les questions-réponses. Le corps des mails et le texte lisible des pièces jointes ne sont pas envoyés pour la vectorisation.",
            .missingVectorIndex: "Aucun index vectoriel disponible. Initialisez ou reconstruisez l'index dans Réglages ; les questions IA répondent uniquement à partir des mails vectorisés.",
            .emptyAIAnswer: "Le modèle n'a pas renvoyé de réponse exploitable."
        ],
        .russian: [
            .smartMailboxes: "Умные ящики",
            .starredMail: "Помеченные письма",
            .settings: "Настройки",
            .receiveNewMail: "Получить почту",
            .refreshHelp: "Обновить текущую учетную запись и получить новые письма",
            .compose: "Написать",
            .composeHelp: "Написать и отправить через SMTP текущей учетной записи",
            .searchMode: "Режим поиска",
            .searchPlaceholder: "Искать отправителя, тему или текст",
            .sort: "Сортировка",
            .sortHelp: "Сортировка писем",
            .sortField: "Поле сортировки",
            .sortOrder: "Порядок",
            .aiQuestionPlaceholder: "Спросите локальную почту, например письма Alice о счетах за прошлую неделю",
            .aiQuestionHelp: "Вопросы ИИ",
            .relatedMessages: "Связанные письма",
            .openOriginalMessage: "Открыть исходное письмо",
            .selectMessage: "Выберите письмо",
            .messageBodyPlaceholder: "Текст письма появится здесь",
            .reply: "Ответить",
            .forward: "Переслать",
            .aiReply: "Ответ ИИ",
            .delete: "Удалить",
            .archive: "Архивировать",
            .addStar: "Добавить звезду",
            .removeStar: "Убрать звезду",
            .noAttachments: "Нет вложений",
            .accounts: "Учетные записи",
            .aiModel: "Модель ИИ",
            .general: "Общие",
            .interfaceLanguage: "Язык интерфейса и ИИ",
            .pop3PollingInterval: "Интервал POP3: %d мин",
            .initialCacheMessageCount: "Первоначально кэшировать писем: %d",
            .signature: "Подпись",
            .enableVectorization: "Включить векторизацию",
            .useZenMuxEmbeddings: "Создавать векторы через ZenMux",
            .useLocalEmbedding: "Использовать локальный NLEmbedding",
            .cancel: "Отмена",
            .vectorizationPrivacyMessage: "Векторизация использует только локальный NLEmbedding для поиска ИИ и вопросов-ответов. Текст писем и читаемый текст вложений не загружаются для векторизации.",
            .missingVectorIndex: "Нет доступного векторного индекса. Сначала инициализируйте или перестройте индекс в настройках; ИИ отвечает только по векторизованным письмам.",
            .emptyAIAnswer: "Модель не вернула пригодный ответ."
        ],
        .swedish: [
            .smartMailboxes: "Smarta brevlådor",
            .starredMail: "Stjärnmärkt e-post",
            .settings: "Inställningar",
            .receiveNewMail: "Hämta ny e-post",
            .refreshHelp: "Uppdatera aktuellt konto och hämta ny e-post",
            .compose: "Skriv",
            .composeHelp: "Skriv och skicka via aktuellt kontos SMTP",
            .searchMode: "Sökläge",
            .searchPlaceholder: "Sök avsändare, ämne eller brödtext",
            .sort: "Sortera",
            .sortHelp: "Sortera e-post",
            .sortField: "Sorteringsfält",
            .sortOrder: "Ordning",
            .aiQuestionPlaceholder: "Fråga lokal e-post, t.ex. Alices fakturamail från förra veckan",
            .aiQuestionHelp: "AI-frågor",
            .relatedMessages: "Relaterade meddelanden",
            .openOriginalMessage: "Öppna originalmeddelande",
            .selectMessage: "Välj ett meddelande",
            .messageBodyPlaceholder: "Meddelandets text visas här",
            .reply: "Svara",
            .forward: "Vidarebefordra",
            .aiReply: "AI-svar",
            .delete: "Radera",
            .archive: "Arkivera",
            .addStar: "Lägg till stjärna",
            .removeStar: "Ta bort stjärna",
            .noAttachments: "Inga bilagor",
            .accounts: "Konton",
            .aiModel: "AI-modell",
            .general: "Allmänt",
            .interfaceLanguage: "Gränssnitts- och AI-språk",
            .pop3PollingInterval: "POP3-intervall: %d min",
            .initialCacheMessageCount: "Första cacheantal: %d",
            .signature: "Signatur",
            .enableVectorization: "Aktivera vektorisering",
            .useZenMuxEmbeddings: "Använd ZenMux för vektorer",
            .useLocalEmbedding: "Använd lokal NLEmbedding",
            .cancel: "Avbryt",
            .vectorizationPrivacyMessage: "Vektorisering använder endast lokal NLEmbedding för AI-sökning och frågor och svar. Meddelandetext och läsbar bilagetext laddas inte upp för vektorisering.",
            .missingVectorIndex: "Inget vektorindex är tillgängligt. Initiera eller bygg om indexet i Inställningar först; AI-frågor besvaras bara från vektoriserad e-post.",
            .emptyAIAnswer: "Modellen returnerade inget användbart svar."
        ],
        .ukrainian: [
            .smartMailboxes: "Розумні скриньки",
            .starredMail: "Позначені листи",
            .settings: "Налаштування",
            .receiveNewMail: "Отримати нову пошту",
            .refreshHelp: "Оновити поточний обліковий запис і отримати нові листи",
            .compose: "Написати",
            .composeHelp: "Написати й надіслати через SMTP поточного облікового запису",
            .searchMode: "Режим пошуку",
            .searchPlaceholder: "Шукати відправника, тему або текст",
            .sort: "Сортувати",
            .sortHelp: "Сортувати листи",
            .sortField: "Поле сортування",
            .sortOrder: "Порядок",
            .aiQuestionPlaceholder: "Запитайте локальну пошту, напр. листи Alice про рахунки за минулий тиждень",
            .aiQuestionHelp: "Питання до ШІ",
            .relatedMessages: "Пов'язані листи",
            .openOriginalMessage: "Відкрити початковий лист",
            .selectMessage: "Виберіть лист",
            .messageBodyPlaceholder: "Текст листа з'явиться тут",
            .reply: "Відповісти",
            .forward: "Переслати",
            .aiReply: "Відповідь ШІ",
            .delete: "Видалити",
            .archive: "Архівувати",
            .addStar: "Додати зірку",
            .removeStar: "Прибрати зірку",
            .noAttachments: "Немає вкладень",
            .accounts: "Облікові записи",
            .aiModel: "Модель ШІ",
            .general: "Загальні",
            .interfaceLanguage: "Мова інтерфейсу та ШІ",
            .pop3PollingInterval: "Інтервал POP3: %d хв",
            .initialCacheMessageCount: "Початкова кількість кешованих листів: %d",
            .signature: "Підпис",
            .enableVectorization: "Увімкнути векторизацію",
            .useZenMuxEmbeddings: "Створювати вектори через ZenMux",
            .useLocalEmbedding: "Використати локальний NLEmbedding",
            .cancel: "Скасувати",
            .vectorizationPrivacyMessage: "Векторизація використовує лише локальний NLEmbedding для пошуку ШІ та запитань-відповідей. Текст листів і читабельний текст вкладень не завантажуються для векторизації.",
            .missingVectorIndex: "Немає доступного векторного індексу. Спочатку ініціалізуйте або перебудуйте індекс у Налаштуваннях; ШІ відповідає лише за векторизованими листами.",
            .emptyAIAnswer: "Модель не повернула придатну відповідь."
        ],
        .finnish: [
            .smartMailboxes: "Älykkäät postilaatikot",
            .starredMail: "Tähdellä merkityt",
            .settings: "Asetukset",
            .receiveNewMail: "Hae uudet viestit",
            .refreshHelp: "Päivitä nykyinen tili ja hae uudet viestit",
            .compose: "Kirjoita",
            .composeHelp: "Kirjoita ja lähetä nykyisen tilin SMTP:llä",
            .searchMode: "Hakutila",
            .searchPlaceholder: "Hae lähettäjää, aihetta tai sisältöä",
            .sort: "Lajittele",
            .sortHelp: "Lajittele viestit",
            .sortField: "Lajittelukenttä",
            .sortOrder: "Järjestys",
            .aiQuestionPlaceholder: "Kysy paikallisista viesteistä, esim. Alicen laskuviestit viime viikolta",
            .aiQuestionHelp: "AI-kysymykset",
            .relatedMessages: "Liittyvät viestit",
            .openOriginalMessage: "Avaa alkuperäinen viesti",
            .selectMessage: "Valitse viesti",
            .messageBodyPlaceholder: "Viestin sisältö näkyy tässä",
            .reply: "Vastaa",
            .forward: "Välitä",
            .aiReply: "AI-vastaus",
            .delete: "Poista",
            .archive: "Arkistoi",
            .addStar: "Lisää tähti",
            .removeStar: "Poista tähti",
            .noAttachments: "Ei liitteitä",
            .accounts: "Tilit",
            .aiModel: "AI-malli",
            .general: "Yleiset",
            .interfaceLanguage: "Käyttöliittymän ja AI:n kieli",
            .pop3PollingInterval: "POP3-kyselyväli: %d min",
            .initialCacheMessageCount: "Aluksi välimuistiin: %d viestiä",
            .signature: "Allekirjoitus",
            .enableVectorization: "Ota vektorointi käyttöön",
            .useZenMuxEmbeddings: "Luo vektorit ZenMuxilla",
            .useLocalEmbedding: "Käytä paikallista NLEmbeddingia",
            .cancel: "Peruuta",
            .vectorizationPrivacyMessage: "Vektorointi käyttää vain paikallista NLEmbeddingia tekoälyhakuun ja kysymyksiin vastaamiseen. Viestien sisältöä ja luettavaa liitetekstiä ei lähetetä vektorointia varten.",
            .missingVectorIndex: "Vektori-indeksiä ei ole saatavilla. Alusta tai rakenna indeksi ensin Asetuksissa; AI-kysymykset vastaavat vain vektoroiduista viesteistä.",
            .emptyAIAnswer: "Malli ei palauttanut käyttökelpoista vastausta."
        ]
    ]

    private static let extraTable: [AppLanguage: [AppText: String]] = [
        .simplifiedChinese: [
            .ready: "就绪",
            .attachmentNotSaved: "附件尚未保存到本地",
            .openAttachment: "打开附件",
            .saveAs: "另存为...",
            .recipient: "收件人",
            .sendingRoute: "发信路径",
            .loadMoreMessages: "加载更多",
            .loadingOlderMessages: "正在加载更早的邮件...",
            .noMoreMessages: "没有更多邮件",
            .cc: "抄送",
            .subject: "主题",
            .aiInstruction: "AI 指令",
            .composeInstructionPlaceholder: "例如：婉拒并说明下周再约",
            .generateAIDraft: "生成 AI 草稿",
            .addAttachment: "添加附件",
            .send: "发送",
            .removeAttachment: "移除附件",
            .pendingToSend: "待发送",
            .needsReauth: "需要重新认证",
            .deleteAccountConfig: "删除账户配置",
            .newAppPassword: "新的客户端专用密码",
            .updatePassword: "更新密码",
            .provider: "服务商",
            .genericProvider: "通用邮箱",
            .customProvider: "自定义",
            .receivingProtocol: "收信协议",
            .oauthBrowserLoginNote: "推荐使用浏览器登录授权；若改用应用专用密码，请先在账号安全设置中开启两步验证。",
            .appPasswordVisibilityNote: "客户端专用密码通常只在生成时可见；请复制后粘贴到这里，myMail 仅写入 Keychain，不会明文回显。",
            .emailAddress: "邮箱地址",
            .appPassword: "客户端专用密码",
            .browserLogin: "浏览器登录",
            .documentation: "文档",
            .saveToken: "保存 token",
            .appPasswordHelp: "如何获取应用专用密码",
            .testingMailConnection: "正在测试 %@ 与 SMTP...",
            .connectionTestPassedCanSave: "连接测试通过，可以保存账户。",
            .testConnection: "测试连接",
            .save: "保存",
            .oauthClientID: "OAuth Client ID",
            .oauthAccessToken: "OAuth2 access token",
            .oauthAdvancedTitle: "高级 OAuth2 登录（可选）",
            .oauthAdvancedHelp: "普通收发请填写上面的邮箱地址和 Gmail 应用专用密码。这里仅用于已有 OAuth Client ID / token 的开发者配置。",
            .oauthClientIDNotEmail: "OAuth Client ID（不是邮箱地址）",
            .oauthAccessTokenNotAppPassword: "OAuth2 access token（不是应用专用密码）",
            .gmailAppPassword: "Gmail 应用专用密码（16 位）",
            .gmailAppPasswordGuideTitle: "Gmail 不能直接使用 Google 登录密码",
            .gmailAppPasswordGuideSteps: "请先在 Google 账号开启两步验证，然后打开“应用专用密码”，创建一个用于邮件客户端的 16 位密码，并把它粘贴到这里。",
            .gmailAppPasswordOpenGoogle: "打开 Google 应用专用密码页面",
            .gmailAppPasswordSecurityNote: "如果页面不可用，通常是账号未开启两步验证、由单位/学校管理员禁用，或账号必须使用 OAuth 登录。",
            .gmailAppPasswordRequired: "Gmail 不能使用普通 Google 登录密码。请使用浏览器 OAuth 登录，或粘贴 Google 生成的 16 位应用专用密码。",
            .gmailConnectionFailedHint: "Gmail 连接失败：%@。请确认你输入的是 16 位应用专用密码，不是 Google 登录密码；同时确认 Gmail 已启用 IMAP/POP。",
            .tlsMode: "TLS 模式",
            .apiKeyLabel: "API-Key",
            .deleteAccountQuestion: "删除账户配置？",
            .deleteAccountButton: "删除 %@",
            .deleteAccountWarning: "将移除此账户配置、本地缓存和 Keychain 凭据。",
            .port: "端口",
            .noEncryption: "无加密",
            .legacyServerHelp: "老服务器可选无加密，常见端口包括 IMAP 143、POP3 110、SMTP 25。",
            .commonPortsSummary: "常用端口 IMAP 993/143 · SMTP 465/587/25 · POP3 995/110；TLS 可选 SSL/TLS、STARTTLS 或无加密。",
            .pop3Unsupported: "POP3 不支持",
            .accountInfoChangedRetest: "账户信息已修改，请重新测试连接。",
            .showAPIKey: "显示 API-Key",
            .hideAPIKey: "隐藏 API-Key",
            .newZenMuxAPIKey: "新的 ZenMux API-Key",
            .update: "更新",
            .noAPIKeyYet: "还没有 API-Key?",
            .openInviteLink: "打开邀请链接",
            .testAPIKey: "测试 API-Key",
            .aiOptionalInfo: "AI 模型仅用于智能问答、草稿生成等增强功能；不配置 API-Key 不影响邮件收发。",
            .chatModel: "对话模型",
            .addModelName: "添加模型名",
            .addModel: "添加模型",
            .removeSelectedModel: "移除当前模型",
            .embeddingModel: "Embedding 模型",
            .useLocalNLEmbeddingOffline: "本地向量化：使用 NLEmbedding（离线，不使用 OpenAI Embedding）",
            .indexingProgress: "正在索引 %d/%d",
            .initializeVectorIndex: "初始化/重建向量索引",
            .rebuildVectorIndexHelp: "重新索引邮件正文和可读取的附件内容",
            .vectorIndexOptionalInfo: "向量索引只服务于 AI 问答和附件内容检索；可以不初始化，不影响基础邮件功能。",
            .vectorizationDisabledStatus: "向量化已关闭。",
            .vectorizationEnabledZen: "向量化已开启，将使用 ZenMux 生成向量。",
            .vectorizationEnabledLocal: "向量化已开启，将使用本地 NLEmbedding。",
            .vectorizationRebuildingZen: "正在使用 ZenMux 重建向量索引。",
            .vectorizationRebuildingLocal: "正在使用本地 NLEmbedding 重建向量索引。",
            .vectorizationChooseMode: "请选择本地向量化或确认远程向量化后开始初始化。",
            .vectorizationCancelled: "已取消开启向量化。",
            .vectorizationMustEnable: "请先开启向量化。",
            .vectorizationNoMessages: "没有可初始化向量化的邮件。",
            .vectorizationQueueInitialized: "已初始化 %d 封邮件的向量化队列，正在处理正文和可读附件。",
            .vectorizationCompletedWithFailures: "向量化初始化完成，%d 封邮件处理失败。",
            .vectorizationCompleted: "向量化初始化完成，已索引 %d 封邮件。",
            .vectorizationRemoteFallback: "ZenMux 向量化失败，已降级为本地 NLEmbedding。",
            .vectorizationFailedStatus: "向量化失败：%@",
            .vectorizationProgressProcessed: "已处理 %d/%d",
            .vectorizationProgressProcessedFailed: "已处理 %d/%d，失败 %d",
            .accountConnectionInitialFeedback: "填写邮箱、密码和服务器后点击测试连接。",
            .apiKeyInitialFeedback: "保存 API-Key 后可测试 ZenMux 连通性。",
            .apiKeyNotSaved: "未保存",
            .apiKeyEnterValue: "请输入 ZenMux API-Key。",
            .apiKeySavedToKeychain: "ZenMux API-Key 已保存到 Keychain。",
            .apiKeyMissingSavedKey: "请先保存 API-Key。",
            .chatModelMissing: "请先选择或填写对话模型。",
            .embeddingModelMissing: "请先填写 Embedding 模型，或改用本地 NLEmbedding。",
            .apiKeyTesting: "正在测试 ZenMux API-Key...",
            .apiKeyValidationPassed: "API-Key 验证通过。",
            .apiKeyValidationPassedWithResponse: "API-Key 验证通过：%@",
            .apiKeyValidationFailed: "API-Key 验证失败：%@",
            .composeMailWindowTitle: "撰写邮件",
            .manualServerNoteGeneric: "适用于学校或企业邮箱。可填写 SSL/TLS、STARTTLS 或无加密的旧端口；密码仅写入 Keychain，不会明文回显。",
            .providerInlineGeneric: "适用于学校或企业邮箱。可填写 SSL/TLS、STARTTLS 或无加密的旧端口。"
        ],
        .traditionalChinese: [
            .ready: "就緒",
            .attachmentNotSaved: "附件尚未儲存到本機",
            .openAttachment: "開啟附件",
            .saveAs: "另存為...",
            .recipient: "收件人",
            .sendingRoute: "寄送路徑",
            .loadMoreMessages: "載入更多",
            .loadingOlderMessages: "正在載入更早的郵件...",
            .noMoreMessages: "沒有更多郵件",
            .cc: "副本",
            .subject: "主旨",
            .aiInstruction: "AI 指令",
            .composeInstructionPlaceholder: "例如：婉拒並說明下週再約",
            .generateAIDraft: "產生 AI 草稿",
            .addAttachment: "加入附件",
            .send: "傳送",
            .removeAttachment: "移除附件",
            .pendingToSend: "待傳送",
            .needsReauth: "需要重新認證",
            .deleteAccountConfig: "刪除帳戶設定",
            .newAppPassword: "新的客戶端專用密碼",
            .updatePassword: "更新密碼",
            .provider: "服務商",
            .genericProvider: "通用信箱",
            .customProvider: "自訂",
            .receivingProtocol: "收信協定",
            .oauthBrowserLoginNote: "建議使用瀏覽器登入授權；若改用應用程式專用密碼，請先在帳號安全設定中啟用兩步驟驗證。",
            .appPasswordVisibilityNote: "客戶端專用密碼通常只在產生時可見；請複製後貼到這裡，myMail 只寫入 Keychain，不會明文回顯。",
            .emailAddress: "電子郵件地址",
            .appPassword: "客戶端專用密碼",
            .browserLogin: "瀏覽器登入",
            .documentation: "文件",
            .saveToken: "儲存 token",
            .appPasswordHelp: "如何取得應用程式專用密碼",
            .testingMailConnection: "正在測試 %@ 與 SMTP...",
            .connectionTestPassedCanSave: "連線測試通過，可以儲存帳戶。",
            .testConnection: "測試連線",
            .save: "儲存",
            .oauthClientID: "OAuth Client ID",
            .oauthAccessToken: "OAuth2 access token",
            .tlsMode: "TLS 模式",
            .apiKeyLabel: "API-Key",
            .deleteAccountQuestion: "刪除帳戶設定？",
            .deleteAccountButton: "刪除 %@",
            .deleteAccountWarning: "將移除此帳戶設定、本機快取和 Keychain 憑證。",
            .port: "連接埠",
            .noEncryption: "無加密",
            .legacyServerHelp: "舊伺服器可選無加密，常見連接埠包括 IMAP 143、POP3 110、SMTP 25。",
            .commonPortsSummary: "常用連接埠 IMAP 993/143 · SMTP 465/587/25 · POP3 995/110；TLS 可選 SSL/TLS、STARTTLS 或無加密。",
            .pop3Unsupported: "不支援 POP3",
            .accountInfoChangedRetest: "帳戶資訊已修改，請重新測試連線。",
            .showAPIKey: "顯示 API-Key",
            .hideAPIKey: "隱藏 API-Key",
            .newZenMuxAPIKey: "新的 ZenMux API-Key",
            .update: "更新",
            .noAPIKeyYet: "還沒有 API-Key?",
            .openInviteLink: "開啟邀請連結",
            .testAPIKey: "測試 API-Key",
            .aiOptionalInfo: "AI 模型僅用於智慧問答、草稿產生等增強功能；不設定 API-Key 不影響郵件收發。",
            .chatModel: "對話模型",
            .addModelName: "新增模型名稱",
            .addModel: "新增模型",
            .removeSelectedModel: "移除目前模型",
            .embeddingModel: "Embedding 模型",
            .useLocalNLEmbeddingOffline: "本機向量化：使用 NLEmbedding（離線，不使用 OpenAI Embedding）",
            .indexingProgress: "正在索引 %d/%d",
            .initializeVectorIndex: "初始化/重建向量索引",
            .rebuildVectorIndexHelp: "重新索引郵件正文和可讀取的附件內容",
            .vectorIndexOptionalInfo: "向量索引只服務於 AI 問答和附件內容檢索；可以不初始化，不影響基礎郵件功能。",
            .vectorizationDisabledStatus: "向量化已關閉。",
            .vectorizationEnabledZen: "向量化已啟用，將使用 ZenMux 產生向量。",
            .vectorizationEnabledLocal: "向量化已啟用，將使用本機 NLEmbedding。",
            .vectorizationRebuildingZen: "正在使用 ZenMux 重建向量索引。",
            .vectorizationRebuildingLocal: "正在使用本機 NLEmbedding 重建向量索引。",
            .vectorizationChooseMode: "請選擇本機向量化或確認遠端向量化後開始初始化。",
            .vectorizationCancelled: "已取消啟用向量化。",
            .vectorizationMustEnable: "請先啟用向量化。",
            .vectorizationNoMessages: "沒有可初始化向量化的郵件。",
            .vectorizationQueueInitialized: "已初始化 %d 封郵件的向量化佇列，正在處理正文和可讀附件。",
            .vectorizationCompletedWithFailures: "向量化初始化完成，%d 封郵件處理失敗。",
            .vectorizationCompleted: "向量化初始化完成，已索引 %d 封郵件。",
            .vectorizationRemoteFallback: "ZenMux 向量化失敗，已降級為本機 NLEmbedding。",
            .vectorizationFailedStatus: "向量化失敗：%@",
            .vectorizationProgressProcessed: "已處理 %d/%d",
            .vectorizationProgressProcessedFailed: "已處理 %d/%d，失敗 %d",
            .accountConnectionInitialFeedback: "填寫信箱、密碼和伺服器後點擊測試連線。",
            .apiKeyInitialFeedback: "儲存 API-Key 後可測試 ZenMux 連通性。",
            .apiKeyNotSaved: "未儲存",
            .apiKeyEnterValue: "請輸入 ZenMux API-Key。",
            .apiKeySavedToKeychain: "ZenMux API-Key 已儲存到 Keychain。",
            .apiKeyMissingSavedKey: "請先儲存 API-Key。",
            .chatModelMissing: "請先選擇或填寫對話模型。",
            .embeddingModelMissing: "請先填寫 Embedding 模型，或改用本地 NLEmbedding。",
            .apiKeyTesting: "正在測試 ZenMux API-Key...",
            .apiKeyValidationPassed: "API-Key 驗證通過。",
            .apiKeyValidationPassedWithResponse: "API-Key 驗證通過：%@",
            .apiKeyValidationFailed: "API-Key 驗證失敗：%@",
            .composeMailWindowTitle: "撰寫郵件",
            .manualServerNoteGeneric: "適用於學校或企業信箱。可填寫 SSL/TLS、STARTTLS 或無加密的舊連接埠；密碼只寫入 Keychain，不會明文回顯。",
            .providerInlineGeneric: "適用於學校或企業信箱。可填寫 SSL/TLS、STARTTLS 或無加密的舊連接埠。"
        ],
        .english: [
            .ready: "Ready",
            .attachmentNotSaved: "Attachment has not been saved locally",
            .openAttachment: "Open Attachment",
            .saveAs: "Save As...",
            .recipient: "To",
            .sendingRoute: "Sending Route",
            .loadMoreMessages: "Load More",
            .loadingOlderMessages: "Loading older messages...",
            .noMoreMessages: "No more messages",
            .cc: "Cc",
            .subject: "Subject",
            .aiInstruction: "AI Instruction",
            .composeInstructionPlaceholder: "For example: politely decline and suggest next week",
            .generateAIDraft: "Generate AI Draft",
            .addAttachment: "Add Attachment",
            .send: "Send",
            .removeAttachment: "Remove attachment",
            .pendingToSend: "Pending",
            .needsReauth: "Reauthentication needed",
            .deleteAccountConfig: "Delete account configuration",
            .newAppPassword: "New app password",
            .updatePassword: "Update Password",
            .provider: "Provider",
            .genericProvider: "Generic Mail",
            .customProvider: "Custom",
            .receivingProtocol: "Receiving Protocol",
            .oauthBrowserLoginNote: "Browser authorization is recommended. If you use an app password instead, enable two-step verification in account security first.",
            .appPasswordVisibilityNote: "App passwords are usually visible only when generated. Paste it here; myMail only writes it to Keychain and never echoes it in plain text.",
            .emailAddress: "Email Address",
            .appPassword: "App Password",
            .browserLogin: "Browser Login",
            .documentation: "Docs",
            .saveToken: "Save token",
            .appPasswordHelp: "How to get an app password",
            .testingMailConnection: "Testing %@ and SMTP...",
            .connectionTestPassedCanSave: "Connection test passed. You can save the account.",
            .testConnection: "Test Connection",
            .save: "Save",
            .oauthClientID: "OAuth Client ID",
            .oauthAccessToken: "OAuth2 access token",
            .oauthAdvancedTitle: "Advanced OAuth2 Login (optional)",
            .oauthAdvancedHelp: "For normal mail access, fill the email address and Gmail app password above. This section is only for developer setups with an OAuth Client ID or token.",
            .oauthClientIDNotEmail: "OAuth Client ID (not email address)",
            .oauthAccessTokenNotAppPassword: "OAuth2 access token (not app password)",
            .gmailAppPassword: "Gmail app password (16 digits)",
            .gmailAppPasswordGuideTitle: "Gmail cannot use your normal Google password",
            .gmailAppPasswordGuideSteps: "Enable 2-Step Verification in your Google Account, open App Passwords, create a 16-digit password for a mail client, then paste it here.",
            .gmailAppPasswordOpenGoogle: "Open Google App Passwords",
            .gmailAppPasswordSecurityNote: "If the page is unavailable, 2-Step Verification may be off, your organization may block app passwords, or the account may require OAuth.",
            .gmailAppPasswordRequired: "Gmail cannot use your normal Google password. Use browser OAuth login, or paste the 16-digit app password generated by Google.",
            .gmailConnectionFailedHint: "Gmail connection failed: %@. Make sure this is the 16-digit app password, not your Google login password, and confirm IMAP/POP is enabled in Gmail.",
            .tlsMode: "TLS Mode",
            .apiKeyLabel: "API-Key",
            .deleteAccountQuestion: "Delete account configuration?",
            .deleteAccountButton: "Delete %@",
            .deleteAccountWarning: "This will remove the account configuration, local cache, and Keychain credentials.",
            .port: "Port",
            .noEncryption: "No Encryption",
            .legacyServerHelp: "Legacy servers may use no encryption. Common ports include IMAP 143, POP3 110, SMTP 25.",
            .commonPortsSummary: "Common ports: IMAP 993/143 · SMTP 465/587/25 · POP3 995/110; TLS can be SSL/TLS, STARTTLS, or none.",
            .pop3Unsupported: "POP3 unsupported",
            .accountInfoChangedRetest: "Account information changed. Please test the connection again.",
            .showAPIKey: "Show API-Key",
            .hideAPIKey: "Hide API-Key",
            .newZenMuxAPIKey: "New ZenMux API-Key",
            .update: "Update",
            .noAPIKeyYet: "No API-Key yet?",
            .openInviteLink: "Open Invite Link",
            .testAPIKey: "Test API-Key",
            .aiOptionalInfo: "AI models are only used for enhanced features such as Q&A and draft generation. Mail sending and receiving still work without an API-Key.",
            .chatModel: "Chat Model",
            .addModelName: "Add model name",
            .addModel: "Add model",
            .removeSelectedModel: "Remove selected model",
            .embeddingModel: "Embedding Model",
            .useLocalNLEmbeddingOffline: "Local vectorization: NLEmbedding only (offline, no OpenAI Embedding)",
            .indexingProgress: "Indexing %d/%d",
            .initializeVectorIndex: "Initialize/Rebuild Vector Index",
            .rebuildVectorIndexHelp: "Reindex mail bodies and readable attachment content",
            .vectorIndexOptionalInfo: "The vector index only supports AI Q&A and attachment retrieval. You can skip initialization; basic mail features are unaffected.",
            .vectorizationDisabledStatus: "Vectorization is off.",
            .vectorizationEnabledZen: "Vectorization is on and will use ZenMux embeddings.",
            .vectorizationEnabledLocal: "Vectorization is on and will use local NLEmbedding.",
            .vectorizationRebuildingZen: "Rebuilding the vector index with ZenMux.",
            .vectorizationRebuildingLocal: "Rebuilding the vector index with local NLEmbedding.",
            .vectorizationChooseMode: "Choose local vectorization or confirm remote vectorization before initializing.",
            .vectorizationCancelled: "Vectorization enablement was cancelled.",
            .vectorizationMustEnable: "Enable vectorization first.",
            .vectorizationNoMessages: "There are no messages to vectorize.",
            .vectorizationQueueInitialized: "Initialized the vectorization queue for %d messages. Processing bodies and readable attachments.",
            .vectorizationCompletedWithFailures: "Vectorization finished; %d messages failed.",
            .vectorizationCompleted: "Vectorization finished; indexed %d messages.",
            .vectorizationRemoteFallback: "ZenMux vectorization failed; falling back to local NLEmbedding.",
            .vectorizationFailedStatus: "Vectorization failed: %@",
            .vectorizationProgressProcessed: "Processed %d/%d",
            .vectorizationProgressProcessedFailed: "Processed %d/%d, failed %d",
            .accountConnectionInitialFeedback: "Enter email, password, and servers, then test the connection.",
            .apiKeyInitialFeedback: "Save an API-Key to test ZenMux connectivity.",
            .apiKeyNotSaved: "Not saved",
            .apiKeyEnterValue: "Enter a ZenMux API-Key.",
            .apiKeySavedToKeychain: "ZenMux API-Key saved to Keychain.",
            .apiKeyMissingSavedKey: "Save an API-Key first.",
            .chatModelMissing: "Select or enter a chat model first.",
            .embeddingModelMissing: "Enter an Embedding model first, or switch to local NLEmbedding.",
            .apiKeyTesting: "Testing ZenMux API-Key...",
            .apiKeyValidationPassed: "API-Key validation passed.",
            .apiKeyValidationPassedWithResponse: "API-Key validation passed: %@",
            .apiKeyValidationFailed: "API-Key validation failed: %@",
            .composeMailWindowTitle: "Compose Mail",
            .manualServerNoteGeneric: "For school or enterprise mail. You can enter SSL/TLS, STARTTLS, or legacy unencrypted ports; passwords are only written to Keychain.",
            .providerInlineGeneric: "For school or enterprise mail. Supports SSL/TLS, STARTTLS, or legacy unencrypted ports."
        ],
        .japanese: [
            .ready: "準備完了",
            .attachmentNotSaved: "添付ファイルはまだローカルに保存されていません",
            .openAttachment: "添付ファイルを開く",
            .saveAs: "別名で保存...",
            .recipient: "宛先",
            .sendingRoute: "送信経路",
            .loadMoreMessages: "さらに読み込む",
            .loadingOlderMessages: "古いメールを読み込み中...",
            .noMoreMessages: "これ以上メールはありません",
            .cc: "Cc",
            .subject: "件名",
            .aiInstruction: "AI 指示",
            .composeInstructionPlaceholder: "例：丁寧に断り、来週を提案する",
            .generateAIDraft: "AI 下書きを生成",
            .addAttachment: "添付を追加",
            .send: "送信",
            .removeAttachment: "添付を削除",
            .pendingToSend: "送信待ち",
            .needsReauth: "再認証が必要",
            .deleteAccountConfig: "アカウント設定を削除",
            .newAppPassword: "新しいアプリパスワード",
            .updatePassword: "パスワードを更新",
            .provider: "プロバイダ",
            .genericProvider: "汎用メール",
            .customProvider: "カスタム",
            .receivingProtocol: "受信プロトコル",
            .oauthBrowserLoginNote: "ブラウザ認証を推奨します。アプリパスワードを使う場合は、先にアカウントの二段階認証を有効にしてください。",
            .appPasswordVisibilityNote: "アプリパスワードは通常、生成時にだけ表示されます。ここに貼り付けると myMail は Keychain にだけ保存し、平文では表示しません。",
            .emailAddress: "メールアドレス",
            .appPassword: "アプリパスワード",
            .browserLogin: "ブラウザでログイン",
            .documentation: "ドキュメント",
            .saveToken: "token を保存",
            .appPasswordHelp: "アプリパスワードの取得方法",
            .testingMailConnection: "%@ と SMTP をテスト中...",
            .connectionTestPassedCanSave: "接続テストに成功しました。アカウントを保存できます。",
            .testConnection: "接続をテスト",
            .save: "保存",
            .oauthClientID: "OAuth Client ID",
            .oauthAccessToken: "OAuth2 access token",
            .tlsMode: "TLS モード",
            .apiKeyLabel: "API-Key",
            .deleteAccountQuestion: "アカウント設定を削除しますか？",
            .deleteAccountButton: "%@ を削除",
            .deleteAccountWarning: "このアカウント設定、ローカルキャッシュ、Keychain 資格情報を削除します。",
            .port: "ポート",
            .noEncryption: "暗号化なし",
            .legacyServerHelp: "古いサーバーでは暗号化なしを選べます。一般的なポートは IMAP 143、POP3 110、SMTP 25 です。",
            .commonPortsSummary: "一般的なポート：IMAP 993/143・SMTP 465/587/25・POP3 995/110。TLS は SSL/TLS、STARTTLS、なしを選べます。",
            .pop3Unsupported: "POP3 は非対応",
            .accountInfoChangedRetest: "アカウント情報が変更されました。接続を再テストしてください。",
            .showAPIKey: "API-Key を表示",
            .hideAPIKey: "API-Key を隠す",
            .newZenMuxAPIKey: "新しい ZenMux API-Key",
            .update: "更新",
            .noAPIKeyYet: "API-Key がありませんか？",
            .openInviteLink: "招待リンクを開く",
            .testAPIKey: "API-Key をテスト",
            .aiOptionalInfo: "AI モデルは質問応答や下書き生成などの拡張機能だけに使います。API-Key を設定しなくてもメールの送受信は動作します。",
            .chatModel: "チャットモデル",
            .addModelName: "モデル名を追加",
            .addModel: "モデルを追加",
            .removeSelectedModel: "選択中のモデルを削除",
            .embeddingModel: "Embedding モデル",
            .useLocalNLEmbeddingOffline: "ローカルベクトル化：NLEmbedding のみ（オフライン、OpenAI Embedding 不使用）",
            .indexingProgress: "索引作成中 %d/%d",
            .initializeVectorIndex: "ベクトル索引を初期化/再構築",
            .rebuildVectorIndexHelp: "メール本文と読み取り可能な添付内容を再索引します",
            .vectorIndexOptionalInfo: "ベクトル索引は AI 質問応答と添付内容検索だけに使われます。初期化しなくても基本的なメール機能には影響しません。",
            .vectorizationDisabledStatus: "ベクトル化はオフです。",
            .vectorizationEnabledZen: "ベクトル化はオンで、ZenMux のベクトルを使用します。",
            .vectorizationEnabledLocal: "ベクトル化はオンで、ローカル NLEmbedding を使用します。",
            .vectorizationRebuildingZen: "ZenMux でベクトル索引を再構築中です。",
            .vectorizationRebuildingLocal: "ローカル NLEmbedding でベクトル索引を再構築中です。",
            .vectorizationChooseMode: "初期化する前に、ローカルベクトル化を選ぶかリモートベクトル化を確認してください。",
            .vectorizationCancelled: "ベクトル化の有効化をキャンセルしました。",
            .vectorizationMustEnable: "先にベクトル化を有効にしてください。",
            .vectorizationNoMessages: "ベクトル化できるメールがありません。",
            .vectorizationQueueInitialized: "%d 件のメールのベクトル化キューを初期化しました。本文と読み取り可能な添付を処理しています。",
            .vectorizationCompletedWithFailures: "ベクトル化が完了しました。%d 件のメールで失敗しました。",
            .vectorizationCompleted: "ベクトル化が完了しました。%d 件のメールを索引化しました。",
            .vectorizationRemoteFallback: "ZenMux ベクトル化に失敗したため、ローカル NLEmbedding に切り替えました。",
            .vectorizationFailedStatus: "ベクトル化に失敗しました：%@",
            .vectorizationProgressProcessed: "処理済み %d/%d",
            .vectorizationProgressProcessedFailed: "処理済み %d/%d、失敗 %d",
            .accountConnectionInitialFeedback: "メール、パスワード、サーバーを入力して接続をテストしてください。",
            .apiKeyInitialFeedback: "API-Key を保存すると ZenMux 接続をテストできます。",
            .apiKeyNotSaved: "未保存",
            .apiKeyEnterValue: "ZenMux API-Key を入力してください。",
            .apiKeySavedToKeychain: "ZenMux API-Key を Keychain に保存しました。",
            .apiKeyMissingSavedKey: "先に API-Key を保存してください。",
            .chatModelMissing: "先にチャットモデルを選択または入力してください。",
            .embeddingModelMissing: "先に Embedding モデルを入力するか、ローカル NLEmbedding に切り替えてください。",
            .apiKeyTesting: "ZenMux API-Key をテスト中...",
            .apiKeyValidationPassed: "API-Key の検証に成功しました。",
            .apiKeyValidationPassedWithResponse: "API-Key の検証に成功しました：%@",
            .apiKeyValidationFailed: "API-Key の検証に失敗しました：%@",
            .composeMailWindowTitle: "メールを作成",
            .manualServerNoteGeneric: "学校や企業メール向けです。SSL/TLS、STARTTLS、古い暗号化なしポートを入力できます。パスワードは Keychain にだけ保存されます。",
            .providerInlineGeneric: "学校や企業メール向けです。SSL/TLS、STARTTLS、古い暗号化なしポートに対応します。"
        ],
        .korean: [
            .ready: "준비됨",
            .attachmentNotSaved: "첨부 파일이 아직 로컬에 저장되지 않았습니다",
            .openAttachment: "첨부 파일 열기",
            .saveAs: "다른 이름으로 저장...",
            .recipient: "받는 사람",
            .sendingRoute: "발신 경로",
            .loadMoreMessages: "더 불러오기",
            .loadingOlderMessages: "이전 메일을 불러오는 중...",
            .noMoreMessages: "더 이상 메일이 없습니다",
            .cc: "참조",
            .subject: "제목",
            .aiInstruction: "AI 지시",
            .composeInstructionPlaceholder: "예: 정중히 거절하고 다음 주를 제안",
            .generateAIDraft: "AI 초안 생성",
            .addAttachment: "첨부 추가",
            .send: "보내기",
            .removeAttachment: "첨부 제거",
            .pendingToSend: "대기 중",
            .needsReauth: "재인증 필요",
            .deleteAccountConfig: "계정 설정 삭제",
            .newAppPassword: "새 앱 비밀번호",
            .updatePassword: "비밀번호 업데이트",
            .provider: "서비스 제공자",
            .genericProvider: "범용 메일",
            .customProvider: "사용자 지정",
            .receivingProtocol: "수신 프로토콜",
            .oauthBrowserLoginNote: "브라우저 인증을 권장합니다. 앱 비밀번호를 사용할 경우 먼저 계정 보안에서 2단계 인증을 켜세요.",
            .appPasswordVisibilityNote: "앱 비밀번호는 보통 생성 시에만 보입니다. 여기에 붙여넣으면 myMail은 Keychain에만 저장하고 평문으로 표시하지 않습니다.",
            .emailAddress: "이메일 주소",
            .appPassword: "앱 비밀번호",
            .browserLogin: "브라우저 로그인",
            .documentation: "문서",
            .saveToken: "token 저장",
            .appPasswordHelp: "앱 비밀번호 받는 방법",
            .testingMailConnection: "%@ 및 SMTP 테스트 중...",
            .connectionTestPassedCanSave: "연결 테스트가 통과되었습니다. 계정을 저장할 수 있습니다.",
            .testConnection: "연결 테스트",
            .save: "저장",
            .oauthClientID: "OAuth Client ID",
            .oauthAccessToken: "OAuth2 access token",
            .tlsMode: "TLS 모드",
            .apiKeyLabel: "API-Key",
            .deleteAccountQuestion: "계정 설정을 삭제할까요?",
            .deleteAccountButton: "%@ 삭제",
            .deleteAccountWarning: "이 계정 설정, 로컬 캐시, Keychain 자격 증명이 제거됩니다.",
            .port: "포트",
            .noEncryption: "암호화 없음",
            .legacyServerHelp: "이전 서버는 암호화 없음을 사용할 수 있습니다. 일반 포트는 IMAP 143, POP3 110, SMTP 25입니다.",
            .commonPortsSummary: "일반 포트: IMAP 993/143 · SMTP 465/587/25 · POP3 995/110; TLS는 SSL/TLS, STARTTLS 또는 없음.",
            .pop3Unsupported: "POP3 미지원",
            .accountInfoChangedRetest: "계정 정보가 변경되었습니다. 연결을 다시 테스트하세요.",
            .showAPIKey: "API-Key 표시",
            .hideAPIKey: "API-Key 숨기기",
            .newZenMuxAPIKey: "새 ZenMux API-Key",
            .update: "업데이트",
            .noAPIKeyYet: "API-Key가 없나요?",
            .openInviteLink: "초대 링크 열기",
            .testAPIKey: "API-Key 테스트",
            .aiOptionalInfo: "AI 모델은 질의응답과 초안 생성 같은 향상 기능에만 사용됩니다. API-Key를 설정하지 않아도 메일 송수신은 동작합니다.",
            .chatModel: "채팅 모델",
            .addModelName: "모델명 추가",
            .addModel: "모델 추가",
            .removeSelectedModel: "선택한 모델 제거",
            .embeddingModel: "Embedding 모델",
            .useLocalNLEmbeddingOffline: "로컬 벡터화: NLEmbedding만 사용(오프라인, OpenAI Embedding 미사용)",
            .indexingProgress: "인덱싱 중 %d/%d",
            .initializeVectorIndex: "벡터 인덱스 초기화/재구성",
            .rebuildVectorIndexHelp: "메일 본문과 읽을 수 있는 첨부 내용을 다시 인덱싱합니다",
            .vectorIndexOptionalInfo: "벡터 인덱스는 AI 질의응답과 첨부 내용 검색에만 사용됩니다. 초기화하지 않아도 기본 메일 기능에는 영향이 없습니다.",
            .vectorizationDisabledStatus: "벡터화가 꺼졌습니다.",
            .vectorizationEnabledZen: "벡터화가 켜졌으며 ZenMux 벡터를 사용합니다.",
            .vectorizationEnabledLocal: "벡터화가 켜졌으며 로컬 NLEmbedding을 사용합니다.",
            .vectorizationRebuildingZen: "ZenMux로 벡터 인덱스를 재구성하는 중입니다.",
            .vectorizationRebuildingLocal: "로컬 NLEmbedding으로 벡터 인덱스를 재구성하는 중입니다.",
            .vectorizationChooseMode: "초기화하기 전에 로컬 벡터화를 선택하거나 원격 벡터화를 확인하세요.",
            .vectorizationCancelled: "벡터화 사용이 취소되었습니다.",
            .vectorizationMustEnable: "먼저 벡터화를 켜세요.",
            .vectorizationNoMessages: "벡터화할 메일이 없습니다.",
            .vectorizationQueueInitialized: "%d개 메일의 벡터화 대기열을 초기화했습니다. 본문과 읽을 수 있는 첨부를 처리 중입니다.",
            .vectorizationCompletedWithFailures: "벡터화가 완료되었지만 %d개 메일 처리에 실패했습니다.",
            .vectorizationCompleted: "벡터화가 완료되어 %d개 메일을 인덱싱했습니다.",
            .vectorizationRemoteFallback: "ZenMux 벡터화에 실패하여 로컬 NLEmbedding으로 전환했습니다.",
            .vectorizationFailedStatus: "벡터화 실패: %@",
            .vectorizationProgressProcessed: "%d/%d 처리됨",
            .vectorizationProgressProcessedFailed: "%d/%d 처리됨, 실패 %d",
            .accountConnectionInitialFeedback: "이메일, 비밀번호, 서버를 입력한 뒤 연결을 테스트하세요.",
            .apiKeyInitialFeedback: "API-Key를 저장하면 ZenMux 연결을 테스트할 수 있습니다.",
            .apiKeyNotSaved: "저장 안 됨",
            .apiKeyEnterValue: "ZenMux API-Key를 입력하세요.",
            .apiKeySavedToKeychain: "ZenMux API-Key가 Keychain에 저장되었습니다.",
            .apiKeyMissingSavedKey: "먼저 API-Key를 저장하세요.",
            .chatModelMissing: "먼저 대화 모델을 선택하거나 입력하세요.",
            .embeddingModelMissing: "먼저 Embedding 모델을 입력하거나 로컬 NLEmbedding으로 전환하세요.",
            .apiKeyTesting: "ZenMux API-Key 테스트 중...",
            .apiKeyValidationPassed: "API-Key 검증이 통과되었습니다.",
            .apiKeyValidationPassedWithResponse: "API-Key 검증이 통과되었습니다: %@",
            .apiKeyValidationFailed: "API-Key 검증 실패: %@",
            .composeMailWindowTitle: "메일 작성",
            .manualServerNoteGeneric: "학교나 기업 메일용입니다. SSL/TLS, STARTTLS 또는 이전 암호화 없음 포트를 입력할 수 있으며 비밀번호는 Keychain에만 저장됩니다.",
            .providerInlineGeneric: "학교나 기업 메일용입니다. SSL/TLS, STARTTLS 또는 이전 암호화 없음 포트를 지원합니다."
        ],
        .french: [
            .ready: "Prêt",
            .attachmentNotSaved: "La pièce jointe n'est pas encore enregistrée localement",
            .openAttachment: "Ouvrir la pièce jointe",
            .saveAs: "Enregistrer sous...",
            .recipient: "À",
            .sendingRoute: "Compte d'envoi",
            .loadMoreMessages: "Charger plus",
            .loadingOlderMessages: "Chargement des anciens messages...",
            .noMoreMessages: "Aucun autre message",
            .cc: "Cc",
            .subject: "Objet",
            .aiInstruction: "Instruction IA",
            .composeInstructionPlaceholder: "Ex. refuser poliment et proposer la semaine prochaine",
            .generateAIDraft: "Générer un brouillon IA",
            .addAttachment: "Ajouter une pièce jointe",
            .send: "Envoyer",
            .removeAttachment: "Retirer la pièce jointe",
            .pendingToSend: "En attente",
            .needsReauth: "Réauthentification requise",
            .deleteAccountConfig: "Supprimer la configuration du compte",
            .newAppPassword: "Nouveau mot de passe d'app",
            .updatePassword: "Mettre à jour le mot de passe",
            .provider: "Fournisseur",
            .genericProvider: "Messagerie générique",
            .customProvider: "Personnalisé",
            .receivingProtocol: "Protocole de réception",
            .oauthBrowserLoginNote: "L'autorisation par navigateur est recommandée. Si vous utilisez un mot de passe d'app, activez d'abord la validation en deux étapes.",
            .appPasswordVisibilityNote: "Les mots de passe d'app ne sont généralement visibles qu'à leur création. Collez-le ici ; myMail l'écrit seulement dans Keychain.",
            .emailAddress: "Adresse e-mail",
            .appPassword: "Mot de passe d'app",
            .browserLogin: "Connexion navigateur",
            .documentation: "Documentation",
            .saveToken: "Enregistrer le token",
            .appPasswordHelp: "Comment obtenir un mot de passe d'app",
            .testingMailConnection: "Test de %@ et SMTP...",
            .connectionTestPassedCanSave: "Test de connexion réussi. Vous pouvez enregistrer le compte.",
            .testConnection: "Tester la connexion",
            .save: "Enregistrer",
            .oauthClientID: "OAuth Client ID",
            .oauthAccessToken: "OAuth2 access token",
            .tlsMode: "Mode TLS",
            .apiKeyLabel: "API-Key",
            .deleteAccountQuestion: "Supprimer la configuration du compte ?",
            .deleteAccountButton: "Supprimer %@",
            .deleteAccountWarning: "Cela supprimera la configuration du compte, le cache local et les identifiants Keychain.",
            .port: "Port",
            .noEncryption: "Sans chiffrement",
            .legacyServerHelp: "Les anciens serveurs peuvent utiliser l'absence de chiffrement. Ports courants : IMAP 143, POP3 110, SMTP 25.",
            .commonPortsSummary: "Ports courants : IMAP 993/143 · SMTP 465/587/25 · POP3 995/110 ; TLS peut être SSL/TLS, STARTTLS ou aucun.",
            .pop3Unsupported: "POP3 non pris en charge",
            .accountInfoChangedRetest: "Les informations du compte ont changé. Testez de nouveau la connexion.",
            .showAPIKey: "Afficher l'API-Key",
            .hideAPIKey: "Masquer l'API-Key",
            .newZenMuxAPIKey: "Nouvelle API-Key ZenMux",
            .update: "Mettre à jour",
            .noAPIKeyYet: "Pas encore d'API-Key ?",
            .openInviteLink: "Ouvrir le lien d'invitation",
            .testAPIKey: "Tester l'API-Key",
            .aiOptionalInfo: "Les modèles IA ne servent qu'aux fonctions avancées comme les questions-réponses et les brouillons. L'envoi et la réception des mails fonctionnent sans API-Key.",
            .chatModel: "Modèle de chat",
            .addModelName: "Ajouter un nom de modèle",
            .addModel: "Ajouter le modèle",
            .removeSelectedModel: "Retirer le modèle sélectionné",
            .embeddingModel: "Modèle Embedding",
            .useLocalNLEmbeddingOffline: "Vectorisation locale : NLEmbedding uniquement (hors ligne, sans OpenAI Embedding)",
            .indexingProgress: "Indexation %d/%d",
            .initializeVectorIndex: "Initialiser/reconstruire l'index vectoriel",
            .rebuildVectorIndexHelp: "Réindexer les corps de mails et le contenu lisible des pièces jointes",
            .vectorIndexOptionalInfo: "L'index vectoriel sert uniquement aux questions IA et à la recherche dans les pièces jointes. Vous pouvez l'ignorer ; les fonctions mail de base ne sont pas affectées.",
            .vectorizationDisabledStatus: "La vectorisation est désactivée.",
            .vectorizationEnabledZen: "La vectorisation est activée et utilisera ZenMux.",
            .vectorizationEnabledLocal: "La vectorisation est activée et utilisera NLEmbedding local.",
            .vectorizationRebuildingZen: "Reconstruction de l'index vectoriel avec ZenMux.",
            .vectorizationRebuildingLocal: "Reconstruction de l'index vectoriel avec NLEmbedding local.",
            .vectorizationChooseMode: "Choisissez la vectorisation locale ou confirmez la vectorisation distante avant d'initialiser.",
            .vectorizationCancelled: "Activation de la vectorisation annulée.",
            .vectorizationMustEnable: "Activez d'abord la vectorisation.",
            .vectorizationNoMessages: "Aucun message à vectoriser.",
            .vectorizationQueueInitialized: "File de vectorisation initialisée pour %d messages. Traitement des corps et pièces jointes lisibles.",
            .vectorizationCompletedWithFailures: "Vectorisation terminée ; %d messages ont échoué.",
            .vectorizationCompleted: "Vectorisation terminée ; %d messages indexés.",
            .vectorizationRemoteFallback: "La vectorisation ZenMux a échoué ; bascule vers NLEmbedding local.",
            .vectorizationFailedStatus: "Échec de la vectorisation : %@",
            .vectorizationProgressProcessed: "%d/%d traités",
            .vectorizationProgressProcessedFailed: "%d/%d traités, %d échecs",
            .accountConnectionInitialFeedback: "Saisissez l'e-mail, le mot de passe et les serveurs, puis testez la connexion.",
            .apiKeyInitialFeedback: "Enregistrez une API-Key pour tester la connexion ZenMux.",
            .apiKeyNotSaved: "Non enregistrée",
            .apiKeyEnterValue: "Saisissez une API-Key ZenMux.",
            .apiKeySavedToKeychain: "API-Key ZenMux enregistrée dans Keychain.",
            .apiKeyMissingSavedKey: "Enregistrez d'abord une API-Key.",
            .chatModelMissing: "Sélectionnez ou saisissez d'abord un modèle de chat.",
            .embeddingModelMissing: "Saisissez d'abord un modèle Embedding ou utilisez NLEmbedding local.",
            .apiKeyTesting: "Test de l'API-Key ZenMux...",
            .apiKeyValidationPassed: "Validation de l'API-Key réussie.",
            .apiKeyValidationPassedWithResponse: "Validation de l'API-Key réussie : %@",
            .apiKeyValidationFailed: "Validation de l'API-Key échouée : %@",
            .composeMailWindowTitle: "Rédiger un mail",
            .manualServerNoteGeneric: "Pour les messageries scolaires ou d'entreprise. Vous pouvez saisir SSL/TLS, STARTTLS ou d'anciens ports non chiffrés ; les mots de passe sont seulement écrits dans Keychain.",
            .providerInlineGeneric: "Pour les messageries scolaires ou d'entreprise. Prend en charge SSL/TLS, STARTTLS ou d'anciens ports non chiffrés."
        ],
        .russian: [
            .ready: "Готово",
            .attachmentNotSaved: "Вложение еще не сохранено локально",
            .openAttachment: "Открыть вложение",
            .saveAs: "Сохранить как...",
            .recipient: "Кому",
            .sendingRoute: "Маршрут отправки",
            .loadMoreMessages: "Загрузить еще",
            .loadingOlderMessages: "Загрузка старых писем...",
            .noMoreMessages: "Больше писем нет",
            .cc: "Копия",
            .subject: "Тема",
            .aiInstruction: "Инструкция ИИ",
            .composeInstructionPlaceholder: "Например: вежливо отказать и предложить следующую неделю",
            .generateAIDraft: "Создать черновик ИИ",
            .addAttachment: "Добавить вложение",
            .send: "Отправить",
            .removeAttachment: "Удалить вложение",
            .pendingToSend: "Ожидает отправки",
            .needsReauth: "Нужна повторная авторизация",
            .deleteAccountConfig: "Удалить настройку учетной записи",
            .newAppPassword: "Новый пароль приложения",
            .updatePassword: "Обновить пароль",
            .provider: "Провайдер",
            .genericProvider: "Обычная почта",
            .customProvider: "Другое",
            .receivingProtocol: "Протокол получения",
            .oauthBrowserLoginNote: "Рекомендуется авторизация в браузере. Для пароля приложения сначала включите двухэтапную проверку в настройках безопасности.",
            .appPasswordVisibilityNote: "Пароли приложений обычно видны только при создании. Вставьте его здесь; myMail сохранит его только в Keychain.",
            .emailAddress: "Адрес почты",
            .appPassword: "Пароль приложения",
            .browserLogin: "Войти в браузере",
            .documentation: "Документация",
            .saveToken: "Сохранить token",
            .appPasswordHelp: "Как получить пароль приложения",
            .testingMailConnection: "Проверка %@ и SMTP...",
            .connectionTestPassedCanSave: "Проверка соединения успешна. Можно сохранить учетную запись.",
            .testConnection: "Проверить соединение",
            .save: "Сохранить",
            .oauthClientID: "OAuth Client ID",
            .oauthAccessToken: "OAuth2 access token",
            .tlsMode: "Режим TLS",
            .apiKeyLabel: "API-Key",
            .deleteAccountQuestion: "Удалить настройку учетной записи?",
            .deleteAccountButton: "Удалить %@",
            .deleteAccountWarning: "Будут удалены настройка учетной записи, локальный кэш и данные Keychain.",
            .port: "Порт",
            .noEncryption: "Без шифрования",
            .legacyServerHelp: "Старые серверы могут работать без шифрования. Частые порты: IMAP 143, POP3 110, SMTP 25.",
            .commonPortsSummary: "Частые порты: IMAP 993/143 · SMTP 465/587/25 · POP3 995/110; TLS: SSL/TLS, STARTTLS или нет.",
            .pop3Unsupported: "POP3 не поддерживается",
            .accountInfoChangedRetest: "Данные учетной записи изменились. Проверьте соединение снова.",
            .showAPIKey: "Показать API-Key",
            .hideAPIKey: "Скрыть API-Key",
            .newZenMuxAPIKey: "Новый ZenMux API-Key",
            .update: "Обновить",
            .noAPIKeyYet: "Еще нет API-Key?",
            .openInviteLink: "Открыть ссылку-приглашение",
            .testAPIKey: "Проверить API-Key",
            .aiOptionalInfo: "Модели ИИ используются только для дополнительных функций, таких как вопросы и черновики. Отправка и получение почты работают без API-Key.",
            .chatModel: "Модель чата",
            .addModelName: "Добавить имя модели",
            .addModel: "Добавить модель",
            .removeSelectedModel: "Удалить выбранную модель",
            .embeddingModel: "Модель Embedding",
            .useLocalNLEmbeddingOffline: "Локальная векторизация: только NLEmbedding (офлайн, без OpenAI Embedding)",
            .indexingProgress: "Индексация %d/%d",
            .initializeVectorIndex: "Инициализировать/перестроить векторный индекс",
            .rebuildVectorIndexHelp: "Переиндексировать тексты писем и читаемое содержимое вложений",
            .vectorIndexOptionalInfo: "Векторный индекс нужен только для вопросов ИИ и поиска по вложениям. Его можно не инициализировать; базовая почта не пострадает.",
            .vectorizationDisabledStatus: "Векторизация выключена.",
            .vectorizationEnabledZen: "Векторизация включена и будет использовать ZenMux.",
            .vectorizationEnabledLocal: "Векторизация включена и будет использовать локальный NLEmbedding.",
            .vectorizationRebuildingZen: "Векторный индекс перестраивается через ZenMux.",
            .vectorizationRebuildingLocal: "Векторный индекс перестраивается через локальный NLEmbedding.",
            .vectorizationChooseMode: "Перед инициализацией выберите локальную векторизацию или подтвердите удаленную.",
            .vectorizationCancelled: "Включение векторизации отменено.",
            .vectorizationMustEnable: "Сначала включите векторизацию.",
            .vectorizationNoMessages: "Нет писем для векторизации.",
            .vectorizationQueueInitialized: "Очередь векторизации создана для %d писем. Обрабатываются тексты и читаемые вложения.",
            .vectorizationCompletedWithFailures: "Векторизация завершена; не удалось обработать %d писем.",
            .vectorizationCompleted: "Векторизация завершена; проиндексировано %d писем.",
            .vectorizationRemoteFallback: "Векторизация ZenMux не удалась; выполнен переход на локальный NLEmbedding.",
            .vectorizationFailedStatus: "Ошибка векторизации: %@",
            .vectorizationProgressProcessed: "Обработано %d/%d",
            .vectorizationProgressProcessedFailed: "Обработано %d/%d, ошибок %d",
            .accountConnectionInitialFeedback: "Введите почту, пароль и серверы, затем проверьте соединение.",
            .apiKeyInitialFeedback: "Сохраните API-Key, чтобы проверить соединение ZenMux.",
            .apiKeyNotSaved: "Не сохранен",
            .apiKeyEnterValue: "Введите ZenMux API-Key.",
            .apiKeySavedToKeychain: "ZenMux API-Key сохранен в Keychain.",
            .apiKeyMissingSavedKey: "Сначала сохраните API-Key.",
            .chatModelMissing: "Сначала выберите или введите модель чата.",
            .embeddingModelMissing: "Сначала укажите модель Embedding или переключитесь на локальный NLEmbedding.",
            .apiKeyTesting: "Проверка ZenMux API-Key...",
            .apiKeyValidationPassed: "Проверка API-Key успешна.",
            .apiKeyValidationPassedWithResponse: "Проверка API-Key успешна: %@",
            .apiKeyValidationFailed: "Проверка API-Key не удалась: %@",
            .composeMailWindowTitle: "Написать письмо",
            .manualServerNoteGeneric: "Для школьной или корпоративной почты. Можно указать SSL/TLS, STARTTLS или старые порты без шифрования; пароли сохраняются только в Keychain.",
            .providerInlineGeneric: "Для школьной или корпоративной почты. Поддерживает SSL/TLS, STARTTLS или старые порты без шифрования."
        ],
        .swedish: [
            .ready: "Klar",
            .attachmentNotSaved: "Bilagan har inte sparats lokalt",
            .openAttachment: "Öppna bilaga",
            .saveAs: "Spara som...",
            .recipient: "Till",
            .sendingRoute: "Sändningsväg",
            .loadMoreMessages: "Läs in fler",
            .loadingOlderMessages: "Läser in äldre mejl...",
            .noMoreMessages: "Inga fler mejl",
            .cc: "Kopia",
            .subject: "Ämne",
            .aiInstruction: "AI-instruktion",
            .composeInstructionPlaceholder: "Till exempel: tacka nej artigt och föreslå nästa vecka",
            .generateAIDraft: "Skapa AI-utkast",
            .addAttachment: "Lägg till bilaga",
            .send: "Skicka",
            .removeAttachment: "Ta bort bilaga",
            .pendingToSend: "Väntar",
            .needsReauth: "Ny autentisering krävs",
            .deleteAccountConfig: "Radera kontokonfiguration",
            .newAppPassword: "Nytt applösenord",
            .updatePassword: "Uppdatera lösenord",
            .provider: "Leverantör",
            .genericProvider: "Generisk e-post",
            .customProvider: "Anpassad",
            .receivingProtocol: "Mottagningsprotokoll",
            .oauthBrowserLoginNote: "Webbläsarautentisering rekommenderas. Om du använder applösenord, aktivera tvåstegsverifiering först.",
            .appPasswordVisibilityNote: "Applösenord visas oftast bara när de skapas. Klistra in det här; myMail sparar det bara i Keychain.",
            .emailAddress: "E-postadress",
            .appPassword: "Applösenord",
            .browserLogin: "Webbläsarinloggning",
            .documentation: "Dokumentation",
            .saveToken: "Spara token",
            .appPasswordHelp: "Så hämtar du ett applösenord",
            .testingMailConnection: "Testar %@ och SMTP...",
            .connectionTestPassedCanSave: "Anslutningstestet lyckades. Du kan spara kontot.",
            .testConnection: "Testa anslutning",
            .save: "Spara",
            .oauthClientID: "OAuth Client ID",
            .oauthAccessToken: "OAuth2 access token",
            .tlsMode: "TLS-läge",
            .apiKeyLabel: "API-Key",
            .deleteAccountQuestion: "Radera kontokonfiguration?",
            .deleteAccountButton: "Radera %@",
            .deleteAccountWarning: "Detta tar bort kontokonfiguration, lokal cache och Keychain-uppgifter.",
            .port: "Port",
            .noEncryption: "Ingen kryptering",
            .legacyServerHelp: "Äldre servrar kan använda ingen kryptering. Vanliga portar är IMAP 143, POP3 110, SMTP 25.",
            .commonPortsSummary: "Vanliga portar: IMAP 993/143 · SMTP 465/587/25 · POP3 995/110; TLS kan vara SSL/TLS, STARTTLS eller inget.",
            .pop3Unsupported: "POP3 stöds inte",
            .accountInfoChangedRetest: "Kontoinformationen har ändrats. Testa anslutningen igen.",
            .showAPIKey: "Visa API-Key",
            .hideAPIKey: "Dölj API-Key",
            .newZenMuxAPIKey: "Ny ZenMux API-Key",
            .update: "Uppdatera",
            .noAPIKeyYet: "Ingen API-Key än?",
            .openInviteLink: "Öppna inbjudningslänk",
            .testAPIKey: "Testa API-Key",
            .aiOptionalInfo: "AI-modeller används bara för förbättrade funktioner som frågor och utkast. E-post kan skickas och tas emot utan API-Key.",
            .chatModel: "Chattmodell",
            .addModelName: "Lägg till modellnamn",
            .addModel: "Lägg till modell",
            .removeSelectedModel: "Ta bort vald modell",
            .embeddingModel: "Embedding-modell",
            .useLocalNLEmbeddingOffline: "Lokal vektorisering: endast NLEmbedding (offline, ingen OpenAI Embedding)",
            .indexingProgress: "Indexerar %d/%d",
            .initializeVectorIndex: "Initiera/bygg om vektorindex",
            .rebuildVectorIndexHelp: "Indexera om e-posttexter och läsbart bilageinnehåll",
            .vectorIndexOptionalInfo: "Vektorindexet används bara för AI-frågor och bilagesökning. Du kan hoppa över initiering; grundläggande e-post påverkas inte.",
            .accountConnectionInitialFeedback: "Ange e-post, lösenord och servrar och testa sedan anslutningen.",
            .apiKeyInitialFeedback: "Spara en API-Key för att testa ZenMux-anslutning.",
            .apiKeyNotSaved: "Inte sparad",
            .apiKeyEnterValue: "Ange en ZenMux API-Key.",
            .apiKeySavedToKeychain: "ZenMux API-Key sparad i Keychain.",
            .apiKeyMissingSavedKey: "Spara en API-Key först.",
            .chatModelMissing: "Välj eller ange en chattmodell först.",
            .embeddingModelMissing: "Ange en Embedding-modell först eller använd lokal NLEmbedding.",
            .apiKeyTesting: "Testar ZenMux API-Key...",
            .apiKeyValidationPassed: "API-Key-validering lyckades.",
            .apiKeyValidationPassedWithResponse: "API-Key-validering lyckades: %@",
            .apiKeyValidationFailed: "API-Key-validering misslyckades: %@",
            .composeMailWindowTitle: "Skriv e-post",
            .manualServerNoteGeneric: "För skol- eller företagsmail. Du kan ange SSL/TLS, STARTTLS eller äldre okrypterade portar; lösenord sparas bara i Keychain.",
            .providerInlineGeneric: "För skol- eller företagsmail. Stöder SSL/TLS, STARTTLS eller äldre okrypterade portar."
        ],
        .ukrainian: [
            .ready: "Готово",
            .attachmentNotSaved: "Вкладення ще не збережено локально",
            .openAttachment: "Відкрити вкладення",
            .saveAs: "Зберегти як...",
            .recipient: "Кому",
            .sendingRoute: "Шлях надсилання",
            .loadMoreMessages: "Завантажити ще",
            .loadingOlderMessages: "Завантаження старіших листів...",
            .noMoreMessages: "Більше листів немає",
            .cc: "Копія",
            .subject: "Тема",
            .aiInstruction: "Інструкція ШІ",
            .composeInstructionPlaceholder: "Наприклад: ввічливо відмовити й запропонувати наступний тиждень",
            .generateAIDraft: "Створити чернетку ШІ",
            .addAttachment: "Додати вкладення",
            .send: "Надіслати",
            .removeAttachment: "Вилучити вкладення",
            .pendingToSend: "Очікує",
            .needsReauth: "Потрібна повторна автентифікація",
            .deleteAccountConfig: "Видалити налаштування облікового запису",
            .newAppPassword: "Новий пароль застосунку",
            .updatePassword: "Оновити пароль",
            .provider: "Постачальник",
            .genericProvider: "Звичайна пошта",
            .customProvider: "Власний",
            .receivingProtocol: "Протокол отримання",
            .oauthBrowserLoginNote: "Рекомендовано авторизацію в браузері. Для пароля застосунку спершу увімкніть двоетапну перевірку.",
            .appPasswordVisibilityNote: "Паролі застосунків зазвичай видно лише під час створення. Вставте його тут; myMail збереже його тільки в Keychain.",
            .emailAddress: "Адреса пошти",
            .appPassword: "Пароль застосунку",
            .browserLogin: "Вхід у браузері",
            .documentation: "Документація",
            .saveToken: "Зберегти token",
            .appPasswordHelp: "Як отримати пароль застосунку",
            .testingMailConnection: "Перевірка %@ і SMTP...",
            .connectionTestPassedCanSave: "Перевірку з'єднання пройдено. Можна зберегти обліковий запис.",
            .testConnection: "Перевірити з'єднання",
            .save: "Зберегти",
            .oauthClientID: "OAuth Client ID",
            .oauthAccessToken: "OAuth2 access token",
            .tlsMode: "Режим TLS",
            .apiKeyLabel: "API-Key",
            .deleteAccountQuestion: "Видалити налаштування облікового запису?",
            .deleteAccountButton: "Видалити %@",
            .deleteAccountWarning: "Буде видалено налаштування облікового запису, локальний кеш і дані Keychain.",
            .port: "Порт",
            .noEncryption: "Без шифрування",
            .legacyServerHelp: "Старі сервери можуть працювати без шифрування. Поширені порти: IMAP 143, POP3 110, SMTP 25.",
            .commonPortsSummary: "Поширені порти: IMAP 993/143 · SMTP 465/587/25 · POP3 995/110; TLS: SSL/TLS, STARTTLS або без нього.",
            .pop3Unsupported: "POP3 не підтримується",
            .accountInfoChangedRetest: "Дані облікового запису змінено. Перевірте з'єднання ще раз.",
            .showAPIKey: "Показати API-Key",
            .hideAPIKey: "Приховати API-Key",
            .newZenMuxAPIKey: "Новий ZenMux API-Key",
            .update: "Оновити",
            .noAPIKeyYet: "Ще немає API-Key?",
            .openInviteLink: "Відкрити запрошення",
            .testAPIKey: "Перевірити API-Key",
            .aiOptionalInfo: "Моделі ШІ використовуються лише для розширених функцій, як-от питання та чернетки. Надсилання й отримання пошти працює без API-Key.",
            .chatModel: "Модель чату",
            .addModelName: "Додати назву моделі",
            .addModel: "Додати модель",
            .removeSelectedModel: "Вилучити вибрану модель",
            .embeddingModel: "Модель Embedding",
            .useLocalNLEmbeddingOffline: "Локальна векторизація: лише NLEmbedding (офлайн, без OpenAI Embedding)",
            .indexingProgress: "Індексування %d/%d",
            .initializeVectorIndex: "Ініціалізувати/перебудувати векторний індекс",
            .rebuildVectorIndexHelp: "Переіндексувати тексти листів і читабельний вміст вкладень",
            .vectorIndexOptionalInfo: "Векторний індекс потрібен лише для питань ШІ та пошуку у вкладеннях. Його можна не ініціалізувати; базова пошта працюватиме.",
            .accountConnectionInitialFeedback: "Введіть пошту, пароль і сервери, потім перевірте з'єднання.",
            .apiKeyInitialFeedback: "Збережіть API-Key, щоб перевірити з'єднання ZenMux.",
            .apiKeyNotSaved: "Не збережено",
            .apiKeyEnterValue: "Введіть ZenMux API-Key.",
            .apiKeySavedToKeychain: "ZenMux API-Key збережено в Keychain.",
            .apiKeyMissingSavedKey: "Спочатку збережіть API-Key.",
            .chatModelMissing: "Спочатку виберіть або введіть модель чату.",
            .embeddingModelMissing: "Спочатку вкажіть модель Embedding або перейдіть на локальний NLEmbedding.",
            .apiKeyTesting: "Перевірка ZenMux API-Key...",
            .apiKeyValidationPassed: "Перевірку API-Key пройдено.",
            .apiKeyValidationPassedWithResponse: "Перевірку API-Key пройдено: %@",
            .apiKeyValidationFailed: "Перевірка API-Key не вдалася: %@",
            .composeMailWindowTitle: "Написати лист",
            .manualServerNoteGeneric: "Для шкільної або корпоративної пошти. Можна вказати SSL/TLS, STARTTLS або старі незашифровані порти; паролі зберігаються лише в Keychain.",
            .providerInlineGeneric: "Для шкільної або корпоративної пошти. Підтримує SSL/TLS, STARTTLS або старі незашифровані порти."
        ],
        .finnish: [
            .ready: "Valmis",
            .attachmentNotSaved: "Liitettä ei ole vielä tallennettu paikallisesti",
            .openAttachment: "Avaa liite",
            .saveAs: "Tallenna nimellä...",
            .recipient: "Vastaanottaja",
            .sendingRoute: "Lähetysreitti",
            .loadMoreMessages: "Lataa lisää",
            .loadingOlderMessages: "Ladataan vanhempia viestejä...",
            .noMoreMessages: "Ei lisää viestejä",
            .cc: "Kopio",
            .subject: "Aihe",
            .aiInstruction: "AI-ohje",
            .composeInstructionPlaceholder: "Esim. kieltäydy kohteliaasti ja ehdota ensi viikkoa",
            .generateAIDraft: "Luo AI-luonnos",
            .addAttachment: "Lisää liite",
            .send: "Lähetä",
            .removeAttachment: "Poista liite",
            .pendingToSend: "Odottaa",
            .needsReauth: "Uudelleentunnistus vaaditaan",
            .deleteAccountConfig: "Poista tilin asetukset",
            .newAppPassword: "Uusi sovellussalasana",
            .updatePassword: "Päivitä salasana",
            .provider: "Palveluntarjoaja",
            .genericProvider: "Yleinen sähköposti",
            .customProvider: "Mukautettu",
            .receivingProtocol: "Vastaanottoprotokolla",
            .oauthBrowserLoginNote: "Selaimessa tehtävää valtuutusta suositellaan. Jos käytät sovellussalasanaa, ota ensin kaksivaiheinen vahvistus käyttöön.",
            .appPasswordVisibilityNote: "Sovellussalasanat näkyvät yleensä vain luontihetkellä. Liitä se tähän; myMail tallentaa sen vain Keychainiin.",
            .emailAddress: "Sähköpostiosoite",
            .appPassword: "Sovellussalasana",
            .browserLogin: "Selaimella kirjautuminen",
            .documentation: "Ohjeet",
            .saveToken: "Tallenna token",
            .appPasswordHelp: "Miten sovellussalasana haetaan",
            .testingMailConnection: "Testataan %@ ja SMTP...",
            .connectionTestPassedCanSave: "Yhteystesti onnistui. Voit tallentaa tilin.",
            .testConnection: "Testaa yhteys",
            .save: "Tallenna",
            .oauthClientID: "OAuth Client ID",
            .oauthAccessToken: "OAuth2 access token",
            .tlsMode: "TLS-tila",
            .apiKeyLabel: "API-Key",
            .deleteAccountQuestion: "Poistetaanko tilin asetukset?",
            .deleteAccountButton: "Poista %@",
            .deleteAccountWarning: "Tämä poistaa tilin asetukset, paikallisen välimuistin ja Keychain-tunnukset.",
            .port: "Portti",
            .noEncryption: "Ei salausta",
            .legacyServerHelp: "Vanhat palvelimet voivat käyttää salaamatonta yhteyttä. Yleisiä portteja ovat IMAP 143, POP3 110, SMTP 25.",
            .commonPortsSummary: "Yleiset portit: IMAP 993/143 · SMTP 465/587/25 · POP3 995/110; TLS voi olla SSL/TLS, STARTTLS tai ei mitään.",
            .pop3Unsupported: "POP3 ei tuettu",
            .accountInfoChangedRetest: "Tilin tiedot muuttuivat. Testaa yhteys uudelleen.",
            .showAPIKey: "Näytä API-Key",
            .hideAPIKey: "Piilota API-Key",
            .newZenMuxAPIKey: "Uusi ZenMux API-Key",
            .update: "Päivitä",
            .noAPIKeyYet: "Ei vielä API-Keytä?",
            .openInviteLink: "Avaa kutsulinkki",
            .testAPIKey: "Testaa API-Key",
            .aiOptionalInfo: "AI-malleja käytetään vain lisäominaisuuksiin, kuten kysymyksiin ja luonnoksiin. Sähköpostin lähetys ja vastaanotto toimivat ilman API-Keytä.",
            .chatModel: "Keskustelumalli",
            .addModelName: "Lisää mallin nimi",
            .addModel: "Lisää malli",
            .removeSelectedModel: "Poista valittu malli",
            .embeddingModel: "Embedding-malli",
            .useLocalNLEmbeddingOffline: "Paikallinen vektorointi: vain NLEmbedding (offline, ei OpenAI Embeddingiä)",
            .indexingProgress: "Indeksoidaan %d/%d",
            .initializeVectorIndex: "Alusta/rakenna vektori-indeksi",
            .rebuildVectorIndexHelp: "Indeksoi viestien sisällöt ja luettavat liitteet uudelleen",
            .vectorIndexOptionalInfo: "Vektori-indeksi palvelee vain AI-kysymyksiä ja liitteiden sisältöhakua. Sen voi jättää alustamatta; perussähköposti toimii silti.",
            .accountConnectionInitialFeedback: "Syötä sähköposti, salasana ja palvelimet ja testaa yhteys.",
            .apiKeyInitialFeedback: "Tallenna API-Key testataksesi ZenMux-yhteyttä.",
            .apiKeyNotSaved: "Ei tallennettu",
            .apiKeyEnterValue: "Syötä ZenMux API-Key.",
            .apiKeySavedToKeychain: "ZenMux API-Key tallennettu Keychainiin.",
            .apiKeyMissingSavedKey: "Tallenna ensin API-Key.",
            .chatModelMissing: "Valitse tai anna keskustelumalli ensin.",
            .embeddingModelMissing: "Anna ensin Embedding-malli tai vaihda paikalliseen NLEmbeddingiin.",
            .apiKeyTesting: "Testataan ZenMux API-Keytä...",
            .apiKeyValidationPassed: "API-Keyn vahvistus onnistui.",
            .apiKeyValidationPassedWithResponse: "API-Keyn vahvistus onnistui: %@",
            .apiKeyValidationFailed: "API-Keyn vahvistus epäonnistui: %@",
            .composeMailWindowTitle: "Kirjoita viesti",
            .manualServerNoteGeneric: "Koulu- tai yrityspostille. Voit syöttää SSL/TLS-, STARTTLS- tai vanhat salaamattomat portit; salasanat tallennetaan vain Keychainiin.",
            .providerInlineGeneric: "Koulu- tai yrityspostille. Tukee SSL/TLS-, STARTTLS- tai vanhoja salaamattomia portteja."
        ]
    ]
}

struct AppSettings: Codable, Hashable {
    static let defaultChatModels = [
        "anthropic/claude-sonnet-4.6",
        "z-ai/glm-5v-turbo",
        "openai/gpt-5.4"
    ]

    var selectedChatModel = "anthropic/claude-sonnet-4.6"
    var chatModels = Self.defaultChatModels
    var embeddingModel = ""
    var useLocalEmbedding = true
    var pop3PollingMinutes = 5
    var cacheMessageLimit = 200
    var signature = "Sent from myMail"
    var vectorizationEnabled = false
    var vectorizationConsentAccepted = true
    var gmailOAuthClientID = ""
    var outlookOAuthClientID = ""
    var interfaceLanguage: AppLanguage = .simplifiedChinese

    init(
        selectedChatModel: String = "anthropic/claude-sonnet-4.6",
        chatModels: [String] = AppSettings.defaultChatModels,
        embeddingModel: String = "",
        useLocalEmbedding: Bool = true,
        pop3PollingMinutes: Int = 5,
        cacheMessageLimit: Int = 200,
        signature: String = "Sent from myMail",
        vectorizationEnabled: Bool = false,
        vectorizationConsentAccepted: Bool = true,
        gmailOAuthClientID: String = "",
        outlookOAuthClientID: String = "",
        interfaceLanguage: AppLanguage = .simplifiedChinese
    ) {
        self.selectedChatModel = selectedChatModel
        self.chatModels = chatModels
        self.embeddingModel = ""
        self.useLocalEmbedding = true
        self.pop3PollingMinutes = pop3PollingMinutes
        self.cacheMessageLimit = cacheMessageLimit
        self.signature = signature
        self.vectorizationEnabled = vectorizationEnabled
        self.vectorizationConsentAccepted = true
        self.gmailOAuthClientID = gmailOAuthClientID
        self.outlookOAuthClientID = outlookOAuthClientID
        self.interfaceLanguage = interfaceLanguage
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        selectedChatModel = try values.decodeIfPresent(String.self, forKey: .selectedChatModel) ?? "anthropic/claude-sonnet-4.6"
        chatModels = try values.decodeIfPresent([String].self, forKey: .chatModels) ?? Self.defaultChatModels
        embeddingModel = ""
        useLocalEmbedding = true
        pop3PollingMinutes = try values.decodeIfPresent(Int.self, forKey: .pop3PollingMinutes) ?? 5
        cacheMessageLimit = try values.decodeIfPresent(Int.self, forKey: .cacheMessageLimit) ?? 200
        signature = try values.decodeIfPresent(String.self, forKey: .signature) ?? "Sent from myMail"
        vectorizationEnabled = try values.decodeIfPresent(Bool.self, forKey: .vectorizationEnabled) ?? false
        vectorizationConsentAccepted = true
        gmailOAuthClientID = try values.decodeIfPresent(String.self, forKey: .gmailOAuthClientID) ?? ""
        outlookOAuthClientID = try values.decodeIfPresent(String.self, forKey: .outlookOAuthClientID) ?? ""
        interfaceLanguage = try values.decodeIfPresent(AppLanguage.self, forKey: .interfaceLanguage) ?? .simplifiedChinese
    }

    func oauthClientID(for provider: MailProvider) -> String {
        switch provider {
        case .gmail:
            return gmailOAuthClientID
        case .outlook:
            return outlookOAuthClientID
        case .icloud, .generic, .fudan, .custom:
            return ""
        }
    }
}

private final class OAuthLoopbackServer {
    let redirectURI: String

    private let listener: NWListener
    private let queue = DispatchQueue(label: "fudan.miniS.myMail.oauth-loopback")
    private let path: String
    private let callback: @Sendable (URL) -> Void

    init(path: String, callback: @escaping @Sendable (URL) -> Void) throws {
        let port = try Self.availableLoopbackPort()
        self.listener = try NWListener(using: .tcp, on: port)
        self.path = path
        self.callback = callback
        self.redirectURI = "http://127.0.0.1:\(port.rawValue)\(path)"
    }

    func start() {
        listener.newConnectionHandler = { [weak self] connection in
            self?.handle(connection)
        }
        listener.start(queue: queue)
    }

    func stop() {
        listener.cancel()
    }

    private func handle(_ connection: NWConnection) {
        connection.start(queue: queue)
        connection.receive(minimumIncompleteLength: 1, maximumLength: 16_384) { [weak self] data, _, _, _ in
            guard let self else {
                connection.cancel()
                return
            }
            guard
                let data,
                let request = String(data: data, encoding: .utf8),
                let url = self.callbackURL(from: request)
            else {
                self.respond(connection, status: "400 Bad Request", body: "OAuth callback request is invalid.")
                return
            }
            self.callback(url)
            self.respond(connection, status: "200 OK", body: "OAuth 登录完成，可以回到 AISmartmail。")
            self.stop()
        }
    }

    private func callbackURL(from request: String) -> URL? {
        guard let requestLine = request.components(separatedBy: "\r\n").first else { return nil }
        let parts = requestLine.split(separator: " ")
        guard parts.count >= 2, parts[0] == "GET" else { return nil }
        let target = String(parts[1])
        guard target.hasPrefix(path) else { return nil }
        return URL(string: "http://127.0.0.1\(target)")
    }

    private func respond(_ connection: NWConnection, status: String, body: String) {
        let html = """
        <!doctype html><html><head><meta charset="utf-8"><title>AISmartmail OAuth</title></head><body><p>\(body)</p></body></html>
        """
        let response = """
        HTTP/1.1 \(status)\r
        Content-Type: text/html; charset=utf-8\r
        Content-Length: \(html.utf8.count)\r
        Connection: close\r
        \r
        \(html)
        """
        connection.send(content: Data(response.utf8), completion: .contentProcessed { _ in
            connection.cancel()
        })
    }

    private static func availableLoopbackPort() throws -> NWEndpoint.Port {
        let descriptor = socket(AF_INET, SOCK_STREAM, 0)
        guard descriptor >= 0 else {
            throw MailServiceError.connectionFailed("无法创建 OAuth 本地回调端口")
        }
        defer { close(descriptor) }

        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = 0
        address.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))

        let bindResult = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { rebound in
                bind(descriptor, rebound, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bindResult == 0 else {
            throw MailServiceError.connectionFailed("无法绑定 OAuth 本地回调端口")
        }

        var boundAddress = sockaddr_in()
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let nameResult = withUnsafeMutablePointer(to: &boundAddress) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { rebound in
                getsockname(descriptor, rebound, &length)
            }
        }
        guard nameResult == 0 else {
            throw MailServiceError.connectionFailed("无法读取 OAuth 本地回调端口")
        }
        let portNumber = UInt16(bigEndian: boundAddress.sin_port)
        guard let port = NWEndpoint.Port(rawValue: portNumber), portNumber > 0 else {
            throw MailServiceError.connectionFailed("OAuth 本地回调端口无效")
        }
        return port
    }
}

private struct PendingOAuthLogin {
    var provider: MailProvider
    var email: String
    var useProtocol: MailProtocolChoice
    var clientID: String
    var redirectURI: String
    var state: String
    var codeVerifier: String
    var loopbackServer: OAuthLoopbackServer?
}

protocol SettingsStore {
    func loadSettings() -> AppSettings?
    func saveSettings(_ settings: AppSettings)
}

final class UserDefaultsSettingsStore: SettingsStore {
    private let defaults: UserDefaults
    private let key: String

    init(defaults: UserDefaults = .standard, key: String = "myMail.appSettings") {
        self.defaults = defaults
        self.key = key
    }

    func loadSettings() -> AppSettings? {
        guard let data = defaults.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(AppSettings.self, from: data)
    }

    func saveSettings(_ settings: AppSettings) {
        guard let data = try? JSONEncoder().encode(settings) else { return }
        defaults.set(data, forKey: key)
    }
}
