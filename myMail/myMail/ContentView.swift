//
//  ContentView.swift
//  myMail
//

import AppKit
import SwiftUI
import UniformTypeIdentifiers
import WebKit

struct ContentView: View {
    @EnvironmentObject private var viewModel: MailAppViewModel
    @Environment(\.openWindow) private var openWindow
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        NavigationSplitView {
            AccountSidebar()
                .navigationSplitViewColumnWidth(min: 220, ideal: 260, max: 320)
        } content: {
            MessageListView(openCompose: {
                openWindow(id: "compose")
            })
            .navigationSplitViewColumnWidth(min: 320, ideal: 390, max: 520)
        } detail: {
            ReadingPane(openCompose: {
                openWindow(id: "compose")
            })
        }
        .toolbar {
            ToolbarItemGroup {
                Button {
                    viewModel.refresh()
                } label: {
                    Label(viewModel.localized(.receiveNewMail), systemImage: "arrow.clockwise")
                }
                .help(viewModel.localized(.refreshHelp))

                Button {
                    viewModel.startCompose()
                    openWindow(id: "compose")
                } label: {
                    Label(viewModel.localized(.compose), systemImage: "square.and.pencil")
                }
                .help(viewModel.localized(.composeHelp))

                Button {
                    openSettings()
                } label: {
                    Label(viewModel.localized(.settings), systemImage: "gearshape")
                }
            }
        }
    }
}

private struct AccountSidebar: View {
    @EnvironmentObject private var viewModel: MailAppViewModel
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        VStack(spacing: 0) {
            List(selection: $viewModel.selectedMailboxID) {
                Section(viewModel.localized(.smartMailboxes)) {
                    Button {
                        viewModel.selectSmartMailbox(.starred)
                    } label: {
                        HStack {
                            Image(systemName: SmartMailbox.starred.symbolName)
                                .foregroundStyle(.yellow)
                                .frame(width: 18)
                            Text(viewModel.localized(.starredMail))
                            Spacer()
                            if viewModel.starredMessageCount > 0 {
                                Text("\(viewModel.starredMessageCount)")
                                    .font(.caption)
                                    .padding(.horizontal, 6)
                                    .padding(.vertical, 2)
                                    .background(.quaternary, in: Capsule())
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .listRowBackground(viewModel.selectedSmartMailbox == .starred ? Color.accentColor.opacity(0.14) : Color.clear)
                }

                ForEach(viewModel.accounts) { account in
                    Section(account.displayName) {
                        ForEach(viewModel.mailboxes.filter { $0.accountId == account.id }) { mailbox in
                            Button {
                                viewModel.selectMailbox(mailbox)
                            } label: {
                                HStack {
                                    Image(systemName: mailbox.role.symbolName)
                                        .frame(width: 18)
                                    Text(mailbox.name)
                                    Spacer()
                                    if mailbox.unreadCount > 0 {
                                        Text("\(mailbox.unreadCount)")
                                            .font(.caption)
                                            .padding(.horizontal, 6)
                                            .padding(.vertical, 2)
                                            .background(.quaternary, in: Capsule())
                                    }
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .tag(mailbox.id)
                        }
                    }
                }
            }

            Divider()

            HStack {
                Text(viewModel.statusMessage)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                Spacer()
                Button {
                    openSettings()
                } label: {
                    Image(systemName: "gearshape")
                }
                .help(viewModel.localized(.settings))
            }
            .padding(10)
        }
    }
}

private struct MessageListView: View {
    @EnvironmentObject private var viewModel: MailAppViewModel
    let openCompose: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Picker(viewModel.localized(.searchMode), selection: $viewModel.searchMode) {
                    ForEach(SearchMode.allCases) { mode in
                        Text(viewModel.localized(mode)).tag(mode)
                    }
                }
                .pickerStyle(.segmented)

                Menu {
                    Picker(viewModel.localized(.sortField), selection: $viewModel.messageSortField) {
                        ForEach(MessageSortField.allCases) { field in
                            Text(viewModel.localized(field)).tag(field)
                        }
                    }
                    Divider()
                    Picker(viewModel.localized(.sortOrder), selection: $viewModel.messageSortAscending) {
                        Text(viewModel.localizedSortTitle(field: viewModel.messageSortField, ascending: true)).tag(true)
                        Text(viewModel.localizedSortTitle(field: viewModel.messageSortField, ascending: false)).tag(false)
                    }
                } label: {
                    Label(viewModel.localized(.sort), systemImage: "arrow.up.arrow.down")
                }
                .help(viewModel.localized(.sortHelp))

                Button {
                    viewModel.startCompose()
                    openCompose()
                } label: {
                    Image(systemName: "square.and.pencil")
                }
                .help(viewModel.localized(.compose))
            }
            .padding([.horizontal, .top], 12)

            if viewModel.searchMode == .filter {
                HStack {
                    Image(systemName: "magnifyingglass")
                        .foregroundStyle(.secondary)
                    TextField(viewModel.localized(.searchPlaceholder), text: $viewModel.searchText)
                        .textFieldStyle(.plain)
                }
                .padding(8)
                .background(.quaternary, in: RoundedRectangle(cornerRadius: 8))
                .padding(12)
            } else {
                AIQuestionBar()
                    .padding(12)
            }

            List(selection: $viewModel.selectedMessageID) {
                let visibleMessages = viewModel.visibleMessages
                let loadMoreTriggerID = visibleMessages.suffix(8).first?.id
                ForEach(visibleMessages) { message in
                    MessageRow(message: message)
                        .tag(message.id)
                        .onAppear {
                            guard message.id == loadMoreTriggerID else { return }
                            Task { await viewModel.loadMoreMessagesIfNeeded(currentMessage: message) }
                        }
                }
                if viewModel.isLoadingMoreSelectedMailbox {
                    Text("正在加载更早的邮件...")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .center)
                        .padding(.vertical, 8)
                        .listRowSeparator(.hidden)
                }
            }
            .id(viewModel.messageListResetID)
            .transaction { transaction in
                transaction.animation = nil
            }
            .onChange(of: viewModel.selectedMessageID) { _, _ in
                if viewModel.openSelectedDraftForEditing() {
                    openCompose()
                } else {
                    Task { await viewModel.loadSelectedMessageBodyIfNeeded() }
                }
            }

            if let answer = viewModel.aiAnswer, viewModel.searchMode == .ai {
                AIAnswerPanel(answer: answer)
                    .padding(12)
            }
        }
    }
}

