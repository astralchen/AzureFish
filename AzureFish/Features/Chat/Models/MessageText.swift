import Foundation

/// 消息只保存语义格式；字号、颜色随气泡方向与 Dynamic Type 在展示时生成。
///
/// 草稿清单复用此可编码模型，保留四种格式语义，不归档 UIKit 字体或编辑器属性。
nonisolated struct MessageText: Codable, Equatable, Hashable, Sendable {
    /// 可组合的文字格式集合，通过位标记保存，空集合表示普通文字。
    nonisolated struct Style: Codable, OptionSet, Hashable, Sendable {
        /// 各格式标记的位集合，持久化时保留其整数值。
        let rawValue: Int
        /// 加粗格式。
        static let bold = Style(rawValue: 1 << 0)
        /// 斜体格式。
        static let italic = Style(rawValue: 1 << 1)
        /// 下划线格式。
        static let underline = Style(rawValue: 1 << 2)
        /// 删除线格式。
        static let strikethrough = Style(rawValue: 1 << 3)
    }

    /// 使用同一组语义格式的连续文字，保留原始空白和换行。
    nonisolated struct Run: Codable, Equatable, Hashable, Sendable {
        /// 片段的原始文字，不进行首尾空白裁剪。
        var text: String
        /// 应用于片段全部文字的格式组合。
        let style: Style

        /// 创建指定文字和格式的片段。
        ///
        /// - Parameters:
        ///   - text: 原始文字，可包含空白、换行及任意 Unicode 字符。
        ///   - style: 语义格式组合，默认空集合表示普通文字。
        init(_ text: String, style: Style = []) {
            self.text = text
            self.style = style
        }
    }

    /// 按正文顺序排列的文字片段。
    let runs: [Run]

    /// 合并相邻同格式片段，使刷新身份不受 TextKit 的临时属性分段影响。
    ///
    /// - Parameter runs: 原始有序片段；忽略空字符串片段，但保留只含空白或换行的片段。
    init(runs: [Run]) {
        var normalized: [Run] = []
        for run in runs where !run.text.isEmpty {
            if normalized.last?.style == run.style {
                normalized[normalized.count - 1].text += run.text
            } else {
                normalized.append(run)
            }
        }
        self.runs = normalized
    }

    /// 将所有片段按顺序拼接得到的原始纯文本。
    var text: String { runs.map(\.text).joined() }
    /// 是否至少有一个片段携带非空的语义格式组合。
    var hasFormatting: Bool { runs.contains { !$0.style.isEmpty } }
}
