//
//  ComposerView+Editor.swift
//  Demo
//

import AppLocalization
import QuickLayout
import QuickLayoutKit
import UIKit

/// 管理富文本编辑与附件插入删除。
@available(iOS 26.0, *)
extension ComposerView {

    /// 仅去除附件标记及系统生成的分段；用户输入的空格、换行都保留。
    var plainDraftText: String {
        let text = NSMutableAttributedString(attributedString: textView.attributedText ?? NSAttributedString(string: ""))
        var ranges: [NSRange] = []
        text.enumerateAttributes(in: NSRange(location: 0, length: text.length)) { attrs, range, _ in
            if attrs[.attachment] != nil || attrs[TextAttachment.separatorKey] != nil {
                ranges.append(range)
            }
        }
        for range in ranges.reversed() { text.deleteCharacters(in: range) }
        return text.string.replacingOccurrences(of: "\u{FFFC}", with: "")
    }

    /// 指示当前是否可以直接发送音频预览草稿的布尔值。
    ///
    /// 要求处于音频预览、没有媒体组及普通文本，并且未显示录音不可用提示。
    var canSendAudioDraft: Bool {
        guard case .audioPreview = composerState else { return false }
        return mediaDraft == nil && plainDraftText.isEmpty && !isShowingRecordingUnavailableHint
    }

    /// 将整批内容替换到当前选区；附件异步更新不会再改变插入位置。
    func insertContents(_ items: [EditorInsertion]) {
        performPresentationUpdate { [self] in
            guard !isShowingRecordingUnavailableHint else { return }
            let selection = textView.selectedRange
            guard selection.location != NSNotFound, NSMaxRange(selection) <= textView.textStorage.length else { return }
            // 结束组合输入可能同步触发编辑回调；必须在注册新附件之前完成，
            // 否则身份核对会把尚未写入 textStorage 的新卡片当作已删除对象。
            if textView.markedTextRange != nil { textView.unmarkText() }
            let content = NSMutableAttributedString(string: "")
            var preceding = selection.location > 0
                ? (textView.textStorage.string as NSString).substring(with: NSRange(location: selection.location - 1, length: 1)) : ""
            for item in items {
                switch item {
                case .text(let text):
                    content.append(NSAttributedString(string: text, attributes: [
                        .font: textView.font ?? UIFont.preferredFont(forTextStyle: .body),
                        .foregroundColor: UIColor.label,
                    ]))
                    if !text.isEmpty { preceding = String(text.suffix(1)) }
                case .attachment(let draft):
                    guard textAttachments[draft.id] == nil else { updateDocument(draft); continue }
                    if !preceding.isEmpty, preceding != "\n" { content.append(documentSeparator(draft.id)) }
                    content.append(NSAttributedString(attachment: makeTextAttachment(draft)))
                    content.append(documentSeparator(draft.id))
                    preceding = "\n"
                }
            }
            guard content.length > 0 else { return }
            // attributedString 替换和光标更新属于同一事务；UIKit 的中间回调不能
            // 以尚未完成属性写入的文本判断附件已被删除。
            guard let start = textView.position(from: textView.beginningOfDocument, offset: selection.location),
                  let end = textView.position(from: start, offset: selection.length),
                  let range = textView.textRange(from: start, to: end) else { return }
            isInsertingContents = true
            // 先通过 UITextInput 同步替换字符和输入法上下文，再仅写入附件属性。
            // 直接替换 textStorage 的字符会留下旧的键盘上下文，随后将光标附近
            // 的附件改写为旧字符（尤其是 UTF-16 多码元字符后的原生混合粘贴）。
            textView.replace(range, withText: content.string)
            textView.textStorage.beginEditing()
            content.enumerateAttributes(in: NSRange(location: 0, length: content.length)) { attributes, range, _ in
                textView.textStorage.setAttributes(attributes, range: NSRange(location: selection.location + range.location, length: range.length))
            }
            textView.textStorage.endEditing()
            textView.selectedRange = NSRange(location: selection.location + content.length, length: 0)
            isInsertingContents = false
            reconcileTextAttachments()
            resetTypingAttributes()
            updateTextHeight(animated: true)
            refreshTextAttachments()
            refreshRecordingHintLayout()
            draftDidChange?()
        }
    }