private struct AIQuestionBar: View {
    @EnvironmentObject private var viewModel: MailAppViewModel

    var body: some View {
        HStack(spacing: 8) {
            TextField(viewModel.localized(.aiQuestionPlaceholder), text: $viewModel.aiQuestion)
                .textFieldStyle(.roundedBorder)
                .onSubmit {
                    Task { await viewModel.runAIQuestion() }
                }

            Button {
                Task { await viewModel.runAIQuestion() }
            } label: {
                if viewModel.isSearchingAI {
                    ProgressView()
                        .controlSize(.small)
                } else {
                    Image(systemName: "sparkles")
                }
            }
            .help(viewModel.localized(.aiQuestionHelp))
        }
    }
}

private struct MessageRow: View {
    @EnvironmentObject private var viewModel: MailAppViewModel
    let message: MailMessage

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Circle()
                .fill(message.isUnread ? Color.accentColor : Color.clear)
                .frame(width: 8, height: 8)
                .padding(.top, 7)

            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text(message.senderDisplayName)
                        .fontWeight(message.isUnread ? .semibold : .regular)
                    Spacer()
                    Button {
                        viewModel.toggleStar(messageID: message.id)
                    } label: {
                        Image(systemName: message.flags.contains(.flagged) ? "star.fill" : "star")
                            .foregroundStyle(message.flags.contains(.flagged) ? .yellow : .secondary)
                    }
                    .buttonStyle(.borderless)
                    .help(message.flags.contains(.flagged) ? viewModel.localized(.removeStar) : viewModel.localized(.addStar))
                    Text(message.sortDate, style: .relative)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Text(message.subject)
                    .font(.callout)
                    .lineLimit(1)

                HStack(spacing: 6) {
                    Text(message.snippet)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                    if message.hasAttachments {
                        Image(systemName: "paperclip")
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
        .padding(.vertical, 6)
    }
}

private struct ReadingPane: View {
    @EnvironmentObject private var viewModel: MailAppViewModel
    let openCompose: () -> Void

    var body: some View {
        Group {
            if let message = viewModel.selectedMessage {
                VStack(spacing: 0) {
                    header(for: message)
                    Divider()
                    MailHTMLView(html: html(for: message))
                    Divider()
                    attachmentBar(for: message)
                }
                .onAppear {
                    if !viewModel.selectedMessageIsDraft {
                        viewModel.markSelectedSeen()
                    }
                }
            } else {
                ContentUnavailableView(
                    viewModel.localized(.selectMessage),
                    systemImage: "envelope.open",
                    description: Text(viewModel.localized(.messageBodyPlaceholder))
                )
            }
        }
    }

    private func header(for message: MailMessage) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(message.subject)
                        .font(.title2.weight(.semibold))
                    Text("\(message.senderDisplayName) <\(message.fromAddress)>")
                        .foregroundStyle(.secondary)
                    Text(message.sortDate.formatted(date: .abbreviated, time: .shortened))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button {
                    viewModel.toggleStar(messageID: message.id)
                } label: {
                    Image(systemName: message.flags.contains(.flagged) ? "star.fill" : "star")
                        .foregroundStyle(message.flags.contains(.flagged) ? .yellow : .secondary)
                }
                .buttonStyle(.borderless)
                .help(message.flags.contains(.flagged) ? viewModel.localized(.removeStar) : viewModel.localized(.addStar))
            }

