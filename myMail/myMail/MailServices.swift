//
//  MailServices.swift
//  myMail
//

import CryptoKit
import Foundation
import NaturalLanguage
import PDFKit
import Security
import SQLite3

private let sqliteTransient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

private extension String {
    var nilIfEmpty: String? {
        isEmpty ? nil : self
    }
}

protocol SecretStore {
    func save(_ value: String, account: String) throws
    func read(account: String) throws -> String?
    func delete(account: String) throws
}

enum SecretStoreError: LocalizedError {
    case unhandledStatus(OSStatus)
    case invalidData

    var errorDescription: String? {
        switch self {
        case .unhandledStatus(let status):
            return "Keychain 操作失败: \(status)"
        case .invalidData:
            return "Keychain 数据无法解码"
        }
    }
}

final class KeychainStore: SecretStore {
    private let service: String

    init(service: String = Bundle.main.bundleIdentifier ?? "fudan.miniS.myMail") {
        self.service = service
    }

    func save(_ value: String, account: String) throws {
        let data = Data(value.utf8)
        var query = baseQuery(account: account)
        query[kSecValueData as String] = data
        query[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock

        let status = SecItemAdd(query as CFDictionary, nil)
        if status == errSecDuplicateItem {
            let updateStatus = SecItemUpdate(baseQuery(account: account) as CFDictionary, [kSecValueData as String: data] as CFDictionary)
            guard updateStatus == errSecSuccess else { throw SecretStoreError.unhandledStatus(updateStatus) }
            return
        }

        guard status == errSecSuccess else { throw SecretStoreError.unhandledStatus(status) }
    }

    func read(account: String) throws -> String? {
        var query = baseQuery(account: account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else { throw SecretStoreError.unhandledStatus(status) }
        guard let data = item as? Data, let value = String(data: data, encoding: .utf8) else {
            throw SecretStoreError.invalidData
        }
        return value
    }

    func delete(account: String) throws {
        let status = SecItemDelete(baseQuery(account: account) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw SecretStoreError.unhandledStatus(status)
        }
    }

    private func baseQuery(account: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
    }
}

final class MemorySecretStore: SecretStore {
    private var values: [String: String] = [:]

    func save(_ value: String, account: String) throws {
        values[account] = value
    }

    func read(account: String) throws -> String? {
        values[account]
    }

    func delete(account: String) throws {
        values.removeValue(forKey: account)
    }
}

enum OAuth2Error: LocalizedError {
    case unsupportedProvider
    case missingRefreshToken
    case missingClientID
    case expiredAccessToken
    case malformedAuthorizationURL
    case tokenRequestFailed(Int)
    case malformedTokenResponse

    var errorDescription: String? {
        switch self {
        case .unsupportedProvider:
            return "该服务商暂不支持 OAuth2。"
        case .missingRefreshToken:
            return "OAuth2 refresh token 缺失，请重新登录。"
        case .missingClientID:
            return "OAuth2 Client ID 缺失，请先在设置中填写。"
        case .expiredAccessToken:
            return "OAuth2 access token 已过期，请刷新或重新登录。"
        case .malformedAuthorizationURL:
            return "OAuth2 授权链接生成失败。"
        case .tokenRequestFailed(let statusCode):
            return "OAuth2 token 请求失败：HTTP \(statusCode)。"
        case .malformedTokenResponse:
            return "OAuth2 token 响应格式无法解析。"
        }
    }
}

struct OAuthTokenSet: Codable, Hashable, Sendable {
    var accessToken: String
    var refreshToken: String?
    var tokenType: String
    var scope: String?
    var expiresAt: Date?

    var storageString: String {
        (try? String(data: JSONEncoder().encode(self), encoding: .utf8)) ?? accessToken
    }

    func validAccessToken(now: Date = Date(), leeway: TimeInterval = 60) throws -> String {
        if let expiresAt, expiresAt.timeIntervalSince(now) <= leeway {
            throw OAuth2Error.expiredAccessToken
        }
        return accessToken
    }

    static func decodeStoredSecret(_ value: String) throws -> OAuthTokenSet {
        if let data = value.data(using: .utf8),
           let tokenSet = try? JSONDecoder().decode(OAuthTokenSet.self, from: data) {
            return tokenSet
        }
        return OAuthTokenSet(accessToken: value, refreshToken: nil, tokenType: "Bearer", scope: nil, expiresAt: nil)
    }
}

struct OAuthPKCEPair: Hashable, Sendable {
    var verifier: String
    var challenge: String
}

typealias OAuthClientIDProvider = (MailProvider) -> String

struct OAuth2Service {
    var session: URLSession = .shared
    var now: @Sendable () -> Date = Date.init

    func makePKCEPair(verifier: String? = nil) -> OAuthPKCEPair {
        let resolvedVerifier = verifier ?? randomVerifier()
        let digest = SHA256.hash(data: Data(resolvedVerifier.utf8))
        let challenge = Data(digest).base64URLEncodedString()
        return OAuthPKCEPair(verifier: resolvedVerifier, challenge: challenge)
    }

    func makeAuthorizationURL(
        provider: MailProvider,
        clientID: String,
        redirectURI: String,
        state: String,
        codeChallenge: String? = nil,
        scopes customScopes: [String]? = nil
    ) throws -> URL {
        let config = try OAuthProviderConfiguration(provider: provider)
        var components = URLComponents(url: config.authorizationEndpoint, resolvingAgainstBaseURL: false)
        var queryItems = [
            URLQueryItem(name: "client_id", value: clientID),
            URLQueryItem(name: "redirect_uri", value: redirectURI),
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "scope", value: (customScopes ?? config.scopes).joined(separator: " ")),
            URLQueryItem(name: "state", value: state)
        ]
        if provider == .gmail {
            queryItems.append(URLQueryItem(name: "access_type", value: "offline"))
            queryItems.append(URLQueryItem(name: "prompt", value: "consent"))
        }
        if let codeChallenge {
            queryItems.append(URLQueryItem(name: "code_challenge", value: codeChallenge))
            queryItems.append(URLQueryItem(name: "code_challenge_method", value: "S256"))
        }
        components?.queryItems = queryItems
        guard let url = components?.url else { throw OAuth2Error.malformedAuthorizationURL }
        return url
    }

    func exchangeCode(
        provider: MailProvider,
        clientID: String,
        clientSecret: String? = nil,
        code: String,
        redirectURI: String,
        codeVerifier: String? = nil
    ) async throws -> OAuthTokenSet {
        var fields = [
            "client_id": clientID,
            "code": code,
            "redirect_uri": redirectURI,
            "grant_type": "authorization_code"
        ]
        if let clientSecret, !clientSecret.isEmpty {
            fields["client_secret"] = clientSecret
        }
        if let codeVerifier, !codeVerifier.isEmpty {
            fields["code_verifier"] = codeVerifier
        }
        return try await tokenRequest(provider: provider, fields: fields)
    }

    func refreshAccessToken(
        provider: MailProvider,
        clientID: String,
        clientSecret: String? = nil,
        refreshToken: String
    ) async throws -> OAuthTokenSet {
        guard !refreshToken.isEmpty else { throw OAuth2Error.missingRefreshToken }
        var fields = [
            "client_id": clientID,
            "refresh_token": refreshToken,
            "grant_type": "refresh_token"
        ]
        if let clientSecret, !clientSecret.isEmpty {
            fields["client_secret"] = clientSecret
        }
        var refreshed = try await tokenRequest(provider: provider, fields: fields)
        if refreshed.refreshToken == nil {
            refreshed.refreshToken = refreshToken
        }
        return refreshed
    }

    private func tokenRequest(provider: MailProvider, fields: [String: String]) async throws -> OAuthTokenSet {
        let config = try OAuthProviderConfiguration(provider: provider)
        var request = URLRequest(url: config.tokenEndpoint)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded; charset=utf-8", forHTTPHeaderField: "Content-Type")
        request.httpBody = formURLEncoded(fields).data(using: .utf8)

        let (data, response) = try await session.data(for: request)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw OAuth2Error.tokenRequestFailed(http.statusCode)
        }
        let decoded = try JSONDecoder().decode(OAuthTokenResponse.self, from: data)
        guard !decoded.accessToken.isEmpty else { throw OAuth2Error.malformedTokenResponse }
        return OAuthTokenSet(
            accessToken: decoded.accessToken,
            refreshToken: decoded.refreshToken,
            tokenType: decoded.tokenType ?? "Bearer",
            scope: decoded.scope,
            expiresAt: decoded.expiresIn.map { now().addingTimeInterval(TimeInterval($0)) }
        )
    }

