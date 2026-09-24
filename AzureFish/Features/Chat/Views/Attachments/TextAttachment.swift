//
//  TextAttachment.swift
//  Demo
//

import QuickLayout
import QuickLayoutKit
import UIKit
import UniformTypeIdentifiers

/// 编辑器保存值模型和稳定身份；文件由文档控制器管理，与录音状态无关。
@available(iOS 17.0, *)
@MainActor
final class TextAttachment: NSTextAttachment {
    /// 标记编辑器自动生成附件分隔符的富文本属性键。
    static let separatorKey = NSAttributedString.Key("imessage.attachment.generatedSeparator")
    /// 当前附件卡片对应的文档草稿值；更新后调用 `refresh()` 刷新已注册视图。
    var draft: DocumentDraft
    /// 内联卡片采用的界面布局方向，默认从左向右。
    var direction: UIUserInterfaceLayoutDirection = .leftToRight
    /// 用户打开内联附件时调用的闭包；变化时同步到已注册卡片。
    var open: (() -> Void)? { didSet { cards.allObjects.forEach(configureActions) } }
    /// 用户删除内联附件时调用的闭包；为 `nil` 时移除卡片上的删除动作。
    var remove: (() -> Void)? { didSet { cards.allObjects.forEach(configureActions) } }
    /// 附件首选尺寸变化后通知编辑器重新测量的闭包。
    var sizeDidChange: (() -> Void)?
    /// 当前注册卡片的弱引用集合，供内容与动作更新使用。
    private let cards = NSHashTable<AttachmentCard>.weakObjects()
    /// TextKit 重排时会更换 provider；同一布局管理器继续使用已加载的卡片。
    /// 弱键避免延长编辑器生命周期，不同编辑器也不会争用同一个 UIView。
    private let editorCards = NSMapTable<NSTextLayoutManager, AttachmentCard>.weakToStrongObjects()

    /// 创建绑定指定文档草稿、使用 TextKit 视图提供者渲染的文本附件。
    init(draft: DocumentDraft) {
        self.draft = draft
        super.init(data: nil, ofType: "com.quicklayout.demo.file-draft")
        allowsTextAttachmentView = true
    }
    /// 不支持从归档创建 `TextAttachment`。
    ///
    /// 此初始化方法始终返回 `nil`。
    nonisolated required init?(coder: NSCoder) { return nil }
    /// 必须使用文档草稿创建附件，禁止继承基类的原始数据初始化入口。
    @available(*, unavailable, message: "使用 init(draft:) 创建文档附件")
    nonisolated override init(data contentData: Data?, ofType uti: String?) {
        fatalError("使用 init(draft:) 创建文档附件")
    }
    /// 指示此附件始终使用视图提供者；常量查询沿用基类的非隔离接口。
    nonisolated override var usesTextAttachmentView: Bool { true }

    /// 根据动态字体行高返回文件卡片所需高度，最小值为 84 点。
    static func height(for traits: UITraitCollection) -> CGFloat {
        let title = AttachmentCardStyle.titleFont(for: traits)
        let detail = AttachmentCardStyle.detailFont(for: traits)
        return max(84, ceil(title.lineHeight * 2 + detail.lineHeight
            + AttachmentCardStyle.textSpacing) + 24)
    }

    /// 按 TextKit 的非隔离接口创建提供者；实际视图创建和测量在提供者的主 Actor 边界执行。
    nonisolated override func viewProvider(for parentView: UIView?, location: any NSTextLocation, textContainer: NSTextContainer?) -> NSTextAttachmentViewProvider? {
        let provider = AttachmentProvider(
            textAttachment: self, parentView: parentView,
            textLayoutManager: textContainer?.textLayoutManager, location: location
        )
        provider.tracksTextAttachmentViewBounds = true
        return provider
    }

    /// 返回仍处于可见编辑器中的附件卡片。
    var previewSourceView: UIView? { cards.allObjects.first { $0.window != nil && !$0.isHidden } }

    /// 以弱引用登记卡片，并立即应用草稿、布局方向和交互回调。
    func register(_ card: AttachmentCard) {
        cards.add(card)
        configure(card)
    }

    /// 返回指定文本布局管理器专用的卡片，首次访问时创建并缓存。
    ///
    /// 同一编辑器的 TextKit 重排复用原卡片；不同编辑器各自持有视图。
    fileprivate func card(for layoutManager: NSTextLayoutManager?) -> AttachmentCard {
        if let layoutManager, let card = editorCards.object(forKey: layoutManager) {
            return card
        }
        let card = AttachmentCard(frame: .zero)
        register(card)
        card.preferredSizeDidChange = { [weak self, weak layoutManager] in
            if let layoutManager, let content = layoutManager.textContentManager {
                layoutManager.invalidateLayout(for: content.documentRange)
            }
            self?.sizeDidChange?()
        }
        if let layoutManager { editorCards.setObject(card, forKey: layoutManager) }
        return card
    }
    /// 使用对应编辑器的实际卡片测量指定最大宽度下的附件尺寸。
    func preferredSize(maximumWidth: CGFloat, layoutManager: NSTextLayoutManager?) -> CGSize {
        card(for: layoutManager).preferredSize(maximumWidth: maximumWidth)
    }
    /// 刷新所有注册卡片，并使各文本布局管理器的文档布局失效。
    func refresh() {
        cards.allObjects.forEach(configure)
        for case let manager as NSTextLayoutManager in editorCards.keyEnumerator() {
            if let content = manager.textContentManager {
                manager.invalidateLayout(for: content.documentRange)
            }
        }
        sizeDidChange?()
    }
    /// 将附件的布局方向、草稿内容和动作同步到指定卡片。
    private func configure(_ card: AttachmentCard) {
        card.semanticContentAttribute = direction == .rightToLeft ? .forceRightToLeft : .forceLeftToRight
        card.configure(draft)
        configureActions(card)
    }

