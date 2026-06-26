//
//  MailTransport.swift
//  myMail
//

import Foundation

enum MailServiceError: LocalizedError {
    case missingPassword
    case missingConnectedAccount
    case unsupportedTLSMode(String)
    case connectionFailed(String)
    case serverRejected(String)
    case malformedServerResponse(String)
    case attachmentReadFailed(URL)

    var errorDescription: String? {
        switch self {
        case .missingPassword:
            return "请先保存客户端专用密码。"
        case .missingConnectedAccount:
            return "请先连接账户。"
        case .unsupportedTLSMode(let mode):
            return "暂不支持 \(mode) 连接；请使用 SSL/TLS、STARTTLS 或无加密。"
        case .connectionFailed(let reason):
            return "邮件服务器连接失败：\(reason)"
        case .serverRejected(let message):
            return "邮件服务器拒绝请求：\(message)"
        case .malformedServerResponse(let response):
            return "邮件服务器返回格式无法解析：\(response)"
        case .attachmentReadFailed(let url):
            return "附件读取失败：\(url.lastPathComponent)"
        }
    }
}

protocol MailLineConnection {
    func open() throws
    func close()
    func upgradeToTLS() throws
    func sendLine(_ line: String) throws
    func write(_ data: Data) throws
    func readLine(timeout: TimeInterval) throws -> String
}

struct MailConnectionCredentials: Sendable {
    var username: String
    var secret: String
    var authType: MailAuthType = .appPassword

    init(username: String, password: String) {
        self.username = username
        self.secret = password
        self.authType = .appPassword
    }

    init(username: String, secret: String, authType: MailAuthType) {
        self.username = username
        self.secret = secret
        self.authType = authType
    }

    var password: String { secret }

    var usesOAuth2: Bool { authType == .oauth2 }

    func xoauth2Token() -> String {
        Data("user=\(username)\u{1}auth=Bearer \(secret)\u{1}\u{1}".utf8).base64EncodedString()
    }
}

struct SMTPMIMEBuilder {
    func makeMessage(from account: MailAccount, draft: OutgoingMessage) throws -> Data {
        let boundary = "mymail-\(UUID().uuidString)"
        var lines: [String] = [
            "From: \(account.emailAddress)",
            "To: \(draft.to.joined(separator: ", "))",
            draft.cc.isEmpty ? "" : "Cc: \(draft.cc.joined(separator: ", "))",
            "Subject: \(encodedHeader(draft.subject))",
            "MIME-Version: 1.0",
            "Content-Type: multipart/mixed; boundary=\"\(boundary)\"",
            "",
            "--\(boundary)",
            "Content-Type: text/plain; charset=utf-8",
            "Content-Transfer-Encoding: base64",
            "",
            Data(draft.bodyPlain.utf8).base64EncodedString(options: [.lineLength76Characters, .endLineWithCarriageReturn, .endLineWithLineFeed])
        ].filter { !$0.isEmpty }

        for url in draft.attachmentURLs {
            let didStartAccess = url.startAccessingSecurityScopedResource()
            defer {
                if didStartAccess {
                    url.stopAccessingSecurityScopedResource()
                }
            }
            guard let data = try? Data(contentsOf: url) else {
                throw MailServiceError.attachmentReadFailed(url)
            }
            let filename = url.lastPathComponent
            lines.append(contentsOf: [
                "--\(boundary)",
                "Content-Type: \(mimeType(for: filename)); name=\"\(escapedParameter(filename))\"",
                "Content-Disposition: attachment; filename=\"\(escapedParameter(filename))\"",
                "Content-Transfer-Encoding: base64",
                "",
                data.base64EncodedString(options: [.lineLength76Characters, .endLineWithCarriageReturn, .endLineWithLineFeed])
            ])
        }

        lines.append("--\(boundary)--")
        lines.append("")
        return Data(lines.joined(separator: "\r\n").utf8)
    }

    private func encodedHeader(_ value: String) -> String {
        guard value.canBeConverted(to: .ascii) else {
            return "=?UTF-8?B?\(Data(value.utf8).base64EncodedString())?="
        }
        return value
    }

    private func escapedParameter(_ value: String) -> String {
        value.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
    }