    private func formURLEncoded(_ fields: [String: String]) -> String {
        fields
            .sorted { $0.key < $1.key }
            .map { key, value in "\(percentEncode(key))=\(percentEncode(value))" }
            .joined(separator: "&")
    }

    private func percentEncode(_ value: String) -> String {
        var allowed = CharacterSet.urlQueryAllowed
        allowed.remove(charactersIn: ":#[]@!$&'()*+,;=")
        return value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
    }

    private func randomVerifier() -> String {
        let alphabet = Array("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-._~")
        return String((0..<64).compactMap { _ in alphabet.randomElement() })
    }
}

private extension Data {
    func base64URLEncodedString() -> String {
        base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}

private struct OAuthProviderConfiguration {
    var authorizationEndpoint: URL
    var tokenEndpoint: URL
    var scopes: [String]

    init(provider: MailProvider) throws {
        switch provider {
        case .gmail:
            authorizationEndpoint = URL(string: "https://accounts.google.com/o/oauth2/v2/auth")!
            tokenEndpoint = URL(string: "https://oauth2.googleapis.com/token")!
            scopes = ["https://mail.google.com/"]
        case .outlook:
            authorizationEndpoint = URL(string: "https://login.microsoftonline.com/common/oauth2/v2.0/authorize")!
            tokenEndpoint = URL(string: "https://login.microsoftonline.com/common/oauth2/v2.0/token")!
            scopes = [
                "https://outlook.office.com/IMAP.AccessAsUser.All",
                "https://outlook.office.com/POP.AccessAsUser.All",
                "https://outlook.office.com/SMTP.Send",
                "offline_access"
            ]
        case .icloud, .generic, .fudan, .custom:
            throw OAuth2Error.unsupportedProvider
        }
    }
}

private struct OAuthTokenResponse: Decodable {
    var accessToken: String
    var refreshToken: String?
    var tokenType: String?
    var expiresIn: Int?
    var scope: String?

    private enum CodingKeys: String, CodingKey {
        case accessToken = "access_token"
        case refreshToken = "refresh_token"
        case tokenType = "token_type"
        case expiresIn = "expires_in"
        case scope
    }
}

struct MailCredentialResolver {
    private let secretStore: SecretStore
    private let oauth2Service: OAuth2Service
    private let oauthClientIDProvider: OAuthClientIDProvider

    init(
        secretStore: SecretStore,
        oauth2Service: OAuth2Service = OAuth2Service(),
        oauthClientIDProvider: @escaping OAuthClientIDProvider = { _ in "" }
    ) {
        self.secretStore = secretStore
        self.oauth2Service = oauth2Service
        self.oauthClientIDProvider = oauthClientIDProvider
    }

    func authSecret(for account: MailAccount) async throws -> String? {
        switch account.authType {
        case .oauth2:
            return try await oauthSecret(for: account)
        case .password, .appPassword:
            return try secretStore.read(account: "account.\(account.id.uuidString).password")
        }
    }