    /// 菜单单项导入和录音移交同样遵循当前光标的替换语义。
    func insertDocument(_ draft: DocumentDraft) {
        insertContents([.attachment(draft)])
    }

    /// 在附件边界结束文字段，仅忽略由编辑器生成的排版字符。
    var draftSegments: [DraftSegment] { editorSegments(preservingWhitespace: false) }

    /// 持久化保留纯空白段，发送仍沿用已有空白过滤规则。
    var persistentDraftSegments: [DraftSegment] { editorSegments(preservingWhitespace: true) }

    /// 在内联附件边界拆分正文，提取语义富文本并排除编辑器生成的附件分隔字符。
    ///
    /// - Parameter preservingWhitespace: 为 `true` 时保留纯空白文字段，用于持久化；发送时为 `false`。
    /// - Returns: 按编辑器顺序排列的文字、富文本和附件身份片段。
    private func editorSegments(preservingWhitespace: Bool) -> [DraftSegment] {
        var result: [DraftSegment] = []
        let body = NSMutableAttributedString(string: "")
        /// 按当前空白保留规则追加累计文字段，并清空文字缓冲区。
        func flush() {
            let text = MessageText(attributedString: body)
            if preservingWhitespace ? !text.text.isEmpty : !text.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                result.append(text.hasFormatting ? .richText(text) : .text(text.text))
            }
            body.mutableString.setString("")
        }
        let storage = textView.textStorage
        storage.enumerateAttributes(in: NSRange(location: 0, length: storage.length)) { attributes, range, _ in
            if let attachment = attributes[.attachment] as? TextAttachment {
                flush()
                if textAttachments[attachment.draft.id] === attachment { result.append(.attachment(attachment.draft.id)) }
            } else if attributes[.attachment] != nil {
                flush()
            } else if attributes[TextAttachment.separatorKey] == nil {
                let text = (storage.string as NSString).substring(with: range).replacingOccurrences(of: "\u{FFFC}", with: "")
                body.append(NSAttributedString(string: text, attributes: attributes))
            }
        }
        flush()
        return result
    }

    /// 从语义片段一次性恢复编辑器，不请求焦点、不恢复撤销栈。
    ///
    /// 调用方应在批量恢复期间抑制自动保存，避免状态与高度更新触发中间快照。
    /// - Parameters:
    ///   - segments: 保留原始空白、格式和内联附件位置的有序正文片段。
    ///   - documents: 已登记的就绪附件索引；缺失身份对应的片段被跳过。
    func restoreDraft(segments: [DraftSegment], documents: [UUID: DocumentDraft]) {
        for attachment in textAttachments.values { attachment.open = nil; attachment.remove = nil }
        textAttachments.removeAll()
        let body = NSMutableAttributedString(string: "")
        let font = UIFont.preferredFont(forTextStyle: .body, compatibleWith: traitCollection)
        for segment in segments {
            switch segment {
            case .text(let text): body.append(MessageText(runs: [.init(text)]).attributedString(font: font, color: .label))
            case .richText(let text): body.append(text.attributedString(font: font, color: .label))
            case .attachment(let id):
                guard let draft = documents[id] else { continue }
                if body.length > 0, !body.string.hasSuffix("\n") { body.append(documentSeparator(id)) }
                body.append(NSAttributedString(attachment: makeTextAttachment(draft)))
                body.append(documentSeparator(id))
            }
        }
        // 一次替换正文并重置旧撤销记录，避免恢复过程成为可撤销的用户输入。
        isInsertingContents = true
        textView.textStorage.setAttributedString(body)
        textView.selectedRange = NSRange(location: body.length, length: 0)
        isInsertingContents = false
        textView.undoManager?.removeAllActions()
        resetTypingAttributes(preservingFormatting: false)
        updateComposerState()
        refreshTextAttachments()
        updateTextHeight(animated: false)
    }

    /// 创建带附件身份标记的分隔换行，使发送时可排除编辑器生成的排版字符。
    private func documentSeparator(_ id: UUID) -> NSAttributedString {
        NSAttributedString(string: "\n", attributes: [
            TextAttachment.separatorKey: id.uuidString,
            .font: textView.font ?? UIFont.preferredFont(forTextStyle: .body),
        ])
    }

    /// 创建并登记内联附件，绑定尺寸变化、打开与删除回调。
    private func makeTextAttachment(_ draft: DocumentDraft) -> TextAttachment {
        let attachment = TextAttachment(draft: draft)
        textAttachments[draft.id] = attachment
        attachment.sizeDidChange = { [weak self, weak attachment] in
            guard let self, let attachment, textAttachments[draft.id] === attachment else { return }
            performPresentationUpdate { [self] in
                updateTextHeight()
                textView.setNeedsLayout()
            }
        }
        attachment.open = { [weak self] in
            guard let self, !isShowingRecordingUnavailableHint else { return }
            _ = actionRequested?(.openDocument(draft.id))
        }
        attachment.remove = { [weak self] in
            guard let self, !isShowingRecordingUnavailableHint else { return }
            removeDocument(draft.id, notify: true)
        }
        return attachment
    }

    /// 更新同一身份附件的草稿内容，并刷新卡片与输入栏状态。
    func updateDocument(_ draft: DocumentDraft) {
        guard let attachment = textAttachments[draft.id] else { return }
        attachment.draft = draft
        attachment.refresh()
        updateComposerState()
    }

    /// 按编辑器中的实际排列顺序返回活跃文档附件标识符。
    var orderedDocumentIDs: [UUID] {
        var ids: [UUID] = []
        textView.textStorage.enumerateAttribute(.attachment, in: NSRange(location: 0, length: textView.textStorage.length)) { value, _, _ in
            if let attachment = value as? TextAttachment,
               textAttachments[attachment.draft.id] === attachment { ids.append(attachment.draft.id) }
        }
        return ids
    }

    /// 清理附件属性；正常编辑保留当前文字格式，发送后显式恢复普通正文。
    func resetTypingAttributes(preservingFormatting: Bool = true) {
        guard textView.markedTextRange == nil else { return }
        let style = preservingFormatting ? MessageText.Style(attributes: textView.typingAttributes) : []
        textView.typingAttributes = style.attributes(
            font: .preferredFont(forTextStyle: .body, compatibleWith: traitCollection), color: .label
        )
        inputBinding.refresh()
    }

    /// 将当前布局方向应用到全部内联附件，并刷新其视图和测量。
    func refreshTextAttachments() {
        for attachment in textAttachments.values {
            attachment.direction = textView.effectiveUserInterfaceLayoutDirection
            attachment.refresh()
        }
    }

    /// 逆序修改 textStorage，保持光标位置；不更换编辑器，不重新取得焦点。
    private func removeEditorRanges(_ ranges: [NSRange]) {
        // 普通输入没有附件删除时，不触碰选区，避免打断输入法的组合文本。
        guard !ranges.isEmpty else { return }
        var selection = textView.selectedRange
        textView.textStorage.beginEditing()
        for range in ranges.sorted(by: { $0.location > $1.location }) {
            let start = selection.location - min(range.length, max(0, selection.location - range.location))
            let end = NSMaxRange(selection) - min(range.length, max(0, NSMaxRange(selection) - range.location))
            textView.textStorage.deleteCharacters(in: range)
            selection = NSRange(location: start, length: end - start)
        }
        textView.textStorage.endEditing()
        textView.selectedRange = selection
    }

    /// 移除指定附件的活跃身份及回调，并清理编辑器中的失效引用。
    ///
    /// - Parameters:
    ///   - id: 要移除的附件稳定标识符。
    ///   - notify: 是否向上层发送文档删除动作。
    func removeDocument(_ id: UUID, notify: Bool) {
        performPresentationUpdate { [self] in
            guard let attachment = textAttachments.removeValue(forKey: id) else { return }
            attachment.open = nil
            attachment.remove = nil
            reconcileTextAttachments()
            if notify { _ = actionRequested?(.removeDocument(id)) }
            updateTextHeight()
            refreshRecordingHintLayout()
            draftDidChange?()
        }
    }

    /// 删除、剪切和撤销核对所有活跃身份；失效对象与重复粘贴不能恢复已删除文件。
    private func reconcileTextAttachments() {
        guard !isReconcilingAttachments else { return }
        isReconcilingAttachments = true
        defer { isReconcilingAttachments = false }
        let storage = textView.textStorage
        var found: Set<UUID> = []
        var invalid: [NSRange] = []
        storage.enumerateAttribute(.attachment, in: NSRange(location: 0, length: storage.length)) { value, range, _ in
            guard let value else { return }
            guard let attachment = value as? TextAttachment else { invalid.append(range); return }
            let id = attachment.draft.id
            if textAttachments[id] === attachment, found.insert(id).inserted {} else { invalid.append(range) }
        }
        storage.enumerateAttribute(TextAttachment.separatorKey, in: NSRange(location: 0, length: storage.length)) { value, range, _ in
            if let value = value as? String, let id = UUID(uuidString: value), !found.contains(id) { invalid.append(range) }
        }
        removeEditorRanges(invalid)
        for id in Set(textAttachments.keys).subtracting(found) {
            let attachment = textAttachments.removeValue(forKey: id)
            attachment?.open = nil
            attachment?.remove = nil
            _ = actionRequested?(.removeDocument(id))
        }
    }

    /// 响应文本变化，核对附件身份并更新输入属性、发送状态与输入高度。
    func textViewDidChange(_ textView: UITextView) {
        performPresentationUpdate { [self] in
            guard !isInsertingContents else { return }
            reconcileTextAttachments()
            resetTypingAttributes()
            placeholderLabel.textAlignment = textView.textAlignment
            updateComposerState()
            updateTextHeight(animated: true)
            draftDidChange?()
        }
    }

    /// 将开始编辑事件转发给页面，由页面协调照片面板到键盘的交接。
    func textViewDidBeginEditing(_ textView: UITextView) {
        inputBinding.refresh()
        textInputDidBeginEditing?()
    }

    func textViewDidChangeSelection(_ textView: UITextView) {
        inputBinding.refresh()
    }

    /// 在 UIKit 应用手动文本编辑前停止正在进行的语音转写。
    func textView(
        _ textView: UITextView,
        shouldChangeTextIn range: NSRange,
        replacementText text: String
    ) -> Bool {
        guard !isShowingRecordingUnavailableHint else { return false }
        resetTypingAttributes()
        if case .dictating = composerState, !isApplyingTranscription {
            _ = actionRequested?(.manualEditDuringDictation)
        }
        return true
    }

    /// 指示当前纯文本移除首尾空白后是否可发送的布尔值。
    private var hasSendableText: Bool {
        !plainDraftText
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .isEmpty
    }

    /// 指示当前文字、内联附件或媒体草稿是否满足发送条件的布尔值。
    var hasSendableContent: Bool {
        if textAttachments.values.contains(where: { $0.draft.status != .ready }) { return false }
        if let mediaDraft {
            return mediaDraft.canSend
        }
        return !textAttachments.isEmpty || hasSendableText
    }
}