    /// nil 必须传递到已注册视图；编辑器移除附件后不能留下空闭包和可用动作。
    private func configureActions(_ card: AttachmentCard) {
        if open != nil {
            card.open = { [weak self] in self?.open?() }
        } else {
            card.open = nil
        }
        if remove != nil {
            card.remove = { [weak self] in self?.remove?() }
        } else {
            card.remove = nil
        }
    }
}

/// 将编辑器专用卡片装入独立宿主视图的 TextKit 附件提供者。
@available(iOS 17.0, *)
@MainActor
private final class AttachmentProvider: NSTextAttachmentViewProvider {
    /// 获取当前编辑器的缓存卡片，并装入此提供者独占的宿主视图。
    ///
    /// 旧提供者释放宿主时不会移除已经转交给新宿主的卡片。
    nonisolated override func loadView() {
        // SDK 将提供者标为不可 Sendable；此引用仅在同步 Actor 检查内使用，不传给异步任务。
        nonisolated(unsafe) let provider = self
        MainActor.assumeIsolated {
            guard let attachment = provider.textAttachment as? TextAttachment else { return }
            // UITextView 主 Actor 布局中的同步回调，避免异步跳转打乱 TextKit 布局顺序。
            let card = attachment.card(for: provider.textLayoutManager)
            let host = UIView(frame: card.bounds)
            card.frame = host.bounds
            card.autoresizingMask = [.flexibleWidth, .flexibleHeight]
            host.addSubview(card)
            provider.view = host
        }
    }
    /// UITextView 在主 Actor 同步测量卡片；非隔离覆盖入口检查调用方的 Actor 约束。
    nonisolated override func attachmentBounds(for attributes: [NSAttributedString.Key: Any], location: any NSTextLocation, textContainer: NSTextContainer?, proposedLineFragment: CGRect, position: CGPoint) -> CGRect {
        // 保留同步 TextKit 布局契约，动态确认主 Actor 后才读取提供者和测量 UIKit 视图。
        nonisolated(unsafe) let provider = self
        return MainActor.assumeIsolated {
            guard let attachment = provider.textAttachment as? TextAttachment else { return .zero }
            return CGRect(origin: .zero, size: attachment.preferredSize(
                maximumWidth: max(1, proposedLineFragment.width), layoutManager: provider.textLayoutManager
            ))
        }
    }
}

#if DEBUG
import QuickLayout
import QuickLayoutKit
import UIKit

/// 创建文档输入栏预览，支持布局方向、大字体、媒体粘贴及文字附件交错场景。
@available(iOS 26.0, *)
@MainActor
private func documentCardPreview(
    text: String, direction: UIUserInterfaceLayoutDirection, photos: Bool, largeText: Bool = false,
    pastedMedia: Bool = false, interleaved: Bool = false
) -> UIViewController {
    let composer = ComposerView(frame: .zero)
    composer.configure(strings: ConversationPreviewData.composerStrings)
    composer.applyLayoutDirection(direction)
    if largeText { composer.traitOverrides.preferredContentSizeCategory = .accessibilityExtraExtraExtraLarge }
    composer.textView.text = text
    composer.textViewDidChange(composer.textView)
    composer.textView.selectedRange = NSRange(location: interleaved ? (text as NSString).length : 0, length: 0)
    for draft in ConversationPreviewData.documentDrafts {
        composer.insertDocument(draft)
        if interleaved { composer.insertContents([.text(text)]) }
    }
    if pastedMedia { composer.insertContents(ConversationPreviewData.pastedMediaDrafts.map { .attachment($0) }) }
    if photos {
        composer.applyMediaDraft(.init(groupID: UUID(), items: [
            .init(id: UUID(), assetIdentifier: nil, content: .importing),
        ]))
    }
    let background = UIView()
    background.backgroundColor = .systemBackground
    return QuickLayoutHostingController {
        ZStack(alignment: .bottom) {
            background.resizable()
            composer.resizable(axis: .horizontal).fixedSize(axis: .vertical)
        }.frame(width: 390, height: largeText ? 1000 : 680)
    }
}

@available(iOS 26.0, *)
#Preview("多类型附件 · 光标处插入") {
    documentCardPreview(text: "在", direction: .leftToRight, photos: true)
}

@available(iOS 26.0, *)
#Preview("多类型附件 · 删除全部照片后") {
    documentCardPreview(text: "", direction: .leftToRight, photos: false)
}

@available(iOS 26.0, *)
#Preview("多类型附件 · RTL 大字体") {
    documentCardPreview(text: "مرحبا", direction: .rightToLeft, photos: true, largeText: true)
}

@available(iOS 26.0, *)
#Preview("粘贴图片视频 · 右上角删除") {
    documentCardPreview(text: "图片和视频分别发送", direction: .leftToRight, photos: false, pastedMedia: true)
}

@available(iOS 26.0, *)
#Preview("粘贴图片视频 · RTL 大字体") {
    documentCardPreview(text: "صور وفيديو", direction: .rightToLeft, photos: false, largeText: true, pastedMedia: true)
}
@available(iOS 26.0, *)
#Preview("按位置分段 · 文字与多个附件") {
    documentCardPreview(text: " 一段正文\n", direction: .leftToRight, photos: false, interleaved: true)
}

@available(iOS 26.0, *)
#Preview("按位置分段 · RTL 大字体") {
    documentCardPreview(text: " نص الرسالة\n", direction: .rightToLeft, photos: false, largeText: true, interleaved: true)
}
#endif
