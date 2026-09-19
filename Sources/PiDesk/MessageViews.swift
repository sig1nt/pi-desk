import SwiftUI

struct MessageBubble: View {
    let message: ChatMessage
    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            if message.isUser { Spacer(minLength: 40) }
            VStack(alignment: message.isUser ? .trailing : .leading, spacing: 5) {
                VStack(alignment: .leading, spacing: 8) {
                    if let tool = message.toolName {
                        DisclosureGroup {
                            if !message.arguments.isEmpty { code(message.arguments) }
                            if !message.body.isEmpty { code(message.body) }
                        } label: {
                            HStack {
                                if message.isRunning { ProgressView().controlSize(.mini) }
                                Image(systemName: message.isError ? "exclamationmark.triangle" : "terminal")
                                Text(tool).font(.callout.monospaced())
                                Text(message.isRunning ? "Running…" : message.isError ? "Failed" : "Done").font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    } else {
                        if !message.thinking.isEmpty {
                            DisclosureGroup("Thinking") { MarkdownMessageView(markdown: message.thinking).foregroundStyle(.secondary) }.font(.caption)
                        }
                        if !message.body.isEmpty {
                            if message.isUser { Text(message.body).font(.body).lineSpacing(3).textSelection(.enabled) }
                            else { MarkdownMessageView(markdown: message.body) }
                        }
                        if !message.arguments.isEmpty {
                            DisclosureGroup("Tool calls") { code(message.arguments) }.font(.caption)
                        }
                        if message.isRunning && message.body.isEmpty { ProgressView().controlSize(.small) }
                    }
                }
                .padding(.horizontal, 15).padding(.vertical, 12)
                .background(message.isUser ? Color.accentColor : Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 14))
                .foregroundStyle(message.isUser ? Color.white : message.isError ? Color.red : Color.primary)
                Text(message.time).font(.caption2).foregroundStyle(.tertiary)
            }
            .contextMenu { Button("Copy") { copy(message.body) } }
        }.frame(maxWidth: .infinity, alignment: message.isUser ? .trailing : .leading)
    }

    private func code(_ text: String) -> some View {
        ScrollView([.horizontal, .vertical]) {
            Text(text).font(.system(.caption, design: .monospaced)).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
        }.frame(maxHeight: 300)
    }
}

struct MarkdownBlock: Identifiable {
    let id: Int
    let text: String
    let isCode: Bool
    static func parse(_ markdown: String) -> [MarkdownBlock] {
        var blocks: [MarkdownBlock] = [], codeLines: [String] = []
        var fence: String?
        for line in markdown.components(separatedBy: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if let current = fence {
                if trimmed.hasPrefix(current) {
                    blocks.append(MarkdownBlock(id: blocks.count, text: codeLines.joined(separator: "\n"), isCode: true))
                    codeLines = []; fence = nil
                } else { codeLines.append(line) }
            } else if trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~") {
                fence = String(trimmed.prefix(while: { $0 == trimmed.first }))
            } else { blocks.append(MarkdownBlock(id: blocks.count, text: line, isCode: false)) }
        }
        if fence != nil { blocks.append(MarkdownBlock(id: blocks.count, text: codeLines.joined(separator: "\n"), isCode: true)) }
        return blocks
    }
}

struct MarkdownMessageView: View {
    let markdown: String
    private func attributed(_ text: String) -> AttributedString {
        (try? AttributedString(markdown: text, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(text)
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            ForEach(MarkdownBlock.parse(markdown)) { block in
                let line = block.text
                if block.isCode {
                    ScrollView(.horizontal) {
                        Text(line).font(.system(.body, design: .monospaced)).textSelection(.enabled).padding(10)
                    }.background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 6))
                } else if line.hasPrefix("### ") {
                    Text(attributed(String(line.dropFirst(4)))).font(.headline).padding(.bottom, 2)
                } else if line.hasPrefix("## ") {
                    Text(attributed(String(line.dropFirst(3)))).font(.title3.bold()).padding(.bottom, 2)
                } else if line.hasPrefix("# ") {
                    Text(attributed(String(line.dropFirst(2)))).font(.title2.bold()).padding(.bottom, 2)
                } else if line.hasPrefix("- ") || line.hasPrefix("* ") {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text("•")
                        Text(attributed(String(line.dropFirst(2)))).textSelection(.enabled)
                    }
                } else if line.isEmpty { Spacer().frame(height: 2) }
                else { Text(attributed(line)).lineSpacing(3).textSelection(.enabled) }
            }
        }.font(.body).fixedSize(horizontal: false, vertical: true)
    }
}
