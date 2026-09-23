import SwiftUI

/// Renders the bundled HELP.md.
///
/// Foundation's Markdown parser does the parsing: with `.full` syntax it tags
/// every run with a `PresentationIntent` describing the block it belongs to, so
/// this only has to group runs into blocks and pick a style per block. Text
/// keeps the inline attributes the parser produced, which covers code spans.
struct HelpView: View {
    private let blocks: [Block]

    init() {
        blocks = HelpView.loadBlocks()
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(blocks) { block in
                    view(for: block)
                }
            }
            .padding(.horizontal, 32)
            .padding(.vertical, 28)
            .frame(maxWidth: 760, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .center)
            .textSelection(.enabled)
        }
    }

    @ViewBuilder
    private func view(for block: Block) -> some View {
        switch block.kind {
        case .header(let level):
            Text(block.text)
                .font(.system(size: [26.0, 20.0, 17.0][min(level, 3) - 1], weight: .semibold))
                // A heading belongs to the text beneath it, so the gap above is
                // the larger one. The first block must not push the top padding.
                .padding(.top, block.isFirst ? 0 : (level == 1 ? 0 : 28))
                .padding(.bottom, level == 1 ? 12 : 8)
        case .paragraph:
            Text(block.text)
                .lineSpacing(4)
                .padding(.bottom, 12)
        case .listItem(let marker):
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(marker)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                Text(block.text)
                    .lineSpacing(4)
            }
            .padding(.leading, 4)
            .padding(.bottom, 8)
        }
    }

    // MARK: - Parsing

    fileprivate struct Block: Identifiable {
        enum Kind {
            case header(level: Int)
            case paragraph
            case listItem(marker: String)
        }
        let id: Int
        let kind: Kind
        let text: AttributedString
        let isFirst: Bool
    }

    private static func loadBlocks() -> [Block] {
        guard let url = Bundle.module.url(forResource: "HELP", withExtension: "md"),
              let markdown = try? String(contentsOf: url, encoding: .utf8) else { return [] }
        let options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .full)
        guard let parsed = try? AttributedString(markdown: markdown, options: options) else { return [] }

        // Runs split on inline attributes too, so consecutive runs sharing a
        // block identity have to be stitched back into one block.
        var blocks: [Block] = []
        var current: (identity: Int, intent: PresentationIntent, text: AttributedString)?
        func flush() {
            guard let open = current, let kind = kind(for: open.intent) else { current = nil; return }
            var text = trimmingTrailingWhitespace(open.text)
            // Headings carry their own font, so only body text gets code voice.
            if case .header = kind {} else { text = stylingCodeSpans(text) }
            if !text.characters.isEmpty {
                blocks.append(Block(id: blocks.count, kind: kind, text: text, isFirst: blocks.isEmpty))
            }
            current = nil
        }
        for run in parsed.runs {
            // The innermost component identifies the block: runs belonging to
            // one paragraph all report the same paragraph identity.
            guard let intent = run.presentationIntent,
                  let identity = intent.components.first?.identity else { continue }
            var slice = AttributedString(parsed[run.range])
            // The block styling replaces the parser's own, which SwiftUI would
            // otherwise apply on top as its default heading and list treatment.
            slice.presentationIntent = nil
            if current?.identity == identity {
                current?.text.append(slice)
            } else {
                flush()
                current = (identity, intent, slice)
            }
        }
        flush()
        return blocks
    }

    private static func kind(for intent: PresentationIntent) -> Block.Kind? {
        // Components run innermost first: a list item's paragraph comes before
        // the listItem, which comes before the list itself.
        var ordinal: Int?
        for component in intent.components {
            switch component.kind {
            case .header(let level):
                return .header(level: level)
            case .listItem(let value):
                ordinal = value
            case .orderedList:
                return .listItem(marker: "\(ordinal ?? 1).")
            case .unorderedList:
                return .listItem(marker: "•")
            case .paragraph:
                continue
            default:
                continue
            }
        }
        return intent.components.contains { $0.kind == .paragraph } ? .paragraph : nil
    }

    private static func trimmingTrailingWhitespace(_ text: AttributedString) -> AttributedString {
        var result = text
        while let last = result.characters.last, last.isNewline || last == " " {
            let end = result.endIndex
            result.removeSubrange(result.characters.index(before: end)..<end)
        }
        return result
    }

    /// Gives backtick spans a monospaced face and a tinted background, which is
    /// clearer than the code voice a plain `Text` applies on its own.
    private static func stylingCodeSpans(_ text: AttributedString) -> AttributedString {
        // Collect the ranges before mutating: runs is a view over the storage
        // being changed, so its indices would not survive the edits.
        let ranges = text.runs
            .filter { $0.inlinePresentationIntent?.contains(.code) == true }
            .map(\.range)
        var result = text
        for range in ranges {
            result[range].font = .system(.body, design: .monospaced)
            result[range].backgroundColor = Color.secondary.opacity(0.14)
        }
        return result
    }
}
