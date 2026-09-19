import SwiftUI
import ImageIO

struct MessageBubble: View {
    let message: ChatMessage
    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            if message.isUser { Spacer(minLength: 40) }
            VStack(alignment: message.isUser ? .trailing : .leading, spacing: 5) {
                VStack(alignment: .leading, spacing: 8) {
                    if message.toolName != nil {
                        DisclosureGroup {
                            if !message.arguments.isEmpty { code(message.arguments) }
                            if !message.body.isEmpty { code(message.body) }
                        } label: {
                            HStack {
                                if message.isRunning { ProgressView().controlSize(.mini) }
                                Image(systemName: message.isError ? "exclamationmark.triangle" : "terminal")
                                Text(message.toolDisplayName).font(.callout.monospaced()).lineLimit(2)
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
                        if message.isRunning && message.body.isEmpty { ProgressView().controlSize(.small) }
                    }
                    ForEach(message.images) { image in MessageImageView(image: image) }
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
    var table: [[String]]? = nil

    static func cells(_ line: String) -> [String] {
        var text = line.trimmingCharacters(in: .whitespaces)
        if text.hasPrefix("|") { text.removeFirst() }
        if text.hasSuffix("|"), !text.hasSuffix("\\|") { text.removeLast() }
        var cells: [String] = [], cell = "", escaped = false, code = false
        for character in text {
            if escaped { cell.append(character); escaped = false; continue }
            if character == "\\" { escaped = true; cell.append(character); continue }
            if character == "`" { code.toggle() }
            if character == "|", !code { cells.append(cell.trimmingCharacters(in: .whitespaces)); cell = "" }
            else { cell.append(character) }
        }
        cells.append(cell.trimmingCharacters(in: .whitespaces))
        return cells
    }

    static func parse(_ markdown: String) -> [MarkdownBlock] {
        var blocks: [MarkdownBlock] = [], codeLines: [String] = []
        var fence: String?
        let lines = markdown.components(separatedBy: "\n")
        var index = 0
        while index < lines.count {
            let line = lines[index], trimmed = lines[index].trimmingCharacters(in: .whitespaces)
            index += 1
            if let current = fence {
                if trimmed.hasPrefix(current), trimmed.allSatisfy({ $0 == current.first || $0.isWhitespace }) {
                    blocks.append(MarkdownBlock(id: blocks.count, text: codeLines.joined(separator: "\n"), isCode: true))
                    codeLines = []; fence = nil
                } else { codeLines.append(line) }
            } else if trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~") {
                fence = String(trimmed.prefix(while: { $0 == trimmed.first }))
            } else if line.contains("|"), index < lines.count,
                      cells(lines[index]).allSatisfy({ $0.range(of: #"^:?-{3,}:?$"#, options: .regularExpression) != nil }),
                      cells(lines[index]).count == cells(line).count {
                let columns = cells(line).count
                var rows = [cells(line)]
                index += 1 // delimiter row
                while index < lines.count, lines[index].contains("|"), !lines[index].trimmingCharacters(in: .whitespaces).isEmpty {
                    let row = cells(lines[index])
                    rows.append(Array((row + Array(repeating: "", count: columns)).prefix(columns)))
                    index += 1
                }
                blocks.append(MarkdownBlock(id: blocks.count, text: line, isCode: false, table: rows))
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
                } else if let rows = block.table {
                    ScrollView(.horizontal) {
                        Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 8) {
                            ForEach(rows.indices, id: \.self) { row in
                                GridRow {
                                    ForEach(rows[row].indices, id: \.self) { column in
                                        Text(attributed(rows[row][column])).fontWeight(row == 0 ? .semibold : .regular)
                                            .textSelection(.enabled).frame(maxWidth: 300, alignment: .leading)
                                    }
                                }
                                if row == 0 { Divider().gridCellUnsizedAxes(.horizontal) }
                            }
                        }.padding(10)
                    }.background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 6))
                } else {
                    prose(line)
                }
            }
        }.font(.body).fixedSize(horizontal: false, vertical: true)
    }

    @ViewBuilder private func prose(_ line: String) -> some View {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        let indent = min(12, line.prefix(while: { $0.isWhitespace }).reduce(0) { $0 + ($1 == "\t" ? 4 : 1) })
        let heading = trimmed.prefix(while: { $0 == "#" }).count
        if (1...6).contains(heading), trimmed.dropFirst(heading).hasPrefix(" ") {
            Text(attributed(String(trimmed.dropFirst(heading + 1)))).font(heading == 1 ? .title2.bold() : heading == 2 ? .title3.bold() : .headline).textSelection(.enabled)
        } else if ["---", "***", "___"].contains(trimmed) {
            Divider().padding(.vertical, 5)
        } else if trimmed.hasPrefix(">") {
            HStack(spacing: 10) {
                Rectangle().fill(Color.secondary.opacity(0.4)).frame(width: 3)
                Text(attributed(String(trimmed.dropFirst()).trimmingCharacters(in: .whitespaces))).foregroundStyle(.secondary).textSelection(.enabled)
            }.fixedSize(horizontal: false, vertical: true)
        } else if let range = trimmed.range(of: #"^(?:[-+*]|[0-9]+[.)])\s+"#, options: .regularExpression) {
            let marker = trimmed[range].trimmingCharacters(in: .whitespaces)
            let content = String(trimmed[range.upperBound...])
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(marker.count == 1 ? "•" : marker).monospacedDigit()
                if content.hasPrefix("[ ] ") || content.lowercased().hasPrefix("[x] ") {
                    Image(systemName: content.hasPrefix("[ ]") ? "square" : "checkmark.square")
                    Text(attributed(String(content.dropFirst(4)))).textSelection(.enabled)
                } else { Text(attributed(content)).textSelection(.enabled) }
            }.padding(.leading, CGFloat(indent) * 7)
        } else if trimmed.isEmpty { Spacer().frame(height: 2) }
        else { Text(attributed(line)).lineSpacing(3).textSelection(.enabled).padding(.leading, CGFloat(indent) * 7) }
    }
}

private struct MessageImageView: View {
    let image: MessageImage
    @State private var thumbnail: NSImage?
    @State private var failed = false
    var body: some View {
        Group {
            if let thumbnail {
                Image(nsImage: thumbnail).resizable().scaledToFit().frame(maxWidth: 560, maxHeight: 360)
                    .accessibilityLabel("Attached image")
            } else if failed { Label("Unsupported image", systemImage: "photo").font(.caption) }
            else { ProgressView().controlSize(.small) }
        }
        .task(id: image.id) {
            let data = image.data
            let decoded = await Task.detached(priority: .utility) { () -> CGImage? in
                guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
                return CGImageSourceCreateThumbnailAtIndex(source, 0, [
                    kCGImageSourceCreateThumbnailFromImageAlways: true,
                    kCGImageSourceCreateThumbnailWithTransform: true,
                    kCGImageSourceThumbnailMaxPixelSize: 1120
                ] as CFDictionary)
            }.value
            guard !Task.isCancelled else { return }
            if let decoded { thumbnail = NSImage(cgImage: decoded, size: .zero) }
            else { failed = true }
        }
    }
}
