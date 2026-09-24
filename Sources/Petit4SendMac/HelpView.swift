import SwiftUI

/// 同梱の HELP.md を表示する。
///
/// 解析は Foundation の Markdown パーサに任せる。`.full` では各 run に、
/// 所属ブロックを表す `PresentationIntent` が付く。こちらは run をブロックへまとめ、
/// ブロックごとの見た目を選ぶだけ。本文はパーサが付けたインライン属性を残すので、
/// コードスパンもそこで区別できる。
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
                // 見出しは直後の本文と組なので、空きは上を大きくする。
                // 先頭ブロックはウィンドウ上端の余白をさらに押し下げない。
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

    // MARK: - 解析

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

        // インライン属性の境でも run は割れる。同じブロック identity の連続 run は 1 つに戻す。
        var blocks: [Block] = []
        var current: (identity: Int, intent: PresentationIntent, text: AttributedString)?
        func flush() {
            guard let open = current, let kind = kind(for: open.intent) else { current = nil; return }
            var text = trimmingTrailingWhitespace(open.text)
            // 見出しは専用のフォントを付けるので、コード用の等幅は本文だけに掛ける。
            if case .header = kind {} else { text = stylingCodeSpans(text) }
            if !text.characters.isEmpty {
                blocks.append(Block(id: blocks.count, kind: kind, text: text, isFirst: blocks.isEmpty))
            }
            current = nil
        }
        for run in parsed.runs {
            // インライン属性でも run は分割される。同じブロックに属する連続 run は
            // いちばん内側の成分の identity が一致するので、それで 1 ブロックに縫い合わせる。
            guard let intent = run.presentationIntent,
                  let identity = intent.components.first?.identity else { continue }
            var slice = AttributedString(parsed[run.range])
            // ブロックの見た目は自前で付ける。intent を残すと SwiftUI が既定の
            // 見出し・リスト装飾をさらに重ねる。
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

    /// ブロック種別を決める。成分は内側から並ぶ。リスト項目の段落、listItem、リスト本体の順。
    private static func kind(for intent: PresentationIntent) -> Block.Kind? {
        // 番号付きリストの番号は listItem 側にあり、orderedList に到達した時点でマーカーにする。
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

    /// バッククォート範囲を等幅にし、薄い背景を付ける。
    /// 素の `Text` が付けるコード書体より、地の文との境目がはっきりする。
    private static func stylingCodeSpans(_ text: AttributedString) -> AttributedString {
        // 範囲は変更前に集める。runs は書き換え中の格納域を見ているので、
        // 編集のあとでは添字が無効になる。
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