    private func oauthSecret(for account: MailAccount) async throws -> String? {
        guard let ref = account.oauthRefreshTokenRef else { return nil }
        guard let stored = try secretStore.read(account: ref) else { return nil }
        let tokenSet = try OAuthTokenSet.decodeStoredSecret(stored)
        do {
            return try tokenSet.validAccessToken(now: oauth2Service.now())
        } catch OAuth2Error.expiredAccessToken {
            guard let refreshToken = tokenSet.refreshToken, !refreshToken.isEmpty else {
                throw OAuth2Error.missingRefreshToken
            }
            let clientID = oauthClientIDProvider(account.provider).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !clientID.isEmpty else { throw OAuth2Error.missingClientID }
            let refreshed = try await oauth2Service.refreshAccessToken(
                provider: account.provider,
                clientID: clientID,
                refreshToken: refreshToken
            )
            try secretStore.save(refreshed.storageString, account: ref)
            return refreshed.accessToken
        }
    }
}

protocol MailService {
    func connect(_ account: MailAccount) async throws
    func testConnection(_ account: MailAccount, password: String) async throws
    func testIncomingConnection(_ account: MailAccount, password: String) async throws
    func testOutgoingConnection(_ account: MailAccount, password: String) async throws
    func fetchMailboxes() async throws -> [Mailbox]
    func fetchLatestHeaders(mailbox: Mailbox, limit: Int) async throws -> [MessageHeader]
    func fetchHeadersBefore(mailbox: Mailbox, beforeUID: Int64, limit: Int) async throws -> [MessageHeader]
    func fetchHeaders(mailbox: Mailbox, uidRange: ClosedRange<Int64>) async throws -> [MessageHeader]
    func fetchBody(mailbox: Mailbox, uid: Int64) async throws -> MessageBody
    func setFlags(mailbox: Mailbox, uid: Int64, flags: MessageFlags) async throws
    func moveMessage(uid: Int64, from sourceMailbox: Mailbox, to targetMailbox: Mailbox) async throws
    func deleteMessage(uid: Int64, from mailbox: Mailbox) async throws
    func saveDraft(_ draft: OutgoingMessage, to draftsMailbox: Mailbox) async throws -> Int64?
    func sendMessage(_ draft: OutgoingMessage, appendTo sentMailbox: Mailbox?) async throws
    func idle(mailbox: Mailbox) -> AsyncStream<MailboxEvent>
}

enum MailboxEvent: Hashable, Sendable {
    case exists(Int)
    case expunge(Int64)
    case flagsChanged(uid: Int64, flags: MessageFlags)
}

actor NativeMailService: @preconcurrency MailService {
    private let credentialResolver: MailCredentialResolver
    private let mimeBuilder = SMTPMIMEBuilder()
    private var connectedAccount: MailAccount?
    private var authSecret: String?
    private var activeMailbox: Mailbox?

    init(
        secretStore: SecretStore = KeychainStore(),
        oauth2Service: OAuth2Service = OAuth2Service(),
        oauthClientIDProvider: @escaping OAuthClientIDProvider = { _ in "" }
    ) {
        self.credentialResolver = MailCredentialResolver(
            secretStore: secretStore,
            oauth2Service: oauth2Service,
            oauthClientIDProvider: oauthClientIDProvider
        )
    }

    func connect(_ account: MailAccount) async throws {
        guard let secret = try await credentialResolver.authSecret(for: account), !secret.isEmpty else {
            throw MailServiceError.missingPassword
        }
        try await testIncomingConnection(account, password: secret)
        connectedAccount = account
        authSecret = secret
    }

    func testConnection(_ account: MailAccount, password: String) async throws {
        try await testIncomingConnection(account, password: password)
        try await testOutgoingConnection(account, password: password)
    }

    func testIncomingConnection(_ account: MailAccount, password: String) async throws {
        let credentials = MailConnectionCredentials(username: account.emailAddress, secret: password, authType: account.authType)
        switch account.useProtocol {
        case .imap:
            try IMAPClient(endpoint: account.imap, credentials: credentials).verify()
        case .pop3:
            guard let pop3 = account.pop3 else {
                throw MailServiceError.malformedServerResponse("该服务商未提供 POP3 配置")
            }
            try POP3Client(endpoint: pop3, credentials: credentials).verify()
        }
    }

    func testOutgoingConnection(_ account: MailAccount, password: String) async throws {
        let credentials = MailConnectionCredentials(username: account.emailAddress, secret: password, authType: account.authType)
        try trySMTPFallbacks(for: account, credentials: credentials) { client in
            try client.verify(from: account.emailAddress)
        }
    }

    func fetchMailboxes() async throws -> [Mailbox] {
        let (account, credentials) = try await connectedContext()
        switch account.useProtocol {
        case .imap:
            return try IMAPClient(endpoint: account.imap, credentials: credentials).fetchMailboxes(accountId: account.id)
        case .pop3:
            guard let pop3 = account.pop3 else {
                throw MailServiceError.malformedServerResponse("该服务商未提供 POP3 配置")
            }
            return try POP3Client(endpoint: pop3, credentials: credentials).fetchMailboxes(accountId: account.id)
        }
    }

    func fetchHeaders(mailbox: Mailbox, uidRange: ClosedRange<Int64>) async throws -> [MessageHeader] {
        activeMailbox = mailbox
        let (account, credentials) = try await connectedContext()
        switch account.useProtocol {
        case .imap:
            return try IMAPClient(endpoint: account.imap, credentials: credentials).fetchHeaders(mailbox: mailbox, uidRange: uidRange)
        case .pop3:
            guard let pop3 = account.pop3 else {
                throw MailServiceError.malformedServerResponse("该服务商未提供 POP3 配置")
            }
            let limit = max(Int(uidRange.upperBound - uidRange.lowerBound + 1), 1)
            return try POP3Client(endpoint: pop3, credentials: credentials).fetchHeaders(limit: limit)
        }
    }

    func fetchLatestHeaders(mailbox: Mailbox, limit: Int) async throws -> [MessageHeader] {
        activeMailbox = mailbox
        let (account, credentials) = try await connectedContext()
        switch account.useProtocol {
        case .imap:
            return try IMAPClient(endpoint: account.imap, credentials: credentials).fetchLatestHeaders(mailbox: mailbox, limit: limit)
        case .pop3:
            guard let pop3 = account.pop3 else {
                throw MailServiceError.malformedServerResponse("该服务商未提供 POP3 配置")
            }
            return try POP3Client(endpoint: pop3, credentials: credentials).fetchHeaders(limit: limit)
        }
    }

    func fetchHeadersBefore(mailbox: Mailbox, beforeUID: Int64, limit: Int) async throws -> [MessageHeader] {
        activeMailbox = mailbox
        let (account, credentials) = try await connectedContext()
        switch account.useProtocol {
        case .imap:
            return try IMAPClient(endpoint: account.imap, credentials: credentials).fetchHeadersBefore(mailbox: mailbox, beforeUID: beforeUID, limit: limit)
        case .pop3:
            return []
        }
    }

    func fetchBody(mailbox: Mailbox, uid: Int64) async throws -> MessageBody {
        activeMailbox = mailbox
        let (account, credentials) = try await connectedContext()
        switch account.useProtocol {
        case .imap:
            return try IMAPClient(endpoint: account.imap, credentials: credentials).fetchBody(mailbox: mailbox, uid: uid)
        case .pop3:
            guard let pop3 = account.pop3 else {
                throw MailServiceError.malformedServerResponse("该服务商未提供 POP3 配置")
            }
            return try POP3Client(endpoint: pop3, credentials: credentials).fetchBody(messageNumber: Int(uid))
        }
    }

    func setFlags(mailbox: Mailbox, uid: Int64, flags: MessageFlags) async throws {
        activeMailbox = mailbox
        let (account, credentials) = try await connectedContext()
        switch account.useProtocol {
        case .imap:
            try IMAPClient(endpoint: account.imap, credentials: credentials).setFlags(mailbox: mailbox, uid: uid, flags: flags)
        case .pop3:
            throw MailServiceError.malformedServerResponse("POP3 不支持远程标记邮件状态")
        }
    }

    func moveMessage(uid: Int64, from sourceMailbox: Mailbox, to targetMailbox: Mailbox) async throws {
        activeMailbox = sourceMailbox
        let (account, credentials) = try await connectedContext()
        switch account.useProtocol {
        case .imap:
            try IMAPClient(endpoint: account.imap, credentials: credentials).moveMessage(mailbox: sourceMailbox, uid: uid, target: targetMailbox)
        case .pop3:
            throw MailServiceError.malformedServerResponse("POP3 不支持移动邮件")
        }
    }

    func deleteMessage(uid: Int64, from mailbox: Mailbox) async throws {
        activeMailbox = mailbox
        let (account, credentials) = try await connectedContext()
        switch account.useProtocol {
        case .imap:
            try IMAPClient(endpoint: account.imap, credentials: credentials).deleteMessage(mailbox: mailbox, uid: uid)
        case .pop3:
            throw MailServiceError.malformedServerResponse("POP3 不支持删除远程邮件")
        }
    }

    func saveDraft(_ draft: OutgoingMessage, to draftsMailbox: Mailbox) async throws -> Int64? {
        let (account, credentials) = try await connectedContext()
        guard account.useProtocol == .imap else {
            throw MailServiceError.malformedServerResponse("POP3 不支持同步远程草稿")
        }
        let data = try mimeBuilder.makeMessage(from: account, draft: draft)
        return try IMAPClient(endpoint: account.imap, credentials: credentials).appendMessage(data, to: draftsMailbox, flags: [.draft])
    }

    func sendMessage(_ draft: OutgoingMessage, appendTo sentMailbox: Mailbox?) async throws {
        let (account, credentials) = try await connectedContext()
        let recipients = draft.to + draft.cc + draft.bcc
        guard !recipients.isEmpty else {
            throw MailServiceError.malformedServerResponse("缺少收件人")
        }
        let data = try mimeBuilder.makeMessage(from: account, draft: draft)
        try trySMTPFallbacks(for: account, credentials: credentials) { client in
            try client.send(message: data, from: account.emailAddress, recipients: recipients)
        }
        if account.useProtocol == .imap, let sentMailbox {
            _ = try IMAPClient(endpoint: account.imap, credentials: credentials).appendMessage(data, to: sentMailbox)
        }
    }

    func idle(mailbox: Mailbox) -> AsyncStream<MailboxEvent> {
        return AsyncStream { continuation in
            let task = Task.detached {
                do {
                    let (account, credentials) = try await self.connectedContext()
                    guard account.useProtocol == .imap else {
                        continuation.finish()
                        return
                    }
                    let endpoint = account.imap
                    try IMAPClient(endpoint: endpoint, credentials: credentials).idle(mailbox: mailbox) { event in
                        continuation.yield(event)
                        return !Task.isCancelled
                    }
                    continuation.finish()
                } catch {
                    continuation.finish()
                }
            }
            continuation.onTermination = { _ in
                task.cancel()
            }
        }
    }

    private func connectedContext() async throws -> (MailAccount, MailConnectionCredentials) {
        guard let account = connectedAccount else { throw MailServiceError.missingConnectedAccount }
        guard let secret = try await credentialResolver.authSecret(for: account), !secret.isEmpty else {
            throw MailServiceError.missingPassword
        }
        authSecret = secret
        return (account, MailConnectionCredentials(username: account.emailAddress, secret: secret, authType: account.authType))
    }

    private func trySMTPFallbacks(
        for account: MailAccount,
        credentials: MailConnectionCredentials,
        operation: (SMTPClient) throws -> Void
    ) throws {
        var lastError: Error?
        for endpoint in smtpFallbackEndpoints(for: account) {
            do {
                try operation(SMTPClient(endpoint: endpoint, credentials: credentials))
                return
            } catch {
                lastError = error
            }
        }
        throw lastError ?? MailServiceError.connectionFailed(account.smtp.label)
    }

    private func smtpFallbackEndpoints(for account: MailAccount) -> [ServerEndpoint] {
        var endpoints: [ServerEndpoint]
        if account.provider == .gmail {
            endpoints = [
                ServerEndpoint(host: "smtp.gmail.com", port: 465, tlsMode: "SSL"),
                account.smtp,
                ServerEndpoint(host: "smtp.gmail.com", port: 587, tlsMode: "STARTTLS")
            ]
        } else {
            endpoints = [account.smtp]
        }
        var seen = Set<String>()
        return endpoints.filter { endpoint in
            let key = "\(endpoint.host.lowercased()):\(endpoint.port):\(endpoint.normalizedTLSMode)"
            return seen.insert(key).inserted
        }
    }
}

protocol AIService {
    func chat(model: String, messages: [ChatMessage], stream: Bool) -> AsyncThrowingStream<String, Error>
    func embed(model: String, texts: [String]) async throws -> [[Float]]
}

enum AIServiceError: LocalizedError {
    case missingAPIKey
    case malformedResponse

