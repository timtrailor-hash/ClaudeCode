import SwiftUI

struct MarkdownText: View {
    let content: String

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(Array(parseBlocks().enumerated()), id: \.offset) { _, block in
                switch block {
                case .text(let text):
                    renderInlineMarkdown(text)
                case .code(let language, let code):
                    codeBlock(language: language, code: code)
                }
            }
        }
    }

    enum Block {
        case text(String)
        case code(String, String) // language, code
    }

    private func parseBlocks() -> [Block] {
        var blocks: [Block] = []
        let lines = content.components(separatedBy: "\n")
        var inCode = false
        var codeLang = ""
        var codeLines: [String] = []
        var textLines: [String] = []

        for line in lines {
            if line.hasPrefix("```") {
                if inCode {
                    // End code block
                    blocks.append(.code(codeLang, codeLines.joined(separator: "\n")))
                    codeLines = []
                    inCode = false
                } else {
                    // Start code block -- flush text
                    if !textLines.isEmpty {
                        blocks.append(.text(textLines.joined(separator: "\n")))
                        textLines = []
                    }
                    codeLang = String(line.dropFirst(3)).trimmingCharacters(in: .whitespaces)
                    inCode = true
                }
            } else if inCode {
                codeLines.append(line)
            } else {
                textLines.append(line)
            }
        }

        // Flush remaining
        if inCode {
            blocks.append(.code(codeLang, codeLines.joined(separator: "\n")))
        }
        if !textLines.isEmpty {
            blocks.append(.text(textLines.joined(separator: "\n")))
        }

        return blocks
    }

    @ViewBuilder
    private func renderInlineMarkdown(_ text: String) -> some View {
        if let attributed = try? AttributedString(
            markdown: text,
            options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        ) {
            Text(attributed)
                .font(.system(size: 14))
                .foregroundColor(Color(hex: "#E0E0E0"))
                .tint(Color(hex: "#C9A96E"))
        } else {
            Text(text)
                .font(.system(size: 14))
                .foregroundColor(Color(hex: "#E0E0E0"))
        }
    }

    private func codeBlock(language: String, code: String) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            if !language.isEmpty {
                HStack {
                    Text(language)
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundColor(Color(hex: "#888888"))
                    Spacer()
                    Button(action: {
                        UIPasteboard.general.string = code
                    }) {
                        Image(systemName: "doc.on.doc")
                            .font(.system(size: 11))
                            .foregroundColor(Color(hex: "#888888"))
                    }
                }
                .padding(.horizontal, 10)
                .padding(.top, 6)
                .padding(.bottom, 2)
            }

            ScrollView(.horizontal, showsIndicators: false) {
                Text(code)
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundColor(Color(hex: "#E0E0E0"))
                    .padding(.horizontal, 10)
                    .padding(.vertical, 8)
            }
        }
        .background(Color(hex: "#1A1A2E"))
        .cornerRadius(8)
    }
}
