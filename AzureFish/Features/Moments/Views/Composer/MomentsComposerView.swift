import AVFoundation
import AzureFishStorage
import AzureFishAPI
import AzureFishMoments
import ImageIO
import PhotosUI
import QuickLayout
import QuickLayoutKit
import UIKit
import UniformTypeIdentifiers

/// 发布内容组件保留输入控件和焦点，业务变化通过动作回调上报。
final class MomentsComposerView: QuickLayoutView, UITextViewDelegate {
    let text = UITextView()
    let scroll = QuickLayoutScrollView()
    let status = UILabel()
    let add = UIButton(type: .system)
    let videoProgress = UIProgressView(progressViewStyle: .default)
    private var images: [UIButton] = []
    private var imageTasks: [Task<Void, Never>] = []
    private let media: MomentsMediaProvider
    private var state: MomentsComposerState
    var action: ((MomentsComposerAction) -> Void)?
    private var draft: MomentsDraft { state.draft }
    private var busy: Bool { state.busy }
    private var isCover: Bool { state.isCover }

    init(media: MomentsMediaProvider, state: MomentsComposerState) {
        self.media = media
        self.state = state
        super.init(frame: .zero)
        scroll.keyboardDismissMode = .interactive
        text.font = .preferredFont(forTextStyle: .body)
        text.adjustsFontForContentSizeCategory = true
        text.delegate = self
        text.backgroundColor = .secondarySystemBackground
        text.layer.cornerRadius = 12
        text.text = state.draft.text
        text.accessibilityIdentifier = "moments.editor.text"
        status.font = .preferredFont(forTextStyle: .footnote)
        status.adjustsFontForContentSizeCategory = true
        status.numberOfLines = 0
        status.textColor = .secondaryLabel
        status.accessibilityIdentifier = "moments.editor.status"
        add.addAction(UIAction { [weak self] _ in self?.action?(.chooseMedia) }, for: .touchUpInside)
        add.accessibilityIdentifier = "moments.editor.add"
        renderImages()
        apply(state)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override var body: Layout {
        ScrollView(scroll) {
            VStack(alignment: .leading, spacing: 16) {
                if !isCover { text.resizable().frame(height: 180).frame(maxWidth: .infinity) }
                ForEach(images) { $0.resizable().frame(height: 150).frame(maxWidth: .infinity) }
                add.frame(minHeight: 48)
                if busy { videoProgress.resizable(axis: .horizontal).frame(maxWidth: .infinity) }
                status.resizable(axis: .horizontal).frame(maxWidth: .infinity)
            }.frame(width: min(640, max(0, bounds.width - 40))).padding(.vertical, 20)
        }.frame(maxWidth: .infinity, maxHeight: .infinity).safeAreaPadding(.all, 0)
    }

    /// 更新输入和控件状态；媒体版本或语言改变时重建媒体菜单，请求后续布局。
    func apply(_ state: MomentsComposerState, localizationChanged: Bool = false) {
        let mediaChanged = self.state.mediaRevision != state.mediaRevision
        self.state = state
        // 不用同值覆盖正在组合的输入，语言与外观切换保留选区和焦点。
        if text.text != state.draft.text { text.text = state.draft.text }
        text.isEditable = state.canEdit
        text.accessibilityLabel = Localization.text("moments.write")
        add.setTitle(Localization.text(isCover || !draft.images.isEmpty ? "moments.addPhotos" : "moments.addMedia"), for: .normal)
        add.isEnabled = state.canAdd
        videoProgress.progress = state.progress
        status.text = state.errorKey.map { Localization.text($0) } ?? (state.frozen ? Localization.text("moments.pendingPublication") : (isCover ? Localization.text("moments.changeCover") : (draft.video != nil ? Localization.text(busy ? "moments.videoProcessing" : "moments.videoHelp") : Localization.text("moments.editorHelp", Int64(draft.text.count), Int64(draft.images.count)))))
        if mediaChanged || localizationChanged { renderImages() }
        images.forEach { $0.isEnabled = state.canEdit }
        setNeedsQuickLayout()
    }
    func textViewDidChange(_ textView: UITextView) { action?(.textChanged(textView.text)) }
    /// 取消旧缩略图任务并按当前草稿顺序创建媒体按钮，加载结束前保留占位区域。
    func renderImages() {
        imageTasks.forEach { $0.cancel() }; imageTasks = []
        images = draft.images.enumerated().map { index, image in
            let button = UIButton(type: .custom); button.clipsToBounds = true; button.layer.cornerRadius = 8
            button.contentHorizontalAlignment = .fill; button.contentVerticalAlignment = .fill
            button.imageView?.contentMode = .scaleAspectFill; button.backgroundColor = .secondarySystemBackground
            button.accessibilityLabel = Localization.text("moments.photoNumber", Int64(index + 1))
            var actions: [UIAction] = []
            if index > 0 { actions.append(UIAction(title: Localization.text("moments.moveEarlier"), image: UIImage(systemName: "arrow.up")) { [weak self] _ in self?.action?(.moveImage(index, to: index - 1)) }) }
            if index + 1 < draft.images.count { actions.append(UIAction(title: Localization.text("moments.moveLater"), image: UIImage(systemName: "arrow.down")) { [weak self] _ in self?.action?(.moveImage(index, to: index + 1)) }) }
            actions.append(UIAction(title: Localization.text("moments.removePhoto"), image: UIImage(systemName: "trash"), attributes: .destructive) { [weak self] _ in self?.action?(.removeImage(index)) })
            button.menu = UIMenu(children: actions); button.showsMenuAsPrimaryAction = true
            imageTasks.append(Task { [weak self, weak button] in
                guard let self else { return }
                do { let data = try await media.localImage(image); try Task.checkCancellation(); button?.setImage(UIImage(data: data), for: .normal) } catch {}
            })
            return button
        }
        if let video = draft.video {
            let button = UIButton(type: .system)
            var configuration = UIButton.Configuration.plain()
            configuration.imagePlacement = .top; configuration.imagePadding = 6
            configuration.titleTextAttributesTransformer = UIConfigurationTextAttributesTransformer { attributes in
                var result = attributes; result.font = .preferredFont(forTextStyle: .footnote); return result
            }
            button.configuration = configuration
            let formatter = DateComponentsFormatter(); formatter.allowedUnits = [.minute, .second]; formatter.zeroFormattingBehavior = .pad
            button.setTitle(video.output == nil ? Localization.text("moments.videoTrim") : Localization.text("moments.videoDuration", formatter.string(from: Double(video.duration) / 1000) ?? ""), for: .normal)
            button.setImage(UIImage(systemName: "play.rectangle"), for: .normal)
            button.imageView?.contentMode = .scaleAspectFit
            button.accessibilityIdentifier = "moments.editor.video"
            var actions = [UIAction(title: Localization.text("moments.videoTrim"), image: UIImage(systemName: "crop")) { [weak self] _ in self?.action?(.editVideo) }]
            if video.output != nil {
                actions.insert(UIAction(title: Localization.text("moments.videoPlay"), image: UIImage(systemName: "play")) { [weak self] _ in
                    self?.action?(.playVideo)
                }, at: 0)
            }
            actions.append(UIAction(title: Localization.text("moments.videoRemove"), image: UIImage(systemName: "trash"), attributes: .destructive) { [weak self] _ in
                self?.action?(.removeVideo)
            })
            button.menu = UIMenu(children: actions); button.showsMenuAsPrimaryAction = true
            if let poster = video.poster {
                imageTasks.append(Task { [weak self, weak button] in
                    guard let self else { return }
                    if let data = try? await media.localImage(poster), !Task.isCancelled {
                        button?.setImage(UIImage(data: data)?.preparingThumbnail(of: CGSize(width: 250, height: 108))?.withRenderingMode(.alwaysOriginal), for: .normal)
                    }
                })
            }
            images.append(button)
        }
        setNeedsQuickLayout()
    }

    isolated deinit { imageTasks.forEach { $0.cancel() } }
}

#if DEBUG
@available(iOS 17.0, *)
#Preview("朋友圈发布组件") { MomentsComposerView(media: MomentsMediaProvider(runtime: MomentsPreviewData.runtime()), state: MomentsComposerViewModel(runtime: MomentsPreviewData.runtime(), draft: MomentsDraft()).state) }
#endif