    private func mimeType(for filename: String) -> String {
        let ext = (filename as NSString).pathExtension.lowercased()
        switch ext {
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
}

struct MIMEParser {
    private struct Part {
        var headers: [String: String]
        var body: String
    }

    static func parseMessageBody(_ raw: String) -> MessageBody {
        let root = splitHeaderBody(raw)
        var plain: String?
        var html: String?
        var attachments: [MailAttachment] = []

        collect(part: Part(headers: root.headers, body: root.body), plain: &plain, html: &html, attachments: &attachments)

        if plain == nil, html == nil, attachments.isEmpty {
            let fallback = root.body.isEmpty ? raw : root.body
            if fallback.localizedCaseInsensitiveContains("<html") || fallback.localizedCaseInsensitiveContains("<body") {
                html = fallback
                plain = stripHTML(fallback)
            } else {
                plain = fallback
            }
        }

        return MessageBody(plain: plain ?? "", html: html, attachments: attachments)
    }

    private static func collect(part: Part, plain: inout String?, html: inout String?, attachments: inout [MailAttachment]) {
        let contentType = part.headers["content-type"] ?? "text/plain"
        if contentType.lowercased().hasPrefix("multipart/"), let boundary = parameter("boundary", in: contentType) {
            for child in multipartParts(from: part.body, boundary: boundary) {
                collect(part: child, plain: &plain, html: &html, attachments: &attachments)
            }
            return
        }

        let disposition = part.headers["content-disposition"] ?? ""
        let filename = parameter("filename", in: disposition) ?? parameter("name", in: contentType)
        let decodedData = decodedBodyData(part.body, transferEncoding: part.headers["content-transfer-encoding"])

        let attachmentName = filename?.nilIfEmpty
        if attachmentName != nil || disposition.lowercased().contains("attachment") {
            attachments.append(MailAttachment(
                id: UUID(),
                messageId: UUID(),
                filename: attachmentName ?? "attachment",
                mimeType: mediaType(from: contentType),
                sizeBytes: Int64(decodedData.count),
                localPath: nil,
                contentId: cleaned(part.headers["content-id"]),
                decodedContent: decodedData
            ))
            return
        }

        let text = decodedText(decodedData, contentType: contentType, fallback: part.body)
        if mediaType(from: contentType).lowercased().hasPrefix("text/html") {
            html = html ?? text
            plain = plain ?? stripHTML(text)
        } else if mediaType(from: contentType).lowercased().hasPrefix("text/plain") {
            plain = plain ?? text
        }
    }

    private static func splitHeaderBody(_ raw: String) -> (headers: [String: String], body: String) {
        let normalized = raw.replacingOccurrences(of: "\r\n", with: "\n")
        guard let range = normalized.range(of: "\n\n") else {
            return ([:], normalized)
        }
        let headerBlock = String(normalized[..<range.lowerBound])
        let body = String(normalized[range.upperBound...])
        return (parseHeaders(headerBlock), body)
    }

    private static func parseHeaders(_ raw: String) -> [String: String] {
        var headers: [String: String] = [:]
        var currentKey: String?
        for line in raw.split(separator: "\n", omittingEmptySubsequences: false).map(String.init) {
            if line.hasPrefix(" ") || line.hasPrefix("\t"), let currentKey {
                headers[currentKey, default: ""] += " " + line.trimmingCharacters(in: .whitespacesAndNewlines)
                continue
            }
            guard let colon = line.firstIndex(of: ":") else { continue }
            let key = String(line[..<colon]).lowercased()
            headers[key] = String(line[line.index(after: colon)...]).trimmingCharacters(in: .whitespacesAndNewlines)
            currentKey = key
        }
        return headers
    }

    private static func multipartParts(from body: String, boundary: String) -> [Part] {
        let delimiter = "--\(boundary)"
        let closingDelimiter = "--\(boundary)--"
        let lines = body.replacingOccurrences(of: "\r\n", with: "\n").split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        var chunks: [String] = []
        var current: [String]?

        for line in lines {
            let boundaryLine = line.trimmingCharacters(in: .whitespacesAndNewlines)
            if boundaryLine == delimiter || boundaryLine == closingDelimiter {
                if let current {
                    chunks.append(current.joined(separator: "\n"))
                }
                if boundaryLine == closingDelimiter { break }
                current = []
            } else if current != nil {
                current?.append(line)
            }
        }

        return chunks.map { chunk in
            let parsed = splitHeaderBody(chunk)
            return Part(headers: parsed.headers, body: parsed.body)
        }
    }

    private static func decodedBodyData(_ body: String, transferEncoding: String?) -> Data {
        let trimmed = body.trimmingCharacters(in: .whitespacesAndNewlines)
        let encoding = transferEncoding?
            .split(separator: ";", maxSplits: 1)
            .first?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        switch encoding {
        case "base64":
            let compact = trimmed.components(separatedBy: .whitespacesAndNewlines).joined()
            return Data(base64Encoded: compact, options: .ignoreUnknownCharacters) ?? Data()
        case "quoted-printable":
            return decodeQuotedPrintable(trimmed)
        default:
            return rawBodyData(body)
        }
    }

    private static func rawBodyData(_ body: String) -> Data {
        body.data(using: .isoLatin1) ?? Data(body.utf8)
    }

    private static func decodeQuotedPrintable(_ value: String) -> Data {
        let softened = value
            .replacingOccurrences(of: "=\r\n", with: "")
            .replacingOccurrences(of: "=\n", with: "")
        let bytes = Array(softened.utf8)
        var output = Data()
        var index = 0
        while index < bytes.count {
            if bytes[index] == 61, index + 2 < bytes.count,
               let high = hexValue(bytes[index + 1]), let low = hexValue(bytes[index + 2]) {
                output.append(UInt8(high * 16 + low))
                index += 3
            } else {
                output.append(bytes[index])
                index += 1
            }
        }
        return output
    }

    private static func hexValue(_ byte: UInt8) -> UInt8? {
        switch byte {
        case 48...57: return byte - 48
        case 65...70: return byte - 55
        case 97...102: return byte - 87
        default: return nil
        }
    }

    private static func decodedText(_ data: Data, contentType: String, fallback: String) -> String {
        let declared = parameter("charset", in: contentType).flatMap(textEncoding)
        let candidates = [
            declared,
            .some(String.Encoding.utf8),
            textEncoding("gb18030"),
            textEncoding("gbk"),
            textEncoding("big5"),
            .some(String.Encoding.isoLatin1)
        ]
        for encoding in candidates.compactMap({ $0 }) {
            if let text = String(data: data, encoding: encoding) {
                return text
            }
        }
        return fallback
    }

    private static func textEncoding(_ charset: String) -> String.Encoding? {
        let normalized = charset
            .trimmingCharacters(in: CharacterSet(charactersIn: " \"'"))
            .lowercased()
            .replacingOccurrences(of: "_", with: "-")
        switch normalized {
        case "utf-8", "utf8":
            return .utf8
        case "us-ascii", "ascii":
            return .ascii
        case "iso-8859-1", "latin1", "latin-1":
            return .isoLatin1
        case "gb2312", "gbk", "gb18030", "cp936", "windows-936":
            return String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(CFStringEncoding(CFStringEncodings.GB_18030_2000.rawValue)))
        case "big5", "big-5":
            return String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(CFStringEncoding(CFStringEncodings.big5.rawValue)))
        default:
            let converted = CFStringConvertIANACharSetNameToEncoding(normalized as CFString)
            guard converted != kCFStringEncodingInvalidId else { return nil }
            return String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(converted))
        }
    }


    static func parseMailDate(_ raw: String) -> Date? {
        let normalized = raw
            .replacingOccurrences(of: "\r\n", with: " ")
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .replacingOccurrences(of: #"\s*\([^)]*\)\s*$"#, with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else { return nil }

        let formats = [
            "EEE, d MMM yyyy HH:mm:ss Z",
            "EEE, dd MMM yyyy HH:mm:ss Z",
            "d MMM yyyy HH:mm:ss Z",
            "dd MMM yyyy HH:mm:ss Z",
            "EEE, d MMM yyyy HH:mm Z",
            "EEE, dd MMM yyyy HH:mm Z",
            "d MMM yyyy HH:mm Z",
            "dd MMM yyyy HH:mm Z",
            "EEE, d MMM yyyy HH:mm:ss zzz",
            "EEE, dd MMM yyyy HH:mm:ss zzz",
            "d MMM yyyy HH:mm:ss zzz",
            "dd MMM yyyy HH:mm:ss zzz"
        ]
        for format in formats {
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.timeZone = TimeZone(secondsFromGMT: 0)
            formatter.isLenient = true
            formatter.dateFormat = format
            if let date = formatter.date(from: normalized) {
                return date
            }
        }
        return nil
    }

    private static func decodedString(data: Data, charset: String) -> String? {
        if let encoding = textEncoding(charset), let decoded = String(data: data, encoding: encoding) {
            return decoded
        }
        if let decoded = String(data: data, encoding: .utf8) {
            return decoded
        }
        if let decoded = String(data: data, encoding: .isoLatin1) {
            return decoded
        }
        return nil
    }

    private static func parameter(_ name: String, in value: String) -> String? {
        let pattern = #"(?i)(?:^|;)\s*"# + NSRegularExpression.escapedPattern(for: name) + #"(\*)?=(?:"([^"]*)"|([^;\s]+))"#
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: value, range: NSRange(value.startIndex..., in: value)) else { return nil }
        let isExtended = Range(match.range(at: 1), in: value) != nil
        for index in 2..<match.numberOfRanges {
            guard let range = Range(match.range(at: index), in: value) else { continue }
            let raw = String(value[range]).replacingOccurrences(of: "\\\"", with: "\"")
            return isExtended ? decodeExtendedParameter(raw) : decodeHeaderValue(raw)
        }
        return nil
    }

    private static func decodeExtendedParameter(_ value: String) -> String {
        let pieces = value.split(separator: "'", maxSplits: 2, omittingEmptySubsequences: false).map(String.init)
        guard pieces.count == 3 else { return decodeHeaderValue(value) }
        let charset = pieces[0]
        let encoded = pieces[2]
        var data = Data()
        var index = encoded.startIndex
        while index < encoded.endIndex {
            if encoded[index] == "%",
               encoded.distance(from: index, to: encoded.endIndex) >= 3 {
                let first = encoded.index(after: index)
                let second = encoded.index(after: first)
                let hex = String(encoded[first...second])
                if let byte = UInt8(hex, radix: 16) {
                    data.append(byte)
                    index = encoded.index(after: second)
                    continue
                }
            }
            data.append(contentsOf: String(encoded[index]).utf8)
            index = encoded.index(after: index)
        }
        return textEncoding(charset).flatMap { String(data: data, encoding: $0) } ?? decodeHeaderValue(value)
    }

    static func decodeHeaderValue(_ value: String) -> String {
        let normalizedValue = value
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\n", with: " ")
        let pattern = #"=\?\s*([^?]+?)\s*\?\s*([bBqQ])\s*\?\s*([^?]*?)\s*\?="#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return repairMojibakeIfNeeded(value) }
        let matches = regex.matches(in: normalizedValue, range: NSRange(normalizedValue.startIndex..., in: normalizedValue))
        guard !matches.isEmpty else {
            return repairMojibakeIfNeeded(decodeMalformedEncodedWord(normalizedValue) ?? normalizedValue)
        }

        var result = ""
        var cursor = normalizedValue.startIndex
        var previousWasEncodedWord = false
        for match in matches {
            guard let fullRange = Range(match.range(at: 0), in: normalizedValue),
                  let charsetRange = Range(match.range(at: 1), in: normalizedValue),
                  let modeRange = Range(match.range(at: 2), in: normalizedValue),
                  let payloadRange = Range(match.range(at: 3), in: normalizedValue) else { continue }
            let separator = String(normalizedValue[cursor..<fullRange.lowerBound])
            if !(previousWasEncodedWord && separator.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty) {
                result += separator
            }
            let charset = String(normalizedValue[charsetRange])
            let mode = String(normalizedValue[modeRange]).lowercased()
            let payload = String(normalizedValue[payloadRange])
            let data = decodedEncodedWordData(payload: payload, mode: mode)
            if let data, let decoded = decodedString(data: data, charset: charset) {
                result += decoded
            } else {
                result += String(normalizedValue[fullRange])
            }
            previousWasEncodedWord = true
            cursor = fullRange.upperBound
        }
        result += normalizedValue[cursor...]

        if result.contains("=?"), let rescued = decodeMalformedEncodedWord(result) {
            return repairMojibakeIfNeeded(rescued.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        return repairMojibakeIfNeeded(result.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    private static func decodeMalformedEncodedWord(_ value: String) -> String? {
        let pattern = #"=\?\s*([^?]+?)\s*\?\s*([bBqQ])\s*\?\s*(.+)$"#
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: value, range: NSRange(value.startIndex..., in: value)),
              let fullRange = Range(match.range(at: 0), in: value),
              let charsetRange = Range(match.range(at: 1), in: value),
              let modeRange = Range(match.range(at: 2), in: value),
              let payloadRange = Range(match.range(at: 3), in: value) else { return nil }

        let charset = String(value[charsetRange])
        let mode = String(value[modeRange]).lowercased()
        let payload = String(value[payloadRange])
            .replacingOccurrences(of: "?=", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard let data = decodedEncodedWordData(payload: payload, mode: mode),
              let decoded = decodedString(data: data, charset: charset),
              !decoded.isEmpty else { return nil }

        return String(value[..<fullRange.lowerBound]) + decoded
    }

    private static func repairMojibakeIfNeeded(_ value: String) -> String {
        guard looksLikeMojibake(value), let data = legacyBytes(from: value), let repaired = String(data: data, encoding: .utf8) else {
            return value
        }

        let originalScore = mojibakeScore(value)
        let repairedScore = mojibakeScore(repaired)
        let originalReadable = readableUnicodeScore(value)
        let repairedReadable = readableUnicodeScore(repaired)
        if repairedScore < originalScore || repairedReadable > originalReadable + 1 {
            return repaired
        }
        return value
    }

    private static func looksLikeMojibake(_ value: String) -> Bool {
        mojibakeScore(value) >= 2
    }

    private static func mojibakeScore(_ value: String) -> Int {
        let markers = [
            "Ã", "Â", "â€", "â€™", "â€œ", "â€�", "â€“", "â€”",
            "ï¼", "ï½", "ã€", "ã€�", "ã‚", "ãƒ",
            "æ", "ç", "è", "å", "ä", "ðŸ"
        ]
        return markers.reduce(0) { score, marker in
            score + value.components(separatedBy: marker).count - 1
        }
    }

    private static func readableUnicodeScore(_ value: String) -> Int {
        value.unicodeScalars.reduce(0) { score, scalar in
            switch scalar.value {
            case 0x4E00...0x9FFF, 0x3040...0x30FF, 0xAC00...0xD7AF:
                return score + 2
            case 0x2010...0x2027, 0x3000...0x303F, 0xFF00...0xFFEF:
                return score + 1
            default:
                return score
            }
        }
    }

    private static func legacyBytes(from value: String) -> Data? {
        var bytes: [UInt8] = []
        bytes.reserveCapacity(value.unicodeScalars.count)
        for scalar in value.unicodeScalars {
            if scalar.value <= 0xFF {
                bytes.append(UInt8(scalar.value))
                continue
            }
            guard let byte = windows1252Byte(for: scalar.value) else { return nil }
            bytes.append(byte)
        }
        return Data(bytes)
    }

    private static func windows1252Byte(for scalar: UInt32) -> UInt8? {
        switch scalar {
        case 0x20AC: return 0x80
        case 0x201A: return 0x82
        case 0x0192: return 0x83
        case 0x201E: return 0x84
        case 0x2026: return 0x85
        case 0x2020: return 0x86
        case 0x2021: return 0x87
        case 0x02C6: return 0x88
        case 0x2030: return 0x89
        case 0x0160: return 0x8A
        case 0x2039: return 0x8B
        case 0x0152: return 0x8C
        case 0x017D: return 0x8E
        case 0x2018: return 0x91
        case 0x2019: return 0x92
        case 0x201C: return 0x93
        case 0x201D: return 0x94
        case 0x2022: return 0x95
        case 0x2013: return 0x96
        case 0x2014: return 0x97
        case 0x02DC: return 0x98
        case 0x2122: return 0x99
        case 0x0161: return 0x9A
        case 0x203A: return 0x9B
        case 0x0153: return 0x9C
        case 0x017E: return 0x9E
        case 0x0178: return 0x9F
        default: return nil
        }
    }

    private static func decodedEncodedWordData(payload: String, mode: String) -> Data? {
        if mode == "b" {
            var cleaned = payload.filter { !$0.isWhitespace }
            let padding = cleaned.count % 4
            if padding != 0 {
                cleaned += String(repeating: "=", count: 4 - padding)
            }
            return Data(base64Encoded: cleaned, options: .ignoreUnknownCharacters)
        }

        let cleaned = payload.filter { !$0.isWhitespace }
        return decodeEncodedWordQuotedPrintable(String(cleaned))
    }

    private static func decodeEncodedWordQuotedPrintable(_ value: String) -> Data {
        decodeQuotedPrintable(value.replacingOccurrences(of: "_", with: " "))
    }

    private static func mediaType(from contentType: String) -> String {
        contentType.split(separator: ";", maxSplits: 1).first.map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) } ?? "application/octet-stream"
    }

    private static func cleaned(_ value: String?) -> String? {
        value?.trimmingCharacters(in: CharacterSet(charactersIn: " <>\t\r\n")).nilIfEmpty
    }

    private static func stripHTML(_ html: String) -> String {
        html.replacingOccurrences(of: "<[^>]+>", with: " ", options: .regularExpression)
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

final class LineSocket: MailLineConnection {
    private let host: String
    private let port: Int
    private let tlsMode: String
    private var input: InputStream?
    private var output: OutputStream?
    private var pendingBytes = Data()

    init(endpoint: ServerEndpoint) {
        self.host = endpoint.host
        self.port = endpoint.port
        self.tlsMode = endpoint.normalizedTLSMode
    }

    func open() throws {
        guard ServerEndpoint.supportedTLSModes.contains(tlsMode) else {
            throw MailServiceError.unsupportedTLSMode(tlsMode)
        }

        var readStream: InputStream?
        var writeStream: OutputStream?
        Stream.getStreamsToHost(withName: host, port: port, inputStream: &readStream, outputStream: &writeStream)
        guard let readStream, let writeStream else {
            throw MailServiceError.connectionFailed("\(host):\(port)")
        }

        if tlsMode == "SSL" {
            readStream.setProperty(StreamSocketSecurityLevel.negotiatedSSL, forKey: .socketSecurityLevelKey)
            writeStream.setProperty(StreamSocketSecurityLevel.negotiatedSSL, forKey: .socketSecurityLevelKey)
        }
        readStream.open()
        writeStream.open()
        input = readStream
        output = writeStream

        let deadline = Date().addingTimeInterval(10)
        while Date() < deadline {
            if readStream.streamStatus == .error || writeStream.streamStatus == .error {
                let fallback = tlsMode == "SSL" ? "TLS 握手失败" : "连接失败"
                throw MailServiceError.connectionFailed(readStream.streamError?.localizedDescription ?? writeStream.streamError?.localizedDescription ?? fallback)
            }
            if readStream.streamStatus == .open && writeStream.streamStatus == .open {
                return
            }
            usleep(20_000)
        }
        throw MailServiceError.connectionFailed("连接超时")
    }

    func upgradeToTLS() throws {
        guard let input, let output else {
            throw MailServiceError.connectionFailed("连接尚未打开")
        }
        input.setProperty(StreamSocketSecurityLevel.negotiatedSSL, forKey: .socketSecurityLevelKey)
        output.setProperty(StreamSocketSecurityLevel.negotiatedSSL, forKey: .socketSecurityLevelKey)
        pendingBytes.removeAll()

        let deadline = Date().addingTimeInterval(10)
        while Date() < deadline {
            if input.streamStatus == .error || output.streamStatus == .error {
                throw MailServiceError.connectionFailed(input.streamError?.localizedDescription ?? output.streamError?.localizedDescription ?? "STARTTLS 握手失败")
            }
            if input.streamStatus == .open && output.streamStatus == .open {
                return
            }
            usleep(20_000)
        }
        throw MailServiceError.connectionFailed("STARTTLS 握手超时")
    }

    func close() {
        input?.close()
        output?.close()
        input = nil
        output = nil
        pendingBytes.removeAll()
    }

    func sendLine(_ line: String) throws {
        try write(Data((line + "\r\n").utf8))
    }

    func write(_ data: Data) throws {
        guard let output else { throw MailServiceError.connectionFailed("输出流未打开") }
        try data.withUnsafeBytes { rawBuffer in
            guard let base = rawBuffer.bindMemory(to: UInt8.self).baseAddress else { return }
            var offset = 0
            while offset < data.count {
                let written = output.write(base.advanced(by: offset), maxLength: data.count - offset)
                if written < 0 {
                    throw MailServiceError.connectionFailed(output.streamError?.localizedDescription ?? "写入失败")
                }
                if written == 0 {
                    usleep(10_000)
                } else {
                    offset += written
                }
            }
        }
    }

    func readLine(timeout: TimeInterval = 15) throws -> String {
        guard let input else { throw MailServiceError.connectionFailed("输入流未打开") }
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let range = pendingBytes.firstRange(of: Data([0x0A])) {
                let lineData = pendingBytes.subdata(in: pendingBytes.startIndex..<range.lowerBound)
                pendingBytes.removeSubrange(pendingBytes.startIndex...range.lowerBound)
                return (String(data: lineData, encoding: .utf8)
                    ?? String(data: lineData, encoding: .isoLatin1)
                    ?? "")
                    .trimmingCharacters(in: CharacterSet(charactersIn: "\r"))
            }

            if input.hasBytesAvailable {
                var buffer = [UInt8](repeating: 0, count: 4096)
                let count = input.read(&buffer, maxLength: buffer.count)
                if count < 0 {
                    throw MailServiceError.connectionFailed(input.streamError?.localizedDescription ?? "读取失败")
                }
                if count > 0 {
                    pendingBytes.append(buffer, count: count)
                }
            } else {
                if input.streamStatus == .error {
                    throw MailServiceError.connectionFailed(input.streamError?.localizedDescription ?? "读取失败")
                }
                usleep(10_000)
            }
        }
        throw MailServiceError.connectionFailed("读取超时")
    }
}

final class SMTPClient {
    private let endpoint: ServerEndpoint
    private let credentials: MailConnectionCredentials
    private let connectionFactory: () -> MailLineConnection

    init(endpoint: ServerEndpoint, credentials: MailConnectionCredentials, connectionFactory: (() -> MailLineConnection)? = nil) {
        self.endpoint = endpoint
        self.credentials = credentials
        self.connectionFactory = connectionFactory ?? { LineSocket(endpoint: endpoint) }
    }

    func verify(from address: String) throws {
        let socket = connectionFactory()
        defer { socket.close() }
        try prepareAuthenticatedSession(socket)
        try authenticate(socket)
        try command("MAIL FROM:<\(address)>", socket: socket, allowed: [250])
        try command("RSET", socket: socket, allowed: [250])
        try? command("QUIT", socket: socket, allowed: [221])
    }

    func send(message: Data, from address: String, recipients: [String]) throws {
        let socket = connectionFactory()
        defer { socket.close() }
        try prepareAuthenticatedSession(socket)
        try authenticate(socket)
        try command("MAIL FROM:<\(address)>", socket: socket, allowed: [250])
        for recipient in recipients {
            try command("RCPT TO:<\(recipient)>", socket: socket, allowed: [250, 251])
        }
        try command("DATA", socket: socket, allowed: [354])
        try socket.write(dotStuff(message))
        try socket.write(Data("\r\n.\r\n".utf8))
        try expectSMTP(socket.readLine(timeout: 60), allowed: [250])
        try? command("QUIT", socket: socket, allowed: [221])
    }

    private func prepareAuthenticatedSession(_ socket: MailLineConnection) throws {
        let mode = endpoint.normalizedTLSMode
        guard ServerEndpoint.supportedTLSModes.contains(mode) else {
            throw MailServiceError.unsupportedTLSMode(endpoint.tlsMode)
        }
        try socket.open()
        try expectSMTP(socket.readLine(timeout: 15), allowed: [220])
        try command("EHLO myMail.local", socket: socket, allowed: [250])
        if mode == "STARTTLS" {
            try command("STARTTLS", socket: socket, allowed: [220])
            try socket.upgradeToTLS()
            try command("EHLO myMail.local", socket: socket, allowed: [250])
        }
    }

    private func authenticate(_ socket: MailLineConnection) throws {
        if credentials.usesOAuth2 {
            try command("AUTH XOAUTH2 \(credentials.xoauth2Token())", socket: socket, allowed: [235])
        } else {
            try command("AUTH PLAIN \(authPlainToken())", socket: socket, allowed: [235])
        }
    }

    private func command(_ line: String, socket: MailLineConnection, allowed: Set<Int>) throws {
        try socket.sendLine(line)
        var last = try socket.readLine(timeout: 15)
        while isMultilineSMTPReply(last) {
            last = try socket.readLine(timeout: 15)
        }
        try expectSMTP(last, allowed: allowed)
    }

    private func expectSMTP(_ line: String, allowed: Set<Int>) throws {
        guard let code = Int(line.prefix(3)), allowed.contains(code) else {
            throw MailServiceError.serverRejected(line)
        }
    }

    private func isMultilineSMTPReply(_ line: String) -> Bool {
        line.count >= 4 && line[line.index(line.startIndex, offsetBy: 3)] == "-"
    }

    private func authPlainToken() -> String {
        Data("\u{0}\(credentials.username)\u{0}\(credentials.password)".utf8).base64EncodedString()
    }

    private func dotStuff(_ data: Data) -> Data {
        let normalized = String(data: data, encoding: .utf8) ?? ""
        let stuffed = normalized
            .replacingOccurrences(of: "\r\n.", with: "\r\n..")
            .replacingOccurrences(of: "\n.", with: "\n..")
        return Data(stuffed.utf8)
    }
}

final class POP3Client {
    private let endpoint: ServerEndpoint
    private let credentials: MailConnectionCredentials
    private let connectionFactory: () -> MailLineConnection

    init(endpoint: ServerEndpoint, credentials: MailConnectionCredentials, connectionFactory: (() -> MailLineConnection)? = nil) {
        self.endpoint = endpoint
        self.credentials = credentials
        self.connectionFactory = connectionFactory ?? { LineSocket(endpoint: endpoint) }
    }

    func verify() throws {
        let socket = connectionFactory()
        defer { socket.close() }
        try prepareAuthenticatedSession(socket)
        _ = try? command("QUIT", socket: socket)
    }

    func fetchMailboxes(accountId: UUID) throws -> [Mailbox] {
        try verify()
        return [Mailbox(id: UUID(), accountId: accountId, name: "INBOX", role: .inbox, uidValidity: 1, unreadCount: 0)]
    }

    func fetchHeaders(limit: Int) throws -> [MessageHeader] {
        let socket = connectionFactory()
        defer { socket.close() }
        try prepareAuthenticatedSession(socket)
        let uidls = try uidMap(socket: socket)
        let sizes = try sizeMap(socket: socket)
        let numbers = Array(uidls.keys.sorted().suffix(max(limit, 1))).reversed()
        let headers = try numbers.map { number in
            let raw: String
            if let top = try? command("TOP \(number) 0", socket: socket, multiline: true) {
                raw = top
            } else {
                raw = try command("RETR \(number)", socket: socket, multiline: true)
            }
            return parseHeader(raw, number: number, uidl: uidls[number], size: sizes[number])
        }
        _ = try? command("QUIT", socket: socket)
        return headers
    }

    func fetchBody(messageNumber: Int) throws -> MessageBody {
        let socket = connectionFactory()
        defer { socket.close() }
        try prepareAuthenticatedSession(socket)
        let raw = try command("RETR \(messageNumber)", socket: socket, multiline: true)
        _ = try? command("QUIT", socket: socket)
        return MIMEParser.parseMessageBody(raw)
    }

    private func prepareAuthenticatedSession(_ socket: MailLineConnection) throws {
        let mode = endpoint.normalizedTLSMode
        guard ServerEndpoint.supportedTLSModes.contains(mode) else {
            throw MailServiceError.unsupportedTLSMode(endpoint.tlsMode)
        }
        try socket.open()
        try expectOK(socket.readLine(timeout: 15))
        if mode == "STARTTLS" {
            try command("STLS", socket: socket)
            try socket.upgradeToTLS()
        }
        if credentials.usesOAuth2 {
            try command("AUTH XOAUTH2 \(credentials.xoauth2Token())", socket: socket)
        } else {
            try command("USER \(credentials.username)", socket: socket)
            try command("PASS \(credentials.password)", socket: socket)
        }
    }

    @discardableResult
    private func command(_ line: String, socket: MailLineConnection, multiline: Bool = false) throws -> String {
        try socket.sendLine(line)
        let first = try socket.readLine(timeout: 15)
        try expectOK(first)
        guard multiline else { return first }
        return try readMultiline(socket: socket)
    }

    private func expectOK(_ line: String) throws {
        guard line.hasPrefix("+OK") else {
            throw MailServiceError.serverRejected(line)
        }
    }

    private func readMultiline(socket: MailLineConnection) throws -> String {
        var lines: [String] = []
        while true {
            let line = try socket.readLine(timeout: 60)
            if line == "." { break }
            lines.append(line.hasPrefix("..") ? String(line.dropFirst()) : line)
        }
        return lines.joined(separator: "\r\n")
    }

    private func uidMap(socket: MailLineConnection) throws -> [Int: String] {
        let raw = try command("UIDL", socket: socket, multiline: true)
        return Dictionary(uniqueKeysWithValues: raw.split(whereSeparator: \.isNewline).compactMap { line in
            let parts = line.split(separator: " ", maxSplits: 1).map(String.init)
            guard parts.count == 2, let number = Int(parts[0]) else { return nil }
            return (number, parts[1])
        })
    }

    private func sizeMap(socket: MailLineConnection) throws -> [Int: Int64] {
        let raw = try command("LIST", socket: socket, multiline: true)
        return Dictionary(uniqueKeysWithValues: raw.split(whereSeparator: \.isNewline).compactMap { line in
            let parts = line.split(separator: " ", maxSplits: 1).map(String.init)
            guard parts.count == 2, let number = Int(parts[0]), let size = Int64(parts[1]) else { return nil }
            return (number, size)
        })
    }

    private func parseHeader(_ raw: String, number: Int, uidl: String?, size: Int64?) -> MessageHeader {
        let fields = unfoldHeaders(raw)
        let messageId = fields["message-id"] ?? "<pop3-\(uidl ?? String(number))@\(endpoint.host)>"
        let from = parseAddress(fields["from"] ?? "")
        var flags = MessageFlags()
        if fields["x-mymail-seen"] == "true" {
            flags.insert(.seen)
        }
        return MessageHeader(
            uid: Int64(number),
            messageId: messageId,
            subject: MIMEParser.decodeHeaderValue(fields["subject"] ?? "(无主题)"),
            fromAddress: from.email,
            fromName: from.name,
            date: parseDate(fields["date"] ?? "") ?? Date(),
            flags: flags
        )
    }

    private func unfoldHeaders(_ raw: String) -> [String: String] {
        let headerPart = raw.components(separatedBy: "\r\n\r\n").first ?? raw.components(separatedBy: "\n\n").first ?? raw
        var fields: [String: String] = [:]
        var currentKey: String?
        for line in headerPart.replacingOccurrences(of: "\r\n", with: "\n").split(separator: "\n", omittingEmptySubsequences: false).map(String.init) {
            if line.hasPrefix(" ") || line.hasPrefix("\t"), let currentKey {
                fields[currentKey, default: ""] += " " + line.trimmingCharacters(in: .whitespacesAndNewlines)
                continue
            }
            guard let colon = line.firstIndex(of: ":") else { continue }
            let key = String(line[..<colon]).lowercased()
            let value = String(line[line.index(after: colon)...]).trimmingCharacters(in: .whitespacesAndNewlines)
            fields[key] = value
            currentKey = key
        }
        return fields
    }

    private func parseAddress(_ raw: String) -> (name: String, email: String) {
        if let start = raw.firstIndex(of: "<"), let end = raw.firstIndex(of: ">"), start < end {
            let name = raw[..<start].trimmingCharacters(in: CharacterSet(charactersIn: " \""))
            let email = raw[raw.index(after: start)..<end]
            return (MIMEParser.decodeHeaderValue(String(name)), String(email))
        }
        return (MIMEParser.decodeHeaderValue(raw), raw)
    }

    private func parseDate(_ raw: String) -> Date? {
        MIMEParser.parseMailDate(raw)
    }

    private func splitRFC822Body(_ raw: String) -> (plain: String, html: String?) {
        let separators = ["\r\n\r\n", "\n\n"]
        for separator in separators {
            if let range = raw.range(of: separator) {
                let body = String(raw[range.upperBound...])
                if body.localizedCaseInsensitiveContains("<html") || body.localizedCaseInsensitiveContains("<body") {
                    return (body.replacingOccurrences(of: "<[^>]+>", with: " ", options: .regularExpression), body)
                }
                return (body, nil)
            }
        }
        return (raw, nil)
    }
}

final class IMAPClient {
    private let endpoint: ServerEndpoint
    private let credentials: MailConnectionCredentials
    private let connectionFactory: () -> MailLineConnection
    private var tagCounter = 0

    init(endpoint: ServerEndpoint, credentials: MailConnectionCredentials, connectionFactory: (() -> MailLineConnection)? = nil) {
        self.endpoint = endpoint
        self.credentials = credentials
        self.connectionFactory = connectionFactory ?? { LineSocket(endpoint: endpoint) }
    }

    func verify() throws {
        try withLoggedInSocket { socket in
            _ = try command("NOOP", socket: socket)
        }
    }

    func fetchMailboxes(accountId: UUID) throws -> [Mailbox] {
        try withLoggedInSocket { socket in
            let response = try command("LIST \"\" \"*\"", socket: socket)
            let folders = response
                .filter { $0.hasPrefix("* LIST") }
                .compactMap(parseMailboxEntry)
            let uniqueNames = Array(Set(folders.map(\.name))).sorted { lhs, rhs in
                if lhs == "INBOX" { return true }
                if rhs == "INBOX" { return false }
                return lhs.localizedStandardCompare(rhs) == .orderedAscending
            }
            let rolesByName = Dictionary(uniqueKeysWithValues: folders.map { ($0.name, $0.role) })
            return uniqueNames.map { name in
                Mailbox(id: UUID(), accountId: accountId, name: name, role: rolesByName[name] ?? role(for: name), uidValidity: 0, unreadCount: 0)
            }
        }
    }

    func fetchHeaders(mailbox: Mailbox, uidRange: ClosedRange<Int64>) throws -> [MessageHeader] {
        try withLoggedInSocket { socket in
            _ = try command("SELECT \"\(escapedMailboxName(mailbox.name))\"", socket: socket)
            return try fetchHeaderSet("\(uidRange.lowerBound):\(uidRange.upperBound)", socket: socket)
        }
    }

    func fetchLatestHeaders(mailbox: Mailbox, limit: Int) throws -> [MessageHeader] {
        try withLoggedInSocket { socket in
            _ = try command("SELECT \"\(escapedMailboxName(mailbox.name))\"", socket: socket)
            guard let uidSet = try latestUIDSet(limit: limit, socket: socket) else { return [] }
            return try fetchHeaderSet(uidSet, socket: socket)
        }
    }

    func fetchHeadersBefore(mailbox: Mailbox, beforeUID: Int64, limit: Int) throws -> [MessageHeader] {
        guard beforeUID > 1 else { return [] }
        return try withLoggedInSocket { socket in
            _ = try command("SELECT \"\(escapedMailboxName(mailbox.name))\"", socket: socket)
            guard let uidSet = try previousUIDSet(beforeUID: beforeUID, limit: limit, socket: socket) else { return [] }
            return try fetchHeaderSet(uidSet, socket: socket)
        }
    }

    func fetchBody(mailbox: Mailbox, uid: Int64) throws -> MessageBody {
        try withLoggedInSocket { socket in
            _ = try command("SELECT \"\(escapedMailboxName(mailbox.name))\"", socket: socket)
            let response = try command("UID FETCH \(uid) (BODY.PEEK[])", socket: socket, timeout: 90)
            let raw = stripIMAPFetchEnvelope(response.joined(separator: "\n"))
            return MIMEParser.parseMessageBody(raw)
        }
    }

    func appendMessage(_ data: Data, to mailbox: Mailbox, flags: MessageFlags = [.seen]) throws -> Int64? {
        try withLoggedInSocket { socket in
            let response = try append(data, to: mailbox, flags: flags, socket: socket)
            return appendedUID(from: response)
        }
    }

    func idle(mailbox: Mailbox, onEvent: (MailboxEvent) -> Bool) throws {
        try withLoggedInSocket { socket in
            _ = try command("SELECT \"\(escapedMailboxName(mailbox.name))\"", socket: socket)
            tagCounter += 1
            let tag = "A\(tagCounter)"
            try socket.sendLine("\(tag) IDLE")
            let continuation = try socket.readLine(timeout: 30)
            guard continuation.hasPrefix("+") else {
                throw MailServiceError.serverRejected(continuation)
            }

            var shouldContinue = true
            while shouldContinue {
                let line = try socket.readLine(timeout: 300)
                if line.hasPrefix("\(tag) OK") { break }
                if line.hasPrefix("\(tag) NO") || line.hasPrefix("\(tag) BAD") {
                    throw MailServiceError.serverRejected(line)
                }
                if let event = parseIdleEvent(line) {
                    shouldContinue = onEvent(event)
                }
            }
            try socket.sendLine("DONE")
            _ = try readTaggedResponse(tag: tag, socket: socket, timeout: 30)
        }
    }

    func setFlags(mailbox: Mailbox, uid: Int64, flags: MessageFlags) throws {
        try withLoggedInSocket { socket in
            _ = try command("SELECT \"\(escapedMailboxName(mailbox.name))\"", socket: socket)
            _ = try command("UID STORE \(uid) FLAGS (\(imapFlags(flags)))", socket: socket)
        }
    }

    func moveMessage(mailbox: Mailbox, uid: Int64, target: Mailbox) throws {
        try withLoggedInSocket { socket in
            _ = try command("SELECT \"\(escapedMailboxName(mailbox.name))\"", socket: socket)
            _ = try command("UID MOVE \(uid) \"\(escapedMailboxName(target.name))\"", socket: socket)
        }
    }

    func deleteMessage(mailbox: Mailbox, uid: Int64) throws {
        try withLoggedInSocket { socket in
            _ = try command("SELECT \"\(escapedMailboxName(mailbox.name))\"", socket: socket)
            _ = try command("UID STORE \(uid) +FLAGS.SILENT (\\Deleted)", socket: socket)
            do {
                _ = try command("UID EXPUNGE \(uid)", socket: socket)
            } catch {
                _ = try command("EXPUNGE", socket: socket, timeout: 60)
            }
        }
    }

    private func withLoggedInSocket<T>(_ body: (MailLineConnection) throws -> T) throws -> T {
        let mode = endpoint.normalizedTLSMode
        guard ServerEndpoint.supportedTLSModes.contains(mode) else {
            throw MailServiceError.unsupportedTLSMode(endpoint.tlsMode)
        }
        let socket = connectionFactory()
        try socket.open()
        defer { socket.close() }
        _ = try socket.readLine(timeout: 15)
        if mode == "STARTTLS" {
            _ = try command("STARTTLS", socket: socket)
            try socket.upgradeToTLS()
        }
        if credentials.usesOAuth2 {
            _ = try command("AUTHENTICATE XOAUTH2 \(credentials.xoauth2Token())", socket: socket)
        } else {
            _ = try command("LOGIN \"\(escapeIMAP(credentials.username))\" \"\(escapeIMAP(credentials.password))\"", socket: socket)
        }
        let result = try body(socket)
        _ = try? command("LOGOUT", socket: socket)
        return result
    }

    private func command(_ line: String, socket: MailLineConnection, timeout: TimeInterval = 30) throws -> [String] {
        tagCounter += 1
        let tag = "A\(tagCounter)"
        try socket.sendLine("\(tag) \(line)")
        return try readTaggedResponse(tag: tag, socket: socket, timeout: timeout)
    }

    private func append(_ data: Data, to mailbox: Mailbox, flags: MessageFlags, socket: MailLineConnection) throws -> [String] {
        tagCounter += 1
        let tag = "A\(tagCounter)"
        let flagList = imapFlags(flags)
        let flagSection = flagList.isEmpty ? "" : " (\(flagList))"
        try socket.sendLine("\(tag) APPEND \"\(escapedMailboxName(mailbox.name))\"\(flagSection) {\(data.count)}")
        let continuation = try socket.readLine(timeout: 30)
        guard continuation.hasPrefix("+") else {
            throw MailServiceError.serverRejected(continuation)
        }
        try socket.write(data)
        try socket.write(Data("\r\n".utf8))
        return try readTaggedResponse(tag: tag, socket: socket, timeout: 60)
    }

    private func appendedUID(from response: [String]) -> Int64? {
        let text = response.joined(separator: "\n")
        return Int64(firstCapture(#"APPENDUID\s+\d+\s+(\d+)"#, in: text))
    }

    private func readTaggedResponse(tag: String, socket: MailLineConnection, timeout: TimeInterval) throws -> [String] {
        var lines: [String] = []
        while true {
            let response = try socket.readLine(timeout: timeout)
            lines.append(response)
            if response.hasPrefix("\(tag) OK") {
                return lines
            }
            if response.hasPrefix("\(tag) NO") || response.hasPrefix("\(tag) BAD") {
                throw MailServiceError.serverRejected(response)
            }
        }
    }

    private func parseIdleEvent(_ line: String) -> MailboxEvent? {
        if let exists = Int(firstCapture(#"^\*\s+(\d+)\s+EXISTS"#, in: line)) {
            return .exists(exists)
        }
        if let sequence = Int64(firstCapture(#"^\*\s+(\d+)\s+EXPUNGE"#, in: line)) {
            return .expunge(sequence)
        }
        if line.contains(" FETCH "), let uid = Int64(firstCapture(#"UID\s+(\d+)"#, in: line)) {
            return .flagsChanged(uid: uid, flags: parseFlags(line))
        }
        return nil
    }

    private func parseMailboxName(_ line: String) -> String? {
        guard let quote = line.lastIndex(of: "\"") else { return nil }
        let prefix = line[..<quote]
        guard let start = prefix.lastIndex(of: "\"") else { return nil }
        return decodeModifiedUTF7(String(prefix[prefix.index(after: start)..<quote]))
    }

    private func parseMailboxEntry(_ line: String) -> (name: String, role: MailboxRole)? {
        guard let name = parseMailboxName(line) else { return nil }
        return (name, role(for: name, listLine: line))
    }

    private func latestUIDSet(limit: Int, socket: MailLineConnection) throws -> String? {
        let response = try command("UID SEARCH ALL", socket: socket, timeout: 60)
        let uids = response
            .flatMap { line in
                line.split(separator: " ")
                    .compactMap { Int64($0) }
            }
            .sorted()
            .suffix(max(limit, 1))
        guard !uids.isEmpty else { return nil }
        return uids.map(String.init).joined(separator: ",")
    }

    private func previousUIDSet(beforeUID: Int64, limit: Int, socket: MailLineConnection) throws -> String? {
        let upperBound = max(beforeUID - 1, 1)
        let response = try command("UID SEARCH UID 1:\(upperBound)", socket: socket, timeout: 60)
        let uids = response
            .flatMap { line in
                line.split(separator: " ")
                    .compactMap { Int64($0) }
            }
            .filter { $0 < beforeUID }
            .sorted()
            .suffix(max(limit, 1))
        guard !uids.isEmpty else { return nil }
        return uids.map(String.init).joined(separator: ",")
    }

    private func fetchHeaderSet(_ uidSet: String, socket: MailLineConnection) throws -> [MessageHeader] {
        let request = "UID FETCH \(uidSet) (UID FLAGS INTERNALDATE BODY.PEEK[HEADER.FIELDS (MESSAGE-ID SUBJECT FROM DATE)])"
        let response = try command(request, socket: socket, timeout: 60)
        return parseHeaders(response.joined(separator: "\n"))
    }

    private func role(for name: String, listLine: String = "") -> MailboxRole {
        let lower = name.lowercased()
        let lowerLine = listLine.lowercased()
        if lower == "inbox" { return .inbox }
        if lowerLine.contains("\\sent") || lower.contains("sent") || lower.contains("已发送") || lower.contains("已傳送") { return .sent }
        if lowerLine.contains("\\drafts") || lower.contains("draft") || lower.contains("草稿") { return .drafts }
        if lowerLine.contains("\\trash") || lower.contains("trash") || lower.contains("deleted") || lower.contains("垃圾箱") || lower.contains("废纸篓") || lower.contains("垃圾桶") { return .trash }
        if lowerLine.contains("\\junk") || lower.contains("junk") || lower.contains("spam") || lower.contains("bulk mail") || lower.contains("垃圾邮件") || lower.contains("垃圾郵件") || lower.contains("垃圾信") || lower.contains("垃圾信件") { return .junk }
        if lowerLine.contains("\\archive") || lower.contains("archive") || lower.contains("归档") || lower.contains("封存") { return .archive }
        return .custom
    }

    private func parseHeaders(_ raw: String) -> [MessageHeader] {
        let chunks = raw.components(separatedBy: "\n* ").filter { $0.contains("UID ") }
        return chunks.compactMap { chunk in
            guard let uid = Int64(firstCapture(#"UID\s+(\d+)"#, in: chunk)) else { return nil }
            let fields = unfoldHeaders(chunk)
            return MessageHeader(
                uid: uid,
                messageId: fields["message-id"] ?? "<\(uid)@\(endpoint.host)>",
                subject: MIMEParser.decodeHeaderValue(fields["subject"] ?? "(无主题)"),
                fromAddress: parseAddress(fields["from"] ?? "").email,
                fromName: parseAddress(fields["from"] ?? "").name,
                date: parseDate(fields["date"] ?? "") ?? Date(),
                receivedDate: parseInternalDate(chunk),
                flags: parseFlags(chunk)
            )
        }
    }

    private func parseInternalDate(_ raw: String) -> Date? {
        let value = firstCapture(#"INTERNALDATE\s+"([^"]+)""#, in: raw)
        guard !value.isEmpty else { return nil }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "d-MMM-yyyy HH:mm:ss Z"
        return formatter.date(from: value)
    }

    private func unfoldHeaders(_ raw: String) -> [String: String] {
        var fields: [String: String] = [:]
        var currentKey: String?
        let normalized = raw.replacingOccurrences(of: "\r\n", with: "\n")
        for line in normalized.split(separator: "\n", omittingEmptySubsequences: false).map(String.init) {
            if line.hasPrefix(" ") || line.hasPrefix("\t"), let currentKey {
                fields[currentKey, default: ""] += " " + line.trimmingCharacters(in: .whitespacesAndNewlines)
                continue
            }
            guard let colon = line.firstIndex(of: ":") else { continue }
            let key = String(line[..<colon]).lowercased()
            let value = String(line[line.index(after: colon)...]).trimmingCharacters(in: .whitespacesAndNewlines)
            fields[key] = value
            currentKey = key
        }
        return fields
    }

    private func firstCapture(_ pattern: String, in text: String) -> String {
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              let range = Range(match.range(at: 1), in: text) else { return "" }
        return String(text[range])
    }

    private func parseAddress(_ raw: String) -> (name: String, email: String) {
        if let start = raw.firstIndex(of: "<"), let end = raw.firstIndex(of: ">"), start < end {
            let name = String(raw[..<start]).trimmingCharacters(in: CharacterSet(charactersIn: " \""))
            return (MIMEParser.decodeHeaderValue(name), String(raw[raw.index(after: start)..<end]))
        }
        return (MIMEParser.decodeHeaderValue(raw), raw)
    }

    private func parseDate(_ raw: String) -> Date? {
        MIMEParser.parseMailDate(raw)
    }

    private func parseFlags(_ raw: String) -> MessageFlags {
        var flags = MessageFlags()
        if raw.contains("\\Seen") { flags.insert(.seen) }
        if raw.contains("\\Flagged") { flags.insert(.flagged) }
        if raw.contains("\\Answered") { flags.insert(.answered) }
        if raw.contains("\\Draft") { flags.insert(.draft) }
        if raw.contains("\\Deleted") { flags.insert(.deleted) }
        return flags
    }

    private func imapFlags(_ flags: MessageFlags) -> String {
        var values: [String] = []
        if flags.contains(.seen) { values.append("\\Seen") }
        if flags.contains(.flagged) { values.append("\\Flagged") }
        if flags.contains(.answered) { values.append("\\Answered") }
        if flags.contains(.draft) { values.append("\\Draft") }
        if flags.contains(.deleted) { values.append("\\Deleted") }
        return values.joined(separator: " ")
    }

    private func stripIMAPFetchEnvelope(_ raw: String) -> String {
        guard let firstBrace = raw.firstIndex(of: "{"), let firstNewline = raw[firstBrace...].firstIndex(of: "\n") else { return raw }
        let suffix = raw[raw.index(after: firstNewline)...]
        if let last = suffix.range(of: "\n)", options: .backwards) {
            return String(suffix[..<last.lowerBound])
        }
        return String(suffix)
    }

    private func splitRFC822Body(_ raw: String) -> (plain: String, html: String?) {
        let separators = ["\r\n\r\n", "\n\n"]
        for separator in separators {
            if let range = raw.range(of: separator) {
                let body = String(raw[range.upperBound...])
                if body.localizedCaseInsensitiveContains("<html") || body.localizedCaseInsensitiveContains("<body") {
                    return (body.replacingOccurrences(of: "<[^>]+>", with: " ", options: .regularExpression), body)
                }
                return (body, nil)
            }
        }
        return (raw, nil)
    }

    private func escapeIMAP(_ value: String) -> String {
        value.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
    }

    private func escapedMailboxName(_ value: String) -> String {
        escapeIMAP(encodeModifiedUTF7(value))
    }

    private func decodeModifiedUTF7(_ value: String) -> String {
        var result = ""
        var index = value.startIndex
        while index < value.endIndex {
            if value[index] == "&" {
                guard let end = value[index...].firstIndex(of: "-") else {
                    result.append(value[index])
                    index = value.index(after: index)
                    continue
                }
                let encodedStart = value.index(after: index)
                let encoded = String(value[encodedStart..<end])
                if encoded.isEmpty {
                    result.append("&")
                } else {
                    var base64 = encoded.replacingOccurrences(of: ",", with: "/")
                    let padding = (4 - base64.count % 4) % 4
                    base64 += String(repeating: "=", count: padding)
                    if let data = Data(base64Encoded: base64),
                       let decoded = String(data: data, encoding: .utf16BigEndian) {
                        result.append(decoded)
                    } else {
                        result.append("&\(encoded)-")
                    }
                }
                index = value.index(after: end)
            } else {
                result.append(value[index])
                index = value.index(after: index)
            }
        }
        return result
    }

    private func encodeModifiedUTF7(_ value: String) -> String {
        var result = ""
        var buffer = ""

        func flushBuffer() {
            guard !buffer.isEmpty else { return }
            guard let data = buffer.data(using: .utf16BigEndian) else {
                result.append(buffer)
                buffer = ""
                return
            }
            let encoded = data.base64EncodedString()
                .replacingOccurrences(of: "/", with: ",")
                .replacingOccurrences(of: "=", with: "")
            result.append("&\(encoded)-")
            buffer = ""
        }

        for character in value {
            if character == "&" {
                flushBuffer()
                result.append("&-")
                continue
            }
            if character.unicodeScalars.count == 1,
               let scalar = character.unicodeScalars.first,
               scalar.value >= 0x20,
               scalar.value <= 0x7e {
                flushBuffer()
                result.append(character)
            } else {
                buffer.append(character)
            }
        }
        flushBuffer()
        return result
    }
}

private extension String {
    var nilIfEmpty: String? {
        isEmpty ? nil : self
    }
}