    var errorDescription: String? {
        switch self {
        case .missingAPIKey: return "请先在设置中保存 ZenMux API-Key"
        case .malformedResponse: return "AI 服务返回格式无法解析"
        }
    }
}

final class ZenMuxAIService: AIService {
    private let baseURL: URL
    private let secretStore: SecretStore
    private let session: URLSession

    init(
        baseURL: URL = URL(string: "https://zenmux.ai/api/v1")!,
        secretStore: SecretStore = KeychainStore(),
        session: URLSession = .shared
    ) {
        self.baseURL = baseURL
        self.secretStore = secretStore
        self.session = session
    }

    func chat(model: String, messages: [ChatMessage], stream: Bool) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            Task {
                do {
                    let apiKey = try requireAPIKey()
                    var request = URLRequest(url: baseURL.appendingPathComponent("chat/completions"))
                    request.httpMethod = "POST"
                    request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
                    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
                    request.httpBody = try JSONEncoder().encode(ChatRequest(model: model, messages: messages, stream: stream))

                    if stream {
                        let (bytes, _) = try await session.bytes(for: request)
                        for try await line in bytes.lines {
                            guard line.hasPrefix("data: ") else { continue }
                            let payload = String(line.dropFirst(6))
                            if payload == "[DONE]" { break }
                            guard let data = payload.data(using: .utf8) else { continue }
                            if let chunk = try? JSONDecoder().decode(ChatStreamChunk.self, from: data),
                               let content = chunk.choices.first?.delta.content {
                                continuation.yield(content)
                            }
                        }
                        continuation.finish()
                    } else {
                        let (data, _) = try await session.data(for: request)
                        let response = try JSONDecoder().decode(ChatResponse.self, from: data)
                        guard let content = response.choices.first?.message.content else {
                            throw AIServiceError.malformedResponse
                        }
                        continuation.yield(content)
                        continuation.finish()
                    }
                } catch {
                    continuation.finish(throwing: error)
                }
            }
        }
    }

    func embed(model: String, texts: [String]) async throws -> [[Float]] {
        let apiKey = try requireAPIKey()
        var request = URLRequest(url: baseURL.appendingPathComponent("embeddings"))
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(EmbeddingRequest(model: model, input: texts))

        let (data, _) = try await session.data(for: request)
        let response = try JSONDecoder().decode(EmbeddingResponse.self, from: data)
        return response.data.sorted { $0.index < $1.index }.map(\.embedding)
    }

    private func requireAPIKey() throws -> String {
        guard let apiKey = try secretStore.read(account: "zenmux.apikey"), !apiKey.isEmpty else {
            throw AIServiceError.missingAPIKey
        }
        return apiKey
    }
}

