import UIKit
import UniformTypeIdentifiers

/// 仅属于一次用户粘贴的提供器描述，不进入消息值模型或持久化存储。
enum PasteSource {
    /// 由系统项目提供者延迟加载、使用指定类型标识符的文件内容。
    case provider(NSItemProvider, typeIdentifier: String)
    /// 需要复制到页面目录的本地文件 URL。
    case fileURL(URL)
    /// 可直接插入链接草稿的网页 URL。
    case link(URL)
    /// 按剪贴板顺序保留的普通文本。
    case text(String)

    /// 从完整文本识别单个网页 URL；包含内部空白或协议不支持时返回 `nil`。
    static func webURL(in text: String) -> URL? {
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty, !value.contains(where: \.isWhitespace),
              let url = URL(string: value), LinkAttachment.accepts(url) else { return nil }
        return url
    }

    /// 返回项目提供者应加载的原始文件类型。
    ///
    /// 优先选择视频、音频或明确文档类型，再尝试图片，避免将封面当成原件。
    static func fileType(in provider: NSItemProvider) -> String? {
        let types = provider.registeredTypeIdentifiers.compactMap(UTType.init)
        // 视频提供器有时同时提供封面；只选择一次真实媒体表示。
        for family in [UTType.movie, .audio] {
            if let type = types.first(where: { $0.conforms(to: family) }) { return type.identifier }
        }
        let namedType = provider.suggestedName.flatMap { UTType(filenameExtension: ($0 as NSString).pathExtension) }
        // PDF 等文件可能同时提供图片预览；明确的原始文档优先于其缩略图。
        if let document = types.first(where: { type in
            guard type.conforms(to: .data), type != .data, !type.conforms(to: .url), !type.conforms(to: .image),
                  type != .html, type != .rtf, type != .rtfd else { return false }
            // NSString 的文本表示不能被当成文件；有文件名的 txt 和 JSON 文件可以。
            if type.conforms(to: .text) {
                return type == .json || type == .xml || namedType?.conforms(to: type) == true
            }
            return true
        }) { return document.identifier }
        if let image = types.first(where: { $0.conforms(to: .image) }) { return image.identifier }
        if provider.canLoadObject(ofClass: UIImage.self) { return UTType.image.identifier }
        return types.contains(.data) && provider.suggestedName?.isEmpty == false ? UTType.data.identifier : nil
    }
}

/// 令 UIKit 先按剪贴板顺序组合结果，再在目标选区一次性插入有序内容；不等待文件导入。
@MainActor
final class PasteCoordinator: NSObject, UITextPasteDelegate {
    /// 标记纯文本粘贴结果所属操作版本的富文本属性键。
    private static let generationKey = NSAttributedString.Key("imessage.paste.generation")
    /// 粘贴开始时保存的选区与全文快照。
    private struct SelectionSnapshot {
        /// 粘贴开始时的 UTF-16 文本选区。
        let selection: NSRange
        /// 粘贴开始时的完整文本，用于判断选区快照是否仍适用。
        let text: String
    }
    /// 在 UIKit 有序粘贴结果中暂存来源与身份；不操作视图，沿用 NSTextAttachment 的非隔离约定。
    nonisolated private final class Token: NSTextAttachment {
        /// 此占位符对应的原始粘贴来源。
        let source: PasteSource
        /// 占位符所属的粘贴版本，用于过滤已失效操作。
        let generation: Int
        /// 粘贴开始时的可选文本与选区快照。
        let snapshot: SelectionSnapshot?
        /// 创建携带来源、操作版本与选区快照的临时粘贴占位符。
        init(_ source: PasteSource, generation: Int, snapshot: SelectionSnapshot?) {
            self.source = source
            self.generation = generation
            self.snapshot = snapshot
            super.init(data: nil, ofType: nil)
        }
        /// 不支持从归档创建 `Token`。
        ///
        /// 此初始化方法始终返回 `nil`。
        required init?(coder: NSCoder) { return nil }
    }