            HStack {
                Button {
                    viewModel.replyToSelected()
                    openCompose()
                } label: {
                    Label(viewModel.localized(.reply), systemImage: "arrowshape.turn.up.left")
                }

                Button {
                    viewModel.forwardSelected()
                    openCompose()
                } label: {
                    Label(viewModel.localized(.forward), systemImage: "arrowshape.turn.up.right")
                }

                Button {
                    viewModel.replyToSelected()
                    openCompose()
                    Task { await viewModel.generateAIReplyDraft() }
                } label: {
                    Label(viewModel.localized(.aiReply), systemImage: "sparkles")
                }

                Button {
                    viewModel.archiveSelectedMessage()
                } label: {
                    Label(viewModel.localized(.archive), systemImage: "archivebox")
                }

                Button(role: .destructive) {
                    viewModel.deleteSelectedMessage()
                } label: {
                    Label(viewModel.localized(.delete), systemImage: "trash")
                }
            }
            .labelStyle(.iconOnly)
        }
        .padding(18)
    }

    private func attachmentBar(for message: MailMessage) -> some View {
        let items = viewModel.attachments(for: message)
        return ScrollView(.horizontal) {
            HStack(spacing: 8) {
                if items.isEmpty {
                    Text(viewModel.localized(.noAttachments))
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(items) { attachment in
                        AttachmentChip(attachment: attachment)
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(10)
        }
        .font(.caption)
    }

    private func html(for message: MailMessage) -> String {
        if let bodyHTML = message.bodyHTML {
            return bodyHTML
        }

        let text = message.bodyPlain ?? message.snippet
        return """
        <!doctype html>
        <html>
        <head>
            <meta charset="utf-8">
            <style>
                body {
                    color: -apple-system-label;
                    font: -apple-system-body;
                    margin: 16px;
                }
                pre {
                    font: -apple-system-body;
                    white-space: pre-wrap;
                    word-break: break-word;
                }
                a { color: -apple-system-control-accent; }
            </style>
        </head>
        <body><pre>\(Self.linkifiedEscapedHTML(text))</pre></body>
        </html>
        """
    }

    private static func linkifiedEscapedHTML(_ text: String) -> String {
        guard let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue) else {
            return escapeHTML(text)
        }

        let nsText = text as NSString
        let matches = detector.matches(in: text, range: NSRange(location: 0, length: nsText.length))
        guard !matches.isEmpty else {
            return escapeHTML(text)
        }

        var html = ""
        var cursor = 0
        for match in matches {
            guard match.range.location >= cursor else { continue }
            let plainPrefix = nsText.substring(with: NSRange(location: cursor, length: match.range.location - cursor))
            html += escapeHTML(plainPrefix)

            let visibleText = nsText.substring(with: match.range)
            let href = match.url?.absoluteString ?? visibleText
            html += "<a href=\"\(escapeHTMLAttribute(href))\">\(escapeHTML(visibleText))</a>"
            cursor = match.range.location + match.range.length
        }

        if cursor < nsText.length {
            html += escapeHTML(nsText.substring(from: cursor))
        }
        return html
    }

    private static func escapeHTML(_ text: String) -> String {
        text
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
    }

    private static func escapeHTMLAttribute(_ text: String) -> String {
        escapeHTML(text)
            .replacingOccurrences(of: "\"", with: "&quot;")
    }
}

private struct AttachmentChip: View {
    @EnvironmentObject private var viewModel: MailAppViewModel
    let attachment: MailAttachment

    var body: some View {
        HStack(spacing: 4) {
            Button(action: openAttachment) {
                HStack(spacing: 6) {
                    Image(nsImage: systemIcon)
                        .resizable()
                        .scaledToFit()
                        .frame(width: 22, height: 22)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(attachment.filename)
                            .lineLimit(1)
                        Text(ByteCountFormatter.string(fromByteCount: attachment.sizeBytes, countStyle: .file))
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(.leading, 8)
                .padding(.vertical, 6)
            }
            .buttonStyle(.plain)
            .disabled(attachment.localPath == nil)
            .help(attachment.localPath == nil ? viewModel.localized(.attachmentNotSaved) : viewModel.localized(.openAttachment))

            Button(action: saveAttachmentAs) {
                Image(systemName: "square.and.arrow.down")
                    .frame(width: 24, height: 24)
            }
            .buttonStyle(.borderless)
            .disabled(attachment.localPath == nil)
            .help(attachment.localPath == nil ? viewModel.localized(.attachmentNotSaved) : viewModel.localized(.saveAs))
        }
        .padding(.trailing, 6)
        .background(.quaternary, in: RoundedRectangle(cornerRadius: 8))
        .contextMenu {
            Button(viewModel.localized(.openAttachment), action: openAttachment)
                .disabled(attachment.localPath == nil)
            Button(viewModel.localized(.saveAs), action: saveAttachmentAs)
                .disabled(attachment.localPath == nil)
        }
    }

    private var systemIcon: NSImage {
        if let localPath = attachment.localPath {
            return NSWorkspace.shared.icon(forFile: localPath)
        }
        let fileExtension = URL(fileURLWithPath: attachment.filename).pathExtension
        if !fileExtension.isEmpty {
            if let type = UTType(filenameExtension: fileExtension) {
                return NSWorkspace.shared.icon(for: type)
            }
            return NSWorkspace.shared.icon(for: .data)
        }
        if let type = UTType(mimeType: attachment.mimeType) {
            return NSWorkspace.shared.icon(for: type)
        }
        return NSWorkspace.shared.icon(for: .data)
    }

    private func openAttachment() {
        guard let localPath = attachment.localPath else { return }
        NSWorkspace.shared.open(URL(fileURLWithPath: localPath))
    }

    private func saveAttachmentAs() {
        guard let localPath = attachment.localPath else { return }
        let source = URL(fileURLWithPath: localPath)
        let panel = NSSavePanel()
        panel.nameFieldStringValue = attachment.filename
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let destination = panel.url else { return }
        do {
            if FileManager.default.fileExists(atPath: destination.path) {
                try FileManager.default.removeItem(at: destination)
            }
            try FileManager.default.copyItem(at: source, to: destination)
        } catch {
            NSSound.beep()
        }
    }
}

private struct MailHTMLView: NSViewRepresentable {
    var html: String

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeNSView(context: Context) -> WKWebView {
        let view = WKWebView()
        view.setValue(false, forKey: "drawsBackground")
        view.navigationDelegate = context.coordinator
        return view
    }

    func updateNSView(_ nsView: WKWebView, context: Context) {
        guard context.coordinator.currentHTML != html else { return }
        context.coordinator.currentHTML = html
        nsView.loadHTMLString(html, baseURL: nil)
    }

    final class Coordinator: NSObject, WKNavigationDelegate {
        var currentHTML: String?

        func webView(
            _ webView: WKWebView,
            decidePolicyFor navigationAction: WKNavigationAction,
            decisionHandler: @escaping (WKNavigationActionPolicy) -> Void
        ) {
            guard let url = navigationAction.request.url else {
                decisionHandler(.allow)
                return
            }

            if shouldOpenExternally(url: url, navigationAction: navigationAction) {
                NSWorkspace.shared.open(url)
                decisionHandler(.cancel)
                return
            }

            decisionHandler(.allow)
        }

        private func shouldOpenExternally(url: URL, navigationAction: WKNavigationAction) -> Bool {
            guard navigationAction.navigationType == .linkActivated || navigationAction.targetFrame == nil else {
                return false
            }
            guard let scheme = url.scheme?.lowercased() else {
                return false
            }
            return !["about", "data", "blob", "javascript"].contains(scheme)
        }
    }
}

private struct AIAnswerPanel: View {
    @EnvironmentObject private var viewModel: MailAppViewModel
    let answer: SearchAnswer

    private var answerLines: [AIAnswerLine] {
        Self.normalizedMarkdown(answer.answer)
            .components(separatedBy: .newlines)
            .map(Self.parseLine)
    }

    var body: some View {
        ScrollView(.vertical) {
            VStack(alignment: .leading, spacing: 14) {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(Array(answerLines.enumerated()), id: \.offset) { _, line in
                        answerLineView(line)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .textSelection(.enabled)

                if !answer.citations.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(viewModel.localized(.relatedMessages))
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)

                        ForEach(Array(answer.citations.enumerated()), id: \.element.id) { index, message in
                            Button {
                                viewModel.selectMessage(message)
                            } label: {
                                HStack(alignment: .top, spacing: 10) {
                                    Text("[\(index + 1)]")
                                        .font(.caption.weight(.semibold).monospacedDigit())
                                        .foregroundStyle(.secondary)
                                        .frame(width: 34, alignment: .leading)
                                    VStack(alignment: .leading, spacing: 4) {
                                        Text(message.subject)
                                            .font(.caption.weight(.semibold))
                                            .lineLimit(2)
                                        Text("\(message.senderDisplayName) · \(message.sortDate.formatted(date: .abbreviated, time: .shortened))")
                                            .font(.caption2)
                                            .foregroundStyle(.secondary)
                                            .lineLimit(1)
                                        if !message.snippet.isEmpty {
                                            Text(message.snippet)
                                                .font(.caption2)
                                                .foregroundStyle(.secondary)
                                                .lineLimit(2)
                                        }
                                    }
                                    .fixedSize(horizontal: false, vertical: true)
                                    Spacer(minLength: 8)
                                    Image(systemName: "arrow.right.circle")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                        .padding(.top, 2)
                                }
                                .contentShape(Rectangle())
                                .padding(10)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .background(.background.opacity(0.68), in: RoundedRectangle(cornerRadius: 6))
                            }
                            .buttonStyle(.plain)
                            .help(viewModel.localized(.openOriginalMessage))
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.top, 2)
                }
            }
            .padding(12)
        }
        .frame(maxHeight: 320)
        .background(.quaternary, in: RoundedRectangle(cornerRadius: 8))
    }

    @ViewBuilder
    private func answerLineView(_ line: AIAnswerLine) -> some View {
        switch line.kind {
        case .blank:
            Color.clear.frame(height: 3)
        case .heading:
            Text(Self.attributed(line.text))
                .font(.callout.weight(.semibold))
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        case .paragraph:
            Text(Self.attributed(line.text))
                .font(.callout)
                .lineSpacing(3)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        case .bullet(let marker):
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(marker)
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 18, alignment: .trailing)
                Text(Self.attributed(line.text))
                    .font(.callout)
                    .lineSpacing(3)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        case .citation(let marker):
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(marker)
                    .font(.caption.weight(.semibold).monospacedDigit())
                    .foregroundStyle(.secondary)
                    .frame(width: 34, alignment: .trailing)
                Text(Self.attributed(line.text))
                    .font(.callout)
                    .lineSpacing(3)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    nonisolated private static func attributed(_ markdown: String) -> AttributedString {
        (try? AttributedString(
            markdown: markdown,
            options: AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        )) ?? AttributedString(markdown)
    }

    nonisolated private static func normalizedMarkdown(_ markdown: String) -> String {
        var text = markdown
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
        text = text.replacingOccurrences(
            of: #"\](?=[^\s\]\),.;:!?，。；：！？、])"#,
            with: "] ",
            options: .regularExpression
        )
        text = text.replacingOccurrences(
            of: #"(?<!\n)(?=\[\d+\]\s*(?:Jan|Feb|Mar|Apr|May|Jun|Jul|Aug|Sep|Oct|Nov|Dec)\b)"#,
            with: "\n",
            options: .regularExpression
        )
        text = text.replacingOccurrences(
            of: #"(?<=[。！？.!?])\s+(?=\[\d+\])"#,
            with: "\n",
            options: .regularExpression
        )
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    nonisolated private static func parseLine(_ rawLine: String) -> AIAnswerLine {
        let trimmed = rawLine.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else {
            return AIAnswerLine(kind: .blank, text: "")
        }

        if let headingRange = trimmed.range(of: #"^#{1,4}\s+"#, options: .regularExpression) {
            return AIAnswerLine(kind: .heading, text: String(trimmed[headingRange.upperBound...]))
        }

        for prefix in ["- ", "* ", "• "] where trimmed.hasPrefix(prefix) {
            return AIAnswerLine(kind: .bullet("•"), text: String(trimmed.dropFirst(prefix.count)))
        }

        if let numberedRange = trimmed.range(of: #"^\d+[\.)]\s+"#, options: .regularExpression) {
            let marker = String(trimmed[numberedRange]).trimmingCharacters(in: .whitespaces)
            return AIAnswerLine(kind: .bullet(marker), text: String(trimmed[numberedRange.upperBound...]))
        }

        if let citationRange = trimmed.range(of: #"^\[\d+\]\s*"#, options: .regularExpression) {
            let marker = String(trimmed[citationRange]).trimmingCharacters(in: .whitespaces)
            return AIAnswerLine(kind: .citation(marker), text: String(trimmed[citationRange.upperBound...]))
        }

        return AIAnswerLine(kind: .paragraph, text: trimmed)
    }

    private struct AIAnswerLine {
        enum Kind {
            case blank
            case heading
            case paragraph
            case bullet(String)
            case citation(String)
        }

        var kind: Kind
        var text: String
    }
}

struct ComposeWindowView: View {
    @EnvironmentObject private var viewModel: MailAppViewModel
    @State private var isChoosingAttachments = false

    var body: some View {
        VStack(spacing: 12) {
            Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 8) {
                GridRow {
                    Text(viewModel.localized(.recipient))
                    TextField("name@example.com", text: draftBinding(\.to))
                }
                GridRow {
                    Text(viewModel.localized(.cc))
                    TextField("", text: draftBinding(\.cc))
                }
                GridRow {
                    Text(viewModel.localized(.subject))
                    TextField("", text: draftBinding(\.subject))
                }
                GridRow {
                    Text(viewModel.localized(.aiInstruction))
                    TextField(viewModel.localized(.composeInstructionPlaceholder), text: draftBinding(\.instruction))
                }
            }

            TextEditor(text: draftBinding(\.body))
                .font(.body)
                .frame(minHeight: 320)
                .overlay {
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(.quaternary)
                }

            if !viewModel.composeDraft.attachmentURLs.isEmpty {
                ScrollView(.horizontal) {
                    HStack(spacing: 8) {
                        ForEach(viewModel.composeDraft.attachmentURLs, id: \.self) { url in
                            DraftAttachmentChip(url: url) {
                                viewModel.removeDraftAttachment(url)
                            }
                        }
                    }
                }
            }

            HStack {
                Button {
                    Task { await viewModel.generateAIReplyDraft() }
                } label: {
                    Label(viewModel.localized(.generateAIDraft), systemImage: "sparkles")
                }

                Button {
                    isChoosingAttachments = true
                } label: {
                    Label(viewModel.localized(.addAttachment), systemImage: "paperclip")
                }

                Spacer()

                Button {
                    viewModel.sendDraft()
                } label: {
                    Label(viewModel.localized(.send), systemImage: "paperplane.fill")
                }
                .keyboardShortcut(.return, modifiers: [.command])
            }
        }
        .padding(16)
        .frame(minWidth: 720, minHeight: 520)
        .navigationTitle(viewModel.localized(.composeMailWindowTitle))
        .onDisappear {
            Task { await viewModel.synchronizeDraftImmediately() }
        }
        .fileImporter(isPresented: $isChoosingAttachments, allowedContentTypes: [.item], allowsMultipleSelection: true) { result in
            if case .success(let urls) = result {
                viewModel.addDraftAttachments(urls)
            }
        }
    }

    private func draftBinding(_ keyPath: WritableKeyPath<ComposeDraft, String>) -> Binding<String> {
        Binding(
            get: { viewModel.composeDraft[keyPath: keyPath] },
            set: { value in
                viewModel.updateComposeDraft { draft in
                    draft[keyPath: keyPath] = value
                }
            }
        )
    }
}

private struct DraftAttachmentChip: View {
    @EnvironmentObject private var viewModel: MailAppViewModel
    let url: URL
    let remove: () -> Void

    var body: some View {
        HStack(spacing: 6) {
            Image(nsImage: NSWorkspace.shared.icon(forFile: url.path))
                .resizable()
                .scaledToFit()
                .frame(width: 22, height: 22)
            VStack(alignment: .leading, spacing: 2) {
                Text(url.lastPathComponent)
                    .lineLimit(1)
                Text(fileSizeLabel)
                    .foregroundStyle(.secondary)
            }
            Button(action: remove) {
                Image(systemName: "xmark.circle.fill")
            }
            .buttonStyle(.plain)
            .help(viewModel.localized(.removeAttachment))
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(.quaternary, in: RoundedRectangle(cornerRadius: 8))
    }

    private var fileSizeLabel: String {
        guard let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize else { return viewModel.localized(.pendingToSend) }
        return ByteCountFormatter.string(fromByteCount: Int64(size), countStyle: .file)
    }
}

struct SettingsView: View {
    @EnvironmentObject private var viewModel: MailAppViewModel
    @State private var newAPIKey = ""
    @State private var newModelName = ""
    @State private var accountProvider: MailProvider = .generic
    @State private var accountProtocol: MailProtocolChoice = .imap
    @State private var accountEmail = ""
    @State private var accountPassword = ""
    @State private var accountOAuthToken = ""
    @State private var customIMAPHost = ""
    @State private var customIMAPPort = 993
    @State private var customIMAPTLS = "SSL"
    @State private var customSMTPHost = ""
    @State private var customSMTPPort = 465
    @State private var customSMTPTLS = "SSL"
    @State private var customPOP3Host = ""
    @State private var customPOP3Port = 995
    @State private var customPOP3TLS = "SSL"
    @State private var reauthPasswords: [UUID: String] = [:]
    @State private var testedAccountSignature: String?
    @State private var isTestingAccountConnection = false
    @State private var accountConnectionFeedback: String?
    @State private var accountPendingDeletion: MailAccount?
    @State private var showsDeleteAccountConfirmation = false

    var body: some View {
        TabView {
            accountsTab
                .tabItem { Label(viewModel.localized(.accounts), systemImage: "person.crop.circle") }

            aiTab
                .tabItem { Label(viewModel.localized(.aiModel), systemImage: "sparkles") }

            generalTab
                .tabItem { Label(viewModel.localized(.general), systemImage: "slider.horizontal.3") }
        }
        .padding(20)
        .frame(width: 640, height: 540)
    }

    private var accountsTab: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                List(viewModel.accounts) { account in
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            VStack(alignment: .leading, spacing: 3) {
                                Text(account.displayName)
                                    .fontWeight(.semibold)
                                Text("\(viewModel.localizedProviderTitle(account.provider)) · \(account.useProtocol.rawValue.uppercased()) · \(account.emailAddress)")
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            if account.needsReauth {
                                Label(viewModel.localized(.needsReauth), systemImage: "exclamationmark.triangle.fill")
                                    .font(.caption)
                                    .foregroundStyle(.red)
                            }
                            Button(role: .destructive) {
                                accountPendingDeletion = account
                                showsDeleteAccountConfirmation = true
                            } label: {
                                Image(systemName: "trash")
                            }
                            .buttonStyle(.borderless)
                            .help(viewModel.localized(.deleteAccountConfig))
                        }

                        if account.needsReauth {
                            HStack {
                                SecureField(viewModel.localized(.newAppPassword), text: Binding(
                                    get: { reauthPasswords[account.id, default: ""] },
                                    set: { reauthPasswords[account.id] = $0 }
                                ))
                                Button(viewModel.localized(.updatePassword)) {
                                    viewModel.updateAccountPassword(accountID: account.id, password: reauthPasswords[account.id, default: ""])
                                    reauthPasswords[account.id] = ""
                                }
                                .disabled(reauthPasswords[account.id, default: ""].trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                            }
                        }
                    }
                }
                .frame(height: accountListHeight)

                Picker(viewModel.localized(.provider), selection: $accountProvider) {
                    Text(viewModel.localizedProviderTitle(.generic)).tag(MailProvider.generic)
                    Text(viewModel.localizedProviderTitle(.gmail)).tag(MailProvider.gmail)
                }
                .pickerStyle(.segmented)
                .onChange(of: accountProvider) { _, newProvider in
                    accountProtocol = .imap
                    testedAccountSignature = nil
                    accountConnectionFeedback = nil
                    if newProvider == .gmail {
                        customIMAPHost = ""
                        customSMTPHost = ""
                        customPOP3Host = ""
                    }
                }

                let preset = ProviderPreset.preset(for: accountProvider)
                Picker(viewModel.localized(.receivingProtocol), selection: $accountProtocol) {
                    Text("IMAP").tag(MailProtocolChoice.imap)
                    Text("POP3").tag(MailProtocolChoice.pop3)
                }
                .pickerStyle(.segmented)
                .disabled(accountProvider == .gmail || preset.pop3 == nil)
                .onChange(of: accountProtocol) { _, newValue in
                    if accountProvider == .gmail && newValue != .imap {
                        accountProtocol = .imap
                    }
                }

                Text(accountServerSummary)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                Text(viewModel.localizedProviderInlineNote(accountProvider))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if usesManualServerConfig {
                    customServerFields
                }
                if preset.supportsOAuth2 {
                    Text(viewModel.localized(.oauthBrowserLoginNote))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    Text(viewModel.localized(.appPasswordVisibilityNote))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                if accountProvider == .gmail {
                    VStack(alignment: .leading, spacing: 8) {
                        Label(viewModel.localized(.gmailAppPasswordGuideTitle), systemImage: "exclamationmark.shield")
                            .font(.caption.weight(.semibold))
                        Text(viewModel.localized(.gmailAppPasswordGuideSteps))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        HStack(spacing: 12) {
                            if let url = preset.appPasswordHelpURL {
                                Link(destination: url) {
                                    Label(viewModel.localized(.gmailAppPasswordOpenGoogle), systemImage: "safari")
                                }
                            }
                            Link(destination: URL(string: "https://support.google.com/accounts/answer/185833")!) {
                                Label(viewModel.localized(.documentation), systemImage: "questionmark.circle")
                            }
                        }
                        Text(viewModel.localized(.gmailAppPasswordSecurityNote))
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(.quaternary, in: RoundedRectangle(cornerRadius: 6))
                }

                Label(accountConnectionFeedbackText, systemImage: accountConnectionFeedbackIcon)
                    .font(.caption)
                    .foregroundStyle(accountConnectionFeedbackColor)
                    .lineLimit(3)

                HStack {
                    TextField(viewModel.localized(.emailAddress), text: $accountEmail)
                    SecureField(accountProvider == .gmail ? viewModel.localized(.gmailAppPassword) : viewModel.localized(.appPassword), text: $accountPassword)
                }

                if preset.supportsOAuth2 {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            TextField(viewModel.localized(.oauthClientID), text: oauthClientIDBinding)
                            Button {
                                if let url = viewModel.startOAuthLogin(
                                    provider: accountProvider,
                                    email: accountEmail,
                                    clientID: oauthClientIDBinding.wrappedValue,
                                    useProtocol: accountProtocol
                                ) {
                                    NSWorkspace.shared.open(url)
                                }
                            } label: {
                                Label(viewModel.localized(.browserLogin), systemImage: "key")
                            }
                            .disabled(accountEmail.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || oauthClientIDBinding.wrappedValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        }
                        HStack {
                            SecureField(viewModel.localized(.oauthAccessToken), text: $accountOAuthToken)
                            if let url = preset.oauthHelpURL {
                                Link(destination: url) {
                                    Label(viewModel.localized(.documentation), systemImage: "questionmark.circle")
                                }
                            }
                            Button(viewModel.localized(.saveToken)) {
                                viewModel.addOAuthAccount(
                                    provider: accountProvider,
                                    email: accountEmail,
                                    oauthToken: accountOAuthToken,
                                    useProtocol: accountProtocol
                                )
                                accountEmail = ""
                                accountOAuthToken = ""
                            }
                            .disabled(accountEmail.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || accountOAuthToken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        }
                    }
                }

                HStack {
                    if let url = preset.appPasswordHelpURL {
                        Link(viewModel.localized(.appPasswordHelp), destination: url)
                    }
                    Spacer()
                    Button {
                        let signature = currentAccountConnectionSignature
                        accountConnectionFeedback = viewModel.localized(.testingMailConnection, effectiveAccountProtocol.rawValue.uppercased())
                        Task {
                            isTestingAccountConnection = true
                            let didPass = await viewModel.testAccountConnection(
                                provider: accountProvider,
                                email: accountEmail,
                                password: accountPassword,
                                useProtocol: effectiveAccountProtocol,
                                customIMAP: customIMAPEndpoint,
                                customSMTP: customSMTPEndpoint,
                                customPOP3: customPOP3Endpoint
                            )
                            if didPass, signature == currentAccountConnectionSignature {
                                testedAccountSignature = signature
                                accountConnectionFeedback = viewModel.localized(.connectionTestPassedCanSave)
                            } else if signature == currentAccountConnectionSignature {
                                testedAccountSignature = nil
                                accountConnectionFeedback = viewModel.statusMessage
                            }
                            isTestingAccountConnection = false
                        }
                    } label: {
                        if isTestingAccountConnection {
                            ProgressView()
                                .controlSize(.small)
                        } else {
                            Label(viewModel.localized(.testConnection), systemImage: "antenna.radiowaves.left.and.right")
                        }
                    }
                    .disabled(isTestingAccountConnection)
                    Button(viewModel.localized(.save)) {
                        viewModel.addAccount(
                            provider: accountProvider,
                            email: accountEmail,
                            password: accountPassword,
                            useProtocol: effectiveAccountProtocol,
                            customIMAP: customIMAPEndpoint,
                            customSMTP: customSMTPEndpoint,
                            customPOP3: customPOP3Endpoint
                        )
                        accountEmail = ""
                        accountPassword = ""
                        testedAccountSignature = nil
                        accountConnectionFeedback = viewModel.statusMessage
                    }
                    .disabled(!isCurrentAccountConnectionTested)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .confirmationDialog(viewModel.localized(.deleteAccountQuestion), isPresented: $showsDeleteAccountConfirmation, presenting: accountPendingDeletion) { account in
            Button(viewModel.localized(.deleteAccountButton, account.emailAddress), role: .destructive) {
                viewModel.deleteAccount(accountID: account.id)
                reauthPasswords.removeValue(forKey: account.id)
                if accountPendingDeletion?.id == account.id {
                    accountPendingDeletion = nil
                }
            }
            Button(viewModel.localized(.cancel), role: .cancel) {
                accountPendingDeletion = nil
            }
        } message: { account in
            Text(viewModel.localized(.deleteAccountWarning))
        }
    }


    private var customServerFields: some View {
        Grid(alignment: .leading, horizontalSpacing: 8, verticalSpacing: 8) {
            if accountProtocol == .imap {
                customServerRow("IMAP", host: $customIMAPHost, port: $customIMAPPort, tls: $customIMAPTLS, placeholder: "imap.example.com")
            }
            customServerRow("SMTP", host: $customSMTPHost, port: $customSMTPPort, tls: $customSMTPTLS, placeholder: "smtp.example.com")
            if accountProtocol == .pop3 {
                customServerRow("POP3", host: $customPOP3Host, port: $customPOP3Port, tls: $customPOP3TLS, placeholder: "pop.example.com")
            }
        }
        .padding(10)
        .background(.quaternary, in: RoundedRectangle(cornerRadius: 8))
    }

    private func customServerRow(_ label: String, host: Binding<String>, port: Binding<Int>, tls: Binding<String>, placeholder: String) -> some View {
        GridRow {
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(width: 42, alignment: .leading)
            TextField(placeholder, text: host)
            TextField(viewModel.localized(.port), value: port, format: .number)
                .frame(width: 72)
            Picker(viewModel.localized(.tlsMode), selection: tls) {
                Text("SSL/TLS").tag("SSL")
                Text("STARTTLS").tag("STARTTLS")
                Text(viewModel.localized(.noEncryption)).tag("NONE")
            }
            .labelsHidden()
            .frame(width: 128)
            .help(viewModel.localized(.legacyServerHelp))
        }
    }

    private var customIMAPEndpoint: ServerEndpoint? {
        usesManualServerConfig ? ServerEndpoint(host: customIMAPHost, port: customIMAPPort, tlsMode: customIMAPTLS) : nil
    }

    private var customSMTPEndpoint: ServerEndpoint? {
        usesManualServerConfig ? ServerEndpoint(host: customSMTPHost, port: customSMTPPort, tlsMode: customSMTPTLS) : nil
    }

    private var customPOP3Endpoint: ServerEndpoint? {
        usesManualServerConfig ? ServerEndpoint(host: customPOP3Host, port: customPOP3Port, tlsMode: customPOP3TLS) : nil
    }

    private var usesManualServerConfig: Bool {
        accountProvider == .generic || accountProvider == .custom || accountProvider == .fudan
    }

    private var accountListHeight: CGFloat {
        guard !viewModel.accounts.isEmpty else { return 48 }
        let rowHeight: CGFloat = viewModel.accounts.contains(where: \.needsReauth) ? 108 : 64
        return min(max(CGFloat(viewModel.accounts.count) * rowHeight, rowHeight), 160)
    }

    private var accountServerSummary: String {
        if usesManualServerConfig {
            return viewModel.localized(.commonPortsSummary)
        }
        let preset = ProviderPreset.preset(for: accountProvider)
        return "IMAP \(viewModel.localizedEndpointLabel(preset.imap)) · SMTP \(viewModel.localizedEndpointLabel(preset.smtp))" + (preset.pop3.map { " · POP3 \(viewModel.localizedEndpointLabel($0))" } ?? " · \(viewModel.localized(.pop3Unsupported))")
    }

    private var accountCredentialsComplete: Bool {
        !accountEmail.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
            !accountPassword.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var effectiveAccountProtocol: MailProtocolChoice {
        accountProvider == .gmail ? .imap : accountProtocol
    }

    private var currentAccountConnectionSignature: String {
        [
            accountProvider.rawValue,
            effectiveAccountProtocol.rawValue,
            accountEmail.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
            accountPassword,
            customIMAPEndpoint?.label ?? "",
            customSMTPEndpoint?.label ?? "",
            customPOP3Endpoint?.label ?? ""
        ].joined(separator: "\u{1f}")
    }

    private var isCurrentAccountConnectionTested: Bool {
        accountCredentialsComplete && testedAccountSignature == currentAccountConnectionSignature
    }

    private var accountConnectionFeedbackIcon: String {
        if isTestingAccountConnection { return "antenna.radiowaves.left.and.right" }
        if isCurrentAccountConnectionTested { return "checkmark.circle.fill" }
        return "exclamationmark.circle"
    }

    private var accountConnectionFeedbackText: String {
        if isCurrentAccountConnectionTested { return viewModel.localized(.connectionTestPassedCanSave) }
        if testedAccountSignature != nil { return viewModel.localized(.accountInfoChangedRetest) }
        return accountConnectionFeedback ?? viewModel.localized(.accountConnectionInitialFeedback)
    }

    private var accountConnectionFeedbackColor: Color {
        if isCurrentAccountConnectionTested { return .green }
        if isTestingAccountConnection { return .secondary }
        return .orange
    }

    private var oauthClientIDBinding: Binding<String> {
        Binding {
            switch accountProvider {
            case .gmail:
                viewModel.settings.gmailOAuthClientID
            case .outlook:
                viewModel.settings.outlookOAuthClientID
            case .icloud, .generic, .fudan, .custom:
                ""
            }
        } set: { value in
            switch accountProvider {
            case .gmail:
                viewModel.settings.gmailOAuthClientID = value
            case .outlook:
                viewModel.settings.outlookOAuthClientID = value
            case .icloud, .generic, .fudan, .custom:
                break
            }
        }
    }

    private var aiTab: some View {
        VStack(alignment: .leading, spacing: 14) {
            LabeledContent(viewModel.localized(.apiKeyLabel)) {
                HStack {
                    Text(viewModel.apiKeyMask)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    Button {
                        viewModel.toggleAPIKeyVisibility()
                    } label: {
                        Image(systemName: viewModel.isAPIKeyVisible ? "eye.slash" : "eye")
                    }
                    .buttonStyle(.borderless)
                    .disabled(!viewModel.hasSavedAPIKey)
                    .help(viewModel.isAPIKeyVisible ? viewModel.localized(.hideAPIKey) : viewModel.localized(.showAPIKey))

                    SecureField(viewModel.localized(.newZenMuxAPIKey), text: $newAPIKey)
                    Button(viewModel.localized(.update)) {
                        viewModel.saveAPIKey(newAPIKey)
                        newAPIKey = ""
                    }
                    .disabled(newAPIKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }

            HStack {
                Text(viewModel.localized(.noAPIKeyYet))
                Link(viewModel.localized(.openInviteLink), destination: URL(string: "https://zenmux.ai/invite/GBQMC5")!)
                Spacer()
                Button {
                    Task { await viewModel.testAPIKey() }
                } label: {
                    if viewModel.isTestingAPIKey {
                        ProgressView()
                            .controlSize(.small)
                    } else {
                        Label(viewModel.localized(.testAPIKey), systemImage: "checkmark.shield")
                    }
                }
                .disabled(viewModel.isTestingAPIKey)
            }

            Label(viewModel.apiKeyTestFeedback, systemImage: apiKeyTestFeedbackIcon)
                .font(.caption)
                .foregroundStyle(apiKeyTestFeedbackColor)
                .lineLimit(3)

            Label(viewModel.localized(.aiOptionalInfo), systemImage: "info.circle")
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(2)

            Picker(viewModel.localized(.chatModel), selection: $viewModel.settings.selectedChatModel) {
                ForEach(viewModel.settings.chatModels, id: \.self) { model in
                    Text(model).tag(model)
                }
            }

            HStack {
                TextField(viewModel.localized(.addModelName), text: $newModelName)
                Button {
                    viewModel.addChatModel(newModelName)
                    newModelName = ""
                } label: {
                    Image(systemName: "plus")
                }
                .disabled(newModelName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                .help(viewModel.localized(.addModel))

                Button {
                    viewModel.removeSelectedChatModel()
                } label: {
                    Image(systemName: "minus")
                }
                .disabled(viewModel.settings.chatModels.count <= 1)
                .help(viewModel.localized(.removeSelectedModel))
            }

            Label(viewModel.localized(.useLocalNLEmbeddingOffline), systemImage: "lock.laptopcomputer")
                .font(.caption)
                .foregroundStyle(.secondary)

            Button {
                viewModel.startOrRebuildVectorization()
            } label: {
                if let progress = viewModel.vectorizationProgress, progress.isActive {
                    Label(viewModel.localized(.indexingProgress, progress.processed, progress.total), systemImage: "chart.line.uptrend.xyaxis")
                } else {
                    Label(viewModel.localized(.initializeVectorIndex), systemImage: "square.stack.3d.up")
                }
            }
            .disabled(viewModel.vectorizationProgress?.isActive == true)
            .help(viewModel.localized(.rebuildVectorIndexHelp))

            Text(viewModel.localized(.vectorIndexOptionalInfo))
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(2)

            if let progress = viewModel.vectorizationProgress {
                VStack(alignment: .leading, spacing: 6) {
                    ProgressView(value: progress.fraction)
                        .progressViewStyle(.linear)
                    Text(viewModel.localizedProgress(progress))
                        .font(.caption)
                        .foregroundStyle(progress.failed > 0 ? .orange : .secondary)
                }
            }
        }
    }

    private var apiKeyTestFeedbackIcon: String {
        if viewModel.isTestingAPIKey { return "clock" }
        switch viewModel.apiKeyTestState {
        case .success:
            return "checkmark.circle.fill"
        case .failure, .missing:
            return "exclamationmark.circle"
        case .idle, .testing:
            return "info.circle"
        }
    }

    private var apiKeyTestFeedbackColor: Color {
        if viewModel.isTestingAPIKey { return .secondary }
        switch viewModel.apiKeyTestState {
        case .success:
            return .green
        case .failure, .missing:
            return .orange
        case .idle, .testing:
            return .secondary
        }
    }

    private var generalTab: some View {
        Form {
            Picker(viewModel.localized(.interfaceLanguage), selection: $viewModel.settings.interfaceLanguage) {
                ForEach(AppLanguage.allCases) { language in
                    Text(language.nativeName).tag(language)
                }
            }
            Stepper(viewModel.localized(.pop3PollingInterval, viewModel.settings.pop3PollingMinutes), value: $viewModel.settings.pop3PollingMinutes, in: 1...60)
            Stepper(viewModel.localized(.initialCacheMessageCount, viewModel.settings.cacheMessageLimit), value: $viewModel.settings.cacheMessageLimit, in: 50...2_000, step: 50)
            TextField(viewModel.localized(.signature), text: $viewModel.settings.signature)
            Toggle(viewModel.localized(.enableVectorization), isOn: Binding(
                get: { viewModel.settings.vectorizationEnabled },
                set: { viewModel.setVectorizationEnabled($0) }
            ))
        }
        .confirmationDialog(viewModel.localized(.enableVectorization), isPresented: $viewModel.showsVectorizationPrivacyPrompt, titleVisibility: .visible) {
            Button(viewModel.localized(.useLocalEmbedding)) {
                viewModel.useLocalVectorization()
            }
            Button(viewModel.localized(.cancel), role: .cancel) {
                viewModel.cancelVectorizationEnablement()
            }
        } message: {
            Text(viewModel.localized(.vectorizationPrivacyMessage))
        }
    }
}