private struct ChatRequest: Encodable {
    var model: String
    var messages: [ChatMessage]
    var stream: Bool
}

private struct ChatResponse: Decodable {
    struct Choice: Decodable {
        struct Message: Decodable {
            var content: String
        }

        var message: Message
    }

    var choices: [Choice]
}

private struct ChatStreamChunk: Decodable {
    struct Choice: Decodable {
        struct Delta: Decodable {
            var content: String?
        }

        var delta: Delta
    }

    var choices: [Choice]
}

private struct EmbeddingRequest: Encodable {
    var model: String
    var input: [String]
}

private struct EmbeddingResponse: Decodable {
    struct Item: Decodable {
        var index: Int
        var embedding: [Float]
    }

    var data: [Item]
}

protocol EmbeddingService {
    func embed(texts: [String]) async throws -> [[Float]]
}

struct ZenMuxEmbeddingService: EmbeddingService {
    var aiService: AIService
    var model: String

    func embed(texts: [String]) async throws -> [[Float]] {
        try await aiService.embed(model: model, texts: texts)
    }
}

struct LocalNLEmbeddingService: EmbeddingService {
    func embed(texts: [String]) async throws -> [[Float]] {
        await Task.detached(priority: .utility) {
            let embedding = NLEmbedding.sentenceEmbedding(for: .english)
            return texts.map { text in
                if let vector = embedding?.vector(for: text) {
                    return vector.map(Float.init)
                }
                return Self.fallbackVector(for: text)
            }
        }.value
    }

    private static func fallbackVector(for text: String) -> [Float] {
        var buckets = Array(repeating: Float(0), count: 64)
        for scalar in text.unicodeScalars {
            let index = Int(scalar.value) % buckets.count
            buckets[index] += 1
        }
        return VectorMath.normalized(buckets)
    }
}

protocol VectorStore {
    func upsert(messageId: UUID, embedding: [Float]) throws
    func topK(query: [Float], k: Int, allowedMessageIDs: Set<UUID>?) throws -> [VectorMatch]
}

final class InMemoryVectorStore: VectorStore {
    private var values: [UUID: [Float]] = [:]

    func upsert(messageId: UUID, embedding: [Float]) throws {
        values[messageId] = VectorMath.normalized(embedding)
    }

    func topK(query: [Float], k: Int, allowedMessageIDs: Set<UUID>? = nil) throws -> [VectorMatch] {
        let normalizedQuery = VectorMath.normalized(query)
        return values.compactMap { messageId, vector in
            if let allowedMessageIDs, !allowedMessageIDs.contains(messageId) { return nil }
            return VectorMatch(messageId: messageId, score: VectorMath.cosine(normalizedQuery, vector))
        }
        .sorted { $0.score > $1.score }
        .prefix(k)
        .map { $0 }
    }
}

final class SQLiteVectorStore: VectorStore {
    enum Backend: Equatable {
        case sqliteVec
        case jsonFallback
    }

    private var database: OpaquePointer?
    private(set) var backend: Backend = .jsonFallback

    init(url: URL, preferSQLiteVec: Bool = true) throws {
        guard sqlite3_open(url.path, &database) == SQLITE_OK else {
            throw VectorStoreError.openFailed
        }
        try execute("CREATE TABLE IF NOT EXISTS vector_store_metadata(key TEXT PRIMARY KEY, value TEXT NOT NULL);")

        if preferSQLiteVec, !hasLegacyJSONVectorTable(), prepareSQLiteVecIfAvailable() {
            backend = .sqliteVec
        } else {
            backend = .jsonFallback
            try prepareJSONFallbackTable()
        }
    }

    deinit {
        sqlite3_close(database)
    }

    func upsert(messageId: UUID, embedding: [Float]) throws {
        let normalized = VectorMath.normalized(embedding)
        switch backend {
        case .sqliteVec:
            do {
                try ensureSQLiteVecTable(dimension: normalized.count)
                try upsertSQLiteVec(messageId: messageId, embedding: normalized)
            } catch {
                backend = .jsonFallback
                try prepareJSONFallbackTable()
                try upsertJSON(messageId: messageId, embedding: normalized)
            }
        case .jsonFallback:
            try upsertJSON(messageId: messageId, embedding: normalized)
        }
    }

    func topK(query: [Float], k: Int, allowedMessageIDs: Set<UUID>? = nil) throws -> [VectorMatch] {
        let normalizedQuery = VectorMath.normalized(query)
        switch backend {
        case .sqliteVec:
            do {
                return try topKSQLiteVec(query: normalizedQuery, k: k, allowedMessageIDs: allowedMessageIDs)
            } catch {
                backend = .jsonFallback
                try prepareJSONFallbackTable()
                return try topKJSON(query: normalizedQuery, k: k, allowedMessageIDs: allowedMessageIDs)
            }
        case .jsonFallback:
            return try topKJSON(query: normalizedQuery, k: k, allowedMessageIDs: allowedMessageIDs)
        }
    }

    private func prepareSQLiteVecIfAvailable() -> Bool {
        loadSQLiteVecExtensionIfPresent()
        do {
            try execute("CREATE VIRTUAL TABLE temp.mymail_vec_probe USING vec0(embedding FLOAT[3]);")
            try execute("DROP TABLE temp.mymail_vec_probe;")
            return true
        } catch {
            return false
        }
    }

    private func loadSQLiteVecExtensionIfPresent() {
        // The system SQLite module used by Swift does not expose extension loading.
        // If sqlite-vec is statically registered or otherwise available, the vec0 probe succeeds.
    }

    private func ensureSQLiteVecTable(dimension: Int) throws {
        let existingDimension = metadataValue(for: "sqlite_vec_dimension").flatMap(Int.init)
        if existingDimension == dimension, tableExists("message_vectors") { return }
        if let existingDimension, existingDimension != dimension {
            try execute("DROP TABLE IF EXISTS message_vectors;")
        }
        let sql = """
        CREATE VIRTUAL TABLE IF NOT EXISTS message_vectors USING vec0(
          message_id TEXT PRIMARY KEY,
          embedding FLOAT[\(dimension)]
        );
        """
        try execute(sql)
        try setMetadataValue(String(dimension), for: "sqlite_vec_dimension")
        try setMetadataValue("sqlite-vec", for: "vector_backend")
    }

    private func prepareJSONFallbackTable() throws {
        try execute("""
        CREATE TABLE IF NOT EXISTS message_vectors_json(
          message_id TEXT PRIMARY KEY,
          embedding_json TEXT NOT NULL
        );
        """)
        try migrateLegacyJSONTableIfNeeded()
        try setMetadataValue("json-fallback", for: "vector_backend")
    }