    /// 接收有序粘贴结果的文本编辑器；弱引用避免延长编辑器生命周期。
    private weak var textView: ComposerTextView?
    /// 当前粘贴操作版本；失效时递增，以拒绝迟到的系统结果。
    private var generation = 0
    /// 当前粘贴事务开始前保存的文本选区快照。
    private var selectionSnapshot: SelectionSnapshot?
    /// 尚未向 UIKit 提交转换结果的系统粘贴项目。
    private var pendingItems: [UUID: any UITextPasteItem] = [:]
    /// 尚未完成的系统项目加载进度，失效时统一取消。
    private var pendingLoads: [UUID: Progress] = [:]
    /// 有序粘贴中包含附件时调用的闭包，交由上层一次性插入文字与附件。
    var insertAttachments: (([PasteSource]) -> Void)?
    /// 纯文本粘贴完成后通知输入栏刷新状态的闭包。
    var textDidChange: (() -> Void)?

    /// 为指定文本编辑器配置系统粘贴代理，并捕获原始选区。
    ///
    /// 禁用智能插入删除，避免系统在自定义附件边界增加正文空格。
    init(textView: ComposerTextView) {
        self.textView = textView
        super.init()
        textView.pasteDelegate = self
        textView.pasteConfiguration = UIPasteConfiguration(acceptableTypeIdentifiers: [UTType.item.identifier])
        // 智能插入会在自定义附件周围注入空格，甚至让纯附件粘贴替换正文选区。
        textView.smartInsertDeleteType = .no
        textView.willPaste = { [weak self, weak textView] in
            guard let textView else { return }
            self?.selectionSnapshot = SelectionSnapshot(selection: textView.selectedRange, text: textView.textStorage.string)
        }
    }

    /// 使当前粘贴版本失效，取消加载并将所有待处理项目标记为无结果。
    func invalidate() {
        generation += 1
        selectionSnapshot = nil
        let items = Array(pendingItems.values)
        pendingItems.removeAll()
        for progress in pendingLoads.values { progress.cancel() }
        pendingLoads.removeAll()
        for item in items { item.setNoResult() }
    }