    private func migrateLegacyJSONTableIfNeeded() throws {
        let columns = columns(in: "message_vectors")
        guard columns.contains("embedding_json") else { return }
        try execute("""
        INSERT OR REPLACE INTO message_vectors_json(message_id, embedding_json)
        SELECT message_id, embedding_json FROM message_vectors;
        """)
    }

    private func hasLegacyJSONVectorTable() -> Bool {
        columns(in: "message_vectors").contains("embedding_json")
    }

    private func upsertSQLiteVec(messageId: UUID, embedding: [Float]) throws {
        var statement: OpaquePointer?
        let sql = "INSERT OR REPLACE INTO message_vectors(message_id, embedding) VALUES(?, ?);"
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK else {
            throw VectorStoreError.prepareFailed
        }
        defer { sqlite3_finalize(statement) }

        let blob = vectorBlob(embedding)
        sqlite3_bind_text(statement, 1, messageId.uuidString, -1, sqliteTransient)
        _ = blob.withUnsafeBytes { bytes in
            sqlite3_bind_blob(statement, 2, bytes.baseAddress, Int32(blob.count), sqliteTransient)
        }
        guard sqlite3_step(statement) == SQLITE_DONE else { throw VectorStoreError.writeFailed }
    }

    private func upsertJSON(messageId: UUID, embedding: [Float]) throws {
        let data = try JSONEncoder().encode(embedding)
        guard let json = String(data: data, encoding: .utf8) else { throw VectorStoreError.encodingFailed }

        var statement: OpaquePointer?
        let sql = "INSERT OR REPLACE INTO message_vectors_json(message_id, embedding_json) VALUES(?, ?);"
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK else {
            throw VectorStoreError.prepareFailed
        }
        defer { sqlite3_finalize(statement) }

        sqlite3_bind_text(statement, 1, messageId.uuidString, -1, sqliteTransient)
        sqlite3_bind_text(statement, 2, json, -1, sqliteTransient)
        guard sqlite3_step(statement) == SQLITE_DONE else { throw VectorStoreError.writeFailed }
    }

    private func topKSQLiteVec(query: [Float], k: Int, allowedMessageIDs: Set<UUID>?) throws -> [VectorMatch] {
        guard tableExists("message_vectors") else { return [] }
        let searchLimit = max(k, allowedMessageIDs?.count ?? k, 1)
        var statement: OpaquePointer?
        let sql = "SELECT message_id, distance FROM message_vectors WHERE embedding MATCH ? AND k = ?;"
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK else {
            throw VectorStoreError.prepareFailed
        }
        defer { sqlite3_finalize(statement) }

        let blob = vectorBlob(query)
        _ = blob.withUnsafeBytes { bytes in
            sqlite3_bind_blob(statement, 1, bytes.baseAddress, Int32(blob.count), sqliteTransient)
        }
        sqlite3_bind_int(statement, 2, Int32(searchLimit))

        var matches: [VectorMatch] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            guard let idPointer = sqlite3_column_text(statement, 0),
                  let id = UUID(uuidString: String(cString: idPointer)) else { continue }
            if let allowedMessageIDs, !allowedMessageIDs.contains(id) { continue }
            let distance = sqlite3_column_double(statement, 1)
            matches.append(VectorMatch(messageId: id, score: -distance))
        }
        return Array(matches.prefix(k))
    }

    private func topKJSON(query normalizedQuery: [Float], k: Int, allowedMessageIDs: Set<UUID>? = nil) throws -> [VectorMatch] {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, "SELECT message_id, embedding_json FROM message_vectors_json;", -1, &statement, nil) == SQLITE_OK else {
            throw VectorStoreError.prepareFailed
        }
        defer { sqlite3_finalize(statement) }

        var matches: [VectorMatch] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            guard
                let idPointer = sqlite3_column_text(statement, 0),
                let jsonPointer = sqlite3_column_text(statement, 1),
                let id = UUID(uuidString: String(cString: idPointer))
            else { continue }
            if let allowedMessageIDs, !allowedMessageIDs.contains(id) { continue }

            let json = String(cString: jsonPointer)
            guard let data = json.data(using: .utf8),
                  let vector = try? JSONDecoder().decode([Float].self, from: data) else { continue }
            matches.append(VectorMatch(messageId: id, score: VectorMath.cosine(normalizedQuery, vector)))
        }

        return matches.sorted { $0.score > $1.score }.prefix(k).map { $0 }
    }

    private func tableExists(_ name: String) -> Bool {
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }
        guard sqlite3_prepare_v2(database, "SELECT name FROM sqlite_master WHERE name = ? LIMIT 1;", -1, &statement, nil) == SQLITE_OK else {
            return false
        }
        sqlite3_bind_text(statement, 1, name, -1, sqliteTransient)
        return sqlite3_step(statement) == SQLITE_ROW
    }

    private func columns(in table: String) -> Set<String> {
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }
        guard sqlite3_prepare_v2(database, "PRAGMA table_info(\(table));", -1, &statement, nil) == SQLITE_OK else {
            return []
        }
        var names = Set<String>()
        while sqlite3_step(statement) == SQLITE_ROW {
            guard let pointer = sqlite3_column_text(statement, 1) else { continue }
            names.insert(String(cString: pointer))
        }
        return names
    }

    private func metadataValue(for key: String) -> String? {
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }
        guard sqlite3_prepare_v2(database, "SELECT value FROM vector_store_metadata WHERE key = ? LIMIT 1;", -1, &statement, nil) == SQLITE_OK else {
            return nil
        }
        sqlite3_bind_text(statement, 1, key, -1, sqliteTransient)
        guard sqlite3_step(statement) == SQLITE_ROW,
              let pointer = sqlite3_column_text(statement, 0) else { return nil }
        return String(cString: pointer)
    }

    private func setMetadataValue(_ value: String, for key: String) throws {
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }
        guard sqlite3_prepare_v2(database, "INSERT OR REPLACE INTO vector_store_metadata(key, value) VALUES(?, ?);", -1, &statement, nil) == SQLITE_OK else {
            throw VectorStoreError.prepareFailed
        }
        sqlite3_bind_text(statement, 1, key, -1, sqliteTransient)
        sqlite3_bind_text(statement, 2, value, -1, sqliteTransient)
        guard sqlite3_step(statement) == SQLITE_DONE else { throw VectorStoreError.writeFailed }
    }

    private func vectorBlob(_ vector: [Float]) -> Data {
        let values = vector
        return values.withUnsafeBufferPointer { buffer in
            Data(buffer: buffer)
        }
    }

    private func execute(_ sql: String) throws {
        var error: UnsafeMutablePointer<CChar>?
        guard sqlite3_exec(database, sql, nil, nil, &error) == SQLITE_OK else {
            let message = error.map { String(cString: $0) } ?? "unknown"
            sqlite3_free(error)
            throw VectorStoreError.sqlite(message)
        }
    }
}

enum VectorStoreError: LocalizedError {
    case openFailed
    case prepareFailed
    case writeFailed
    case encodingFailed
    case sqlite(String)

    var errorDescription: String? {
        switch self {
        case .openFailed: return "无法打开向量 SQLite 数据库"
        case .prepareFailed: return "无法准备 SQLite 查询"
        case .writeFailed: return "无法写入向量"
        case .encodingFailed: return "向量编码失败"
        case .sqlite(let message): return "SQLite 错误: \(message)"
        }
    }
}

enum VectorMath {
    static func normalized(_ vector: [Float]) -> [Float] {
        let norm = sqrt(vector.reduce(Float(0)) { $0 + $1 * $1 })
        guard norm > 0 else { return vector }
        return vector.map { $0 / norm }
    }

    static func cosine(_ lhs: [Float], _ rhs: [Float]) -> Double {
        let count = min(lhs.count, rhs.count)
        guard count > 0 else { return 0 }
        let dot = (0..<count).reduce(Float(0)) { $0 + lhs[$1] * rhs[$1] }
        return Double(dot)
    }
}

final class SearchService {
    static let missingVectorIndexMessage = "没有可用的向量索引。请先在设置中初始化/重建向量索引；AI 问答只会基于已向量化的邮件回答。"

    private let embeddingService: EmbeddingService
    private let vectorStore: VectorStore
    private let aiService: AIService

    init(embeddingService: EmbeddingService, vectorStore: VectorStore, aiService: AIService) {
        self.embeddingService = embeddingService
        self.vectorStore = vectorStore
        self.aiService = aiService
    }

    func filter(messages: [MailMessage], query: String) -> [MailMessage] {
        guard !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return messages }
        return messages.filter {
            $0.subject.localizedCaseInsensitiveContains(query)
            || $0.senderDisplayName.localizedCaseInsensitiveContains(query)
            || $0.snippet.localizedCaseInsensitiveContains(query)
            || ($0.bodyPlain?.localizedCaseInsensitiveContains(query) ?? false)
        }
    }

    func answer(
        question: String,
        messages: [MailMessage],
        attachments: [MailAttachment] = [],
        chatModel: String,
        responseLanguage: AppLanguage = .simplifiedChinese,
        topK: Int = 8,
        onPartial: (@MainActor (SearchAnswer) -> Void)? = nil
    ) async throws -> SearchAnswer {
        let queryEmbedding = try await embeddingService.embed(texts: [question]).first ?? []
        let allowed = Set(messages.map(\.id))
        let attachmentsByMessageID = Dictionary(grouping: attachments, by: \.messageId)
        let matches = try vectorStore.topK(query: queryEmbedding, k: topK, allowedMessageIDs: allowed)
        let rankedMessages = Self.rankedContextMessages(
            question: question,
            messages: messages,
            vectorMatches: matches,
            attachmentsByMessageID: attachmentsByMessageID,
            limit: topK
        )

        guard !rankedMessages.isEmpty else {
            let emptyAnswer = SearchAnswer(question: question, answer: Self.missingVectorIndexMessage(language: responseLanguage), citations: [])
            await onPartial?(emptyAnswer)
            return emptyAnswer
        }

        let context = rankedMessages.enumerated().map { index, message in
            """
            [\(index + 1)]
            Subject: \(message.subject)
            From: \(message.senderDisplayName) <\(message.fromAddress)>
            Date: \(message.date.formatted(date: .abbreviated, time: .shortened))
            Body: \(Self.contextText(for: message, attachments: attachmentsByMessageID[message.id] ?? []))
            """
        }.joined(separator: "\n\n")

        let promptMessages = [
            ChatMessage(
                role: "system",
                content: """
                You are myMail's mail retrieval assistant.
                Answer only from the provided mail context. If the context is insufficient, say so directly.
                Format the answer as readable Markdown with short paragraphs and vertical bullet lists when summarizing multiple messages or events.
                Put each cited message or event on its own line. Avoid dense inline runs of dates, statuses, and citation numbers.
                Mark relevant sentences with citation numbers such as [1] and [2].
                Do not invent facts that are not present in the messages.
                Answer in \(responseLanguage.aiInstructionName).
                """
            ),
            ChatMessage(
                role: "user",
                content: """
                问题：\(question)

                邮件上下文：
                \(context)
                """
            )
        ]

        var answer = ""
        for try await chunk in aiService.chat(model: chatModel, messages: promptMessages, stream: true) {
            answer += chunk
            await onPartial?(SearchAnswer(
                question: question,
                answer: answer.trimmingCharacters(in: .whitespacesAndNewlines),
                citations: rankedMessages
            ))
        }

        let trimmedAnswer = answer.trimmingCharacters(in: .whitespacesAndNewlines)
        return SearchAnswer(
            question: question,
            answer: trimmedAnswer.isEmpty ? Self.emptyAnswerMessage(language: responseLanguage) : trimmedAnswer,
            citations: rankedMessages
        )
    }

    static func missingVectorIndexMessage(language: AppLanguage) -> String {
        AppLocalizer.text(.missingVectorIndex, language: language)
    }

    static func emptyAnswerMessage(language: AppLanguage) -> String {
        AppLocalizer.text(.emptyAIAnswer, language: language)
    }

    static func indexText(for message: MailMessage, attachments: [MailAttachment] = []) -> String {
        [
            "Subject: \(message.subject)",
            "From: \(message.senderDisplayName) <\(message.fromAddress)>",
            "Body: \(contextText(for: message, attachments: attachments))"
        ].joined(separator: "\n")
    }

    private static func contextText(for message: MailMessage, attachments: [MailAttachment]) -> String {
        let text = message.bodyPlain?.isEmpty == false ? message.bodyPlain ?? "" : message.snippet
        let normalized = text.replacingOccurrences(of: "\n\n\n+", with: "\n\n", options: .regularExpression)
        let body = String(normalized.prefix(4_000))
        let attachmentContext = AttachmentTextExtractor.contextText(for: attachments)
        guard !attachmentContext.isEmpty else { return body }
        return [body, attachmentContext].filter { !$0.isEmpty }.joined(separator: "\n\n")
    }

    private static func rankedContextMessages(
        question: String,
        messages: [MailMessage],
        vectorMatches: [VectorMatch],
        attachmentsByMessageID: [UUID: [MailAttachment]],
        limit: Int
    ) -> [MailMessage] {
        let messagesByID = Dictionary(uniqueKeysWithValues: messages.map { ($0.id, $0) })
        let vectorScores = Dictionary(uniqueKeysWithValues: vectorMatches.map { ($0.messageId, $0.score) })
        var candidateIDs = Set(vectorMatches.map(\.messageId))
        var lexicalScores: [UUID: Double] = [:]

        for message in messages {
            let score = lexicalScore(
                question: question,
                message: message,
                attachments: attachmentsByMessageID[message.id] ?? []
            )
            guard score > 0 else { continue }
            lexicalScores[message.id] = score
            candidateIDs.insert(message.id)
        }

        return candidateIDs.compactMap { id -> (message: MailMessage, score: Double)? in
            guard let message = messagesByID[id] else { return nil }
            let score = (vectorScores[id] ?? 0) + (lexicalScores[id] ?? 0)
            return (message, score)
        }
        .sorted {
            if $0.score == $1.score {
                return $0.message.date > $1.message.date
            }
            return $0.score > $1.score
        }
        .prefix(max(limit, 1))
        .map(\.message)
    }

    private static func lexicalScore(question: String, message: MailMessage, attachments: [MailAttachment]) -> Double {
        let tokens = queryTokens(question)
        guard !tokens.isEmpty else { return 0 }

        let subject = normalizedSearchText(message.subject)
        let sender = normalizedSearchText("\(message.senderDisplayName) \(message.fromAddress)")
        let snippet = normalizedSearchText(message.snippet)
        let body = normalizedSearchText(contextText(for: message, attachments: attachments))
        var score = 0.0

        for token in tokens {
            if subject.contains(token) { score += Double(token.count) * 4.0 }
            if snippet.contains(token) { score += Double(token.count) * 2.0 }
            if body.contains(token) { score += Double(token.count) * 1.5 }
            if sender.contains(token) { score += Double(token.count) }
        }

        let compactQuestion = normalizedSearchText(question)
        if !compactQuestion.isEmpty && subject.contains(compactQuestion) {
            score += Double(compactQuestion.count) * 6.0
        }
        return score
    }

    private static func queryTokens(_ question: String) -> [String] {
        let normalized = normalizedSearchText(question)
        guard !normalized.isEmpty else { return [] }

        let stopWords: Set<String> = [
            "邮件", "哪些", "哪个", "什么", "怎么", "如何", "是否", "是不是", "有没有",
            "请问", "相关", "内容", "一下", "这个", "那个", "的是", "的是哪些"
        ]
        var tokens: Set<String> = []
        let pieces = normalized.components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }

        for piece in pieces {
            if piece.count >= 2, !stopWords.contains(piece) {
                tokens.insert(piece)
            }
            if containsCJK(piece), piece.count >= 2 {
                let characters = Array(piece)
                if characters.count <= 12, !stopWords.contains(piece) {
                    tokens.insert(piece)
                }
                if characters.count >= 2 {
                    for index in 0..<(characters.count - 1) {
                        let token = String(characters[index...index + 1])
                        if !stopWords.contains(token) {
                            tokens.insert(token)
                        }
                    }
                }
            }
        }

        return tokens.sorted { $0.count > $1.count }
    }

    private static func normalizedSearchText(_ text: String) -> String {
        text
            .folding(options: [.caseInsensitive, .widthInsensitive, .diacriticInsensitive], locale: .current)
            .replacingOccurrences(of: "\\s+", with: "", options: .regularExpression)
            .lowercased()
    }

    private static func containsCJK(_ text: String) -> Bool {
        text.unicodeScalars.contains { scalar in
            (0x4E00...0x9FFF).contains(Int(scalar.value))
        }
    }
}