    /// 将单个系统粘贴项目转换为文件占位、网页链接或带操作版本的纯文本。
    func textPasteConfigurationSupporting(_ textPasteConfigurationSupporting: any UITextPasteConfigurationSupporting,
                                          transform item: any UITextPasteItem) {
        guard textView?.isInputSuspended == false else { item.setNoResult(); return }
        let provider = item.itemProvider
        let current = generation
        let snapshot = selectionSnapshot
        if let type = PasteSource.fileType(in: provider) {
            item.setResult(attachment: Token(.provider(provider, typeIdentifier: type), generation: current, snapshot: snapshot))
            return
        }
        let type = provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) ? UTType.fileURL.identifier
            : provider.hasItemConformingToTypeIdentifier(UTType.url.identifier) ? UTType.url.identifier
            : UTType.plainText.identifier
        guard provider.hasItemConformingToTypeIdentifier(type) else { item.setNoResult(); return }
        let id = UUID()
        pendingItems[id] = item
        if type != UTType.fileURL.identifier, provider.canLoadObject(ofClass: NSString.self) {
            pendingLoads[id] = provider.loadObject(ofClass: NSString.self) { [weak self] value, _ in
                let text = value as? String
                Task { @MainActor [weak self] in
                    self?.finishText(id: id, generation: current, string: text, isFileURL: false, snapshot: snapshot)
                }
            }
            return
        }
        provider.loadItem(forTypeIdentifier: type, options: nil) { [weak self] value, _ in
            // 将跨回调的数据转换为值；不把系统提供器的临时 URL 作为文件所有权。
            // 跨进程剪贴板也可能将请求的纯文本物化为临时文件；该 URL 不是正文。
            let representationURL = value as? URL
            let materializedText = type != UTType.fileURL.identifier && representationURL?.isFileURL == true
            let data = (value as? Data) ?? (materializedText ? representationURL.flatMap { try? Data(contentsOf: $0) } : nil)
            let string = (value as? String) ?? data.flatMap { String(data: $0, encoding: .utf8) }
                ?? (materializedText ? nil : representationURL?.absoluteString)
            Task { @MainActor [weak self] in
                self?.finishText(id: id, generation: current, string: string, isFileURL: type == UTType.fileURL.identifier, snapshot: snapshot)
            }
        }
    }

    /// 校验粘贴版本与输入状态后，向 UIKit 提交异步加载的文本或 URL 结果。
    private func finishText(id: UUID, generation current: Int, string: String?, isFileURL: Bool, snapshot: SelectionSnapshot?) {
        pendingLoads[id] = nil
        guard let item = pendingItems.removeValue(forKey: id) else { return }
        guard generation == current, textView?.isInputSuspended == false else { item.setNoResult(); return }
        if isFileURL, let string, let url = URL(string: string), url.isFileURL {
            item.setResult(attachment: Token(.fileURL(url), generation: current, snapshot: snapshot))
        } else if let string, let url = PasteSource.webURL(in: string) {
            item.setResult(attachment: Token(.link(url), generation: current, snapshot: snapshot))
        } else if let string {
            item.setResult(attributedString: NSAttributedString(string: string, attributes: [Self.generationKey: current]))
        } else { item.setNoResult() }
    }

    /// 按 UIKit 提供的顺序连接粘贴结果，不注入额外分隔字符。
    ///
    /// 包含附件时先让原生事务结束，再异步提交混合内容，避免系统收尾改写选区。
    func textPasteConfigurationSupporting(_ textPasteConfigurationSupporting: any UITextPasteConfigurationSupporting,
                                          combineItemAttributedStrings itemStrings: [NSAttributedString],
                                          for textRange: UITextRange) -> NSAttributedString {
        // UIKit 默认拼接可能在附件边界加入智能空格；这些空格不能变成用户正文。
        let result = NSMutableAttributedString(string: "")
        for string in itemStrings { result.append(string) }
        var hasAttachments = false
        result.enumerateAttribute(.attachment, in: NSRange(location: 0, length: result.length)) { value, _, _ in
            if value is Token { hasAttachments = true }
        }
        if hasAttachments {
            let current = generation
            // 让 UIKit 先结束空的原生粘贴事务，再提交附件批次。否则其收尾步骤会
            // 在已插入附件的编辑器中追加智能空格、按旧位置折叠选区。
            DispatchQueue.main.async { [weak self] in
                guard let self, generation == current, let textView, !textView.isInputSuspended else { return }
                _ = self.textPasteConfigurationSupporting(textView, performPasteOf: result, to: textRange)
            }
            return NSAttributedString(string: "")
        }
        return result
    }

    /// 校验操作版本和选区，将有序混合内容交给附件入口或执行纯文本替换。
    ///
    /// - Returns: 操作后的编辑器选区；无法安全应用结果时保留原目标范围。
    func textPasteConfigurationSupporting(_ textPasteConfigurationSupporting: any UITextPasteConfigurationSupporting,
                                          performPasteOf attributedString: NSAttributedString,
                                          to textRange: UITextRange) -> UITextRange {
        guard let textView, !textView.isInputSuspended else { return textRange }
        guard attributedString.length > 0 else {
            return textView.textRange(from: textRange.start, to: textRange.start) ?? textRange
        }
        var targetSelection = NSRange(
            location: textView.offset(from: textView.beginningOfDocument, to: textRange.start),
            length: textView.offset(from: textRange.start, to: textRange.end)
        )
        var expired = false
        attributedString.enumerateAttribute(Self.generationKey, in: NSRange(location: 0, length: attributedString.length)) { value, _, _ in
            if let value = value as? Int, value != generation { expired = true }
        }
        guard !expired else { return textRange }
        var sources: [PasteSource] = []
        var hasAttachments = false
        attributedString.enumerateAttributes(in: NSRange(location: 0, length: attributedString.length)) { attrs, range, _ in
            if let token = attrs[.attachment] as? Token {
                guard token.generation == generation else { expired = true; return }
                hasAttachments = true
                sources.append(token.source)
                if let snapshot = token.snapshot, snapshot.text == textView.textStorage.string {
                    targetSelection = snapshot.selection
                }
            } else if attrs[.attachment] == nil {
                sources.append(.text((attributedString.string as NSString).substring(with: range)))
            }
        }
        guard !expired, targetSelection.location >= 0, NSMaxRange(targetSelection) <= textView.textStorage.length else { return textRange }
        if hasAttachments {
            textView.selectedRange = targetSelection
            insertAttachments?(sources)
        } else {
            guard let start = textView.position(from: textView.beginningOfDocument, offset: targetSelection.location),
                  let end = textView.position(from: start, offset: targetSelection.length),
                  let replacementRange = textView.textRange(from: start, to: end) else { return textRange }
            textView.replace(replacementRange, withText: attributedString.string)
            textDidChange?()
        }
        return textView.selectedTextRange ?? textRange
    }
}