enum AttachmentTextExtractor {
    private static let maxReadBytes = 1_500_000
    private static let maxTextCharacters = 4_000
    private static let textExtensions: Set<String> = [
        "txt", "text", "md", "markdown", "csv", "tsv", "json", "xml", "html", "htm",
        "log", "rtf", "ics", "eml", "vcf", "yaml", "yml"
    ]

    static func contextText(for attachments: [MailAttachment]) -> String {
        let chunks = attachments.compactMap { attachment -> String? in
            let header = "Attachment: \(attachment.filename) (\(attachment.mimeType))"
            if let text = extractedText(for: attachment), !text.isEmpty {
                return "\(header)\n\(text)"
            }
            return header
        }
        return chunks.isEmpty ? "" : "Attachments:\n" + chunks.joined(separator: "\n\n")
    }

    static func extractedText(for attachment: MailAttachment) -> String? {
        if attachment.mimeType.localizedCaseInsensitiveContains("pdf") || attachment.filename.lowercased().hasSuffix(".pdf") {
            return pdfText(for: attachment).map(limitText)
        }
        guard isTextual(attachment) else { return nil }
        guard let data = attachmentData(attachment) else { return nil }
        return decodedString(from: data).map { limitText(stripMarkupIfNeeded($0, attachment: attachment)) }
    }

    private static func attachmentData(_ attachment: MailAttachment) -> Data? {
        if let decodedContent = attachment.decodedContent {
            return decodedContent
        }
        guard let localPath = attachment.localPath else { return nil }
        let url = URL(fileURLWithPath: localPath)
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
              let size = attributes[.size] as? NSNumber,
              size.intValue <= maxReadBytes else {
            return nil
        }
        return try? Data(contentsOf: url)
    }

    private static func pdfText(for attachment: MailAttachment) -> String? {
        let document: PDFDocument?
        if let localPath = attachment.localPath {
            document = PDFDocument(url: URL(fileURLWithPath: localPath))
        } else if let decodedContent = attachment.decodedContent {
            document = PDFDocument(data: decodedContent)
        } else {
            document = nil
        }
        guard let document else { return nil }
        return (0..<document.pageCount)
            .compactMap { document.page(at: $0)?.string }
            .joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .nilIfEmpty
    }

    private static func isTextual(_ attachment: MailAttachment) -> Bool {
        let mimeType = attachment.mimeType.lowercased()
        let fileExtension = URL(fileURLWithPath: attachment.filename).pathExtension.lowercased()
        return mimeType.hasPrefix("text/")
            || mimeType.contains("json")
            || mimeType.contains("xml")
            || mimeType.contains("html")
            || textExtensions.contains(fileExtension)
    }

    private static func decodedString(from data: Data) -> String? {
        let gb18030 = String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(CFStringEncoding(CFStringEncodings.GB_18030_2000.rawValue)))
        let encodings: [String.Encoding] = [.utf8, gb18030, .utf16, .isoLatin1]
        return encodings.lazy.compactMap { String(data: data, encoding: $0) }.first?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .nilIfEmpty
    }

    private static func stripMarkupIfNeeded(_ text: String, attachment: MailAttachment) -> String {
        let lowerName = attachment.filename.lowercased()
        let lowerMIME = attachment.mimeType.lowercased()
        guard lowerMIME.contains("html") || lowerName.hasSuffix(".html") || lowerName.hasSuffix(".htm") else {
            return text
        }
        return text
            .replacingOccurrences(of: "<[^>]+>", with: " ", options: .regularExpression)
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
    }

    private static func limitText(_ text: String) -> String {
        String(text.prefix(maxTextCharacters))
    }
}
