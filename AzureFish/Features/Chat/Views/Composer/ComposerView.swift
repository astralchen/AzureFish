//
//  ComposerView.swift
//  Demo
//

import AppLocalization
import QuickLayout
import QuickLayoutKit
import UIKit

/// 支持文本、照片/视频草稿、语音转写文本和音频消息的 Liquid Glass 输入栏。
///
/// 此视图渲染页面媒体控制器提供的状态，不持有录音器、播放器或语音识别任务。
@available(iOS 26.0, *)
final class ComposerView: QuickLayoutView, UITextViewDelegate {

    /// 启用 TextKit 2、承载文字与内联附件的文本编辑器。
    let textView = ComposerTextView(usingTextLayoutManager: true)
    lazy var inputBinding = Localization.inputContext(for: self)
        .makeTextInputBinding(to: textView)

    /// 接管系统粘贴并保留文字与附件顺序的协调器。
    lazy var pasteCoordinator = PasteCoordinator(textView: textView)
    /// 粘贴解析出待导入来源后调用的闭包。
    var pasteAttachments: (([PasteSource]) -> Void)?
    /// 编辑器为空时显示提示文字的标签。
    let placeholderLabel = UILabel()
    /// 草稿阻止录音时显示的短暂说明。
    let recordingUnavailableLabel = UILabel()
    /// 展开照片、录音、文件和链接菜单的按钮。
    let attachmentButton = UIButton(type: .system)
    /// 发送当前文字或混合草稿的按钮。
    let sendButton = ComposerHitButton(type: .system)
    /// 开始或停止实时听写的按钮。
    let dictationButton = UIButton(type: .system)
    /// 停止录音并保留有效草稿的按钮。
    let recordingStopButton = ComposerHitButton(type: .system)
    /// 丢弃当前音频草稿的按钮。
    let audioCancelButton = UIButton(type: .system)
    /// 切换音频草稿播放与暂停的按钮。
    let audioPlayButton = ComposerHitButton(type: .system)
    /// 发送当前音频草稿的按钮。
    let audioSendButton = ComposerHitButton(type: .system)
    /// 显示实时录音音量的固定槽位波形视图。
    let recordingWaveformView = WaveformView()
    /// 显示音频草稿波形和播放位置的视图。
    let previewWaveformView = WaveformView()
    /// 显示当前已录制时长的标签。
    let recordingDurationLabel = UILabel()
    /// 显示音频预览时长或播放时间的标签。
    let previewDurationLabel = UILabel()
    /// 按选择顺序显示照片和视频草稿的横向条带。
    let mediaDraftStripView = MediaDraftStripView()
    /// 分隔媒体草稿与文本操作区域的视图。
    let mediaDraftSeparatorView = UIView()

    /// 用户在输入栏中发起操作时调用。
    ///
    /// 处理方应对成功接受的动作返回 `true`。发送动作返回 `false` 时，Composer
    /// 会保留当前文本或附件预览，避免验证、导入或文件失效导致草稿丢失。
    var actionRequested: ((ComposerAction) -> Bool)?

    /// 完成一次正文编辑事务后报告语义内容变化。
    ///
    /// 覆盖用户编辑、格式变更、附件插入删除、听写写入及受理发送后的清空。
    /// 不因光标移动或播放进度变化而调用；页面在批量恢复期间应忽略此回调。
    var draftDidChange: (() -> Void)?

    /// 输入栏固有高度发生变化时调用。
    var heightDidChange: ((HeightChange) -> Void)?
    /// 实际 frame 已安装后，通知页面同步全屏列表的覆盖范围。
    var geometryDidLayout: (() -> Void)?
    enum HeightChange {
        case immediate
        case textInput
        case mediaDraft
    }
    /// 将一次用户操作内的多次测量合并到同一布局事务。
    var isUpdatingPresentation = false
    var isAnimatingPresentation = false
    var hasPendingPresentationHeightChange = false
    var presentationGeneration = 0

    /// 清空草稿时短暂保留的纯视觉副本，不参与命中、辅助功能或发送状态。
    var mediaDraftExitSnapshot: UIView?

    /// 文本编辑器取得第一响应者时调用，用于完成照片 Sheet 到键盘的交接。
    var textInputDidBeginEditing: (() -> Void)?

    /// 当前输入栏使用的本地化文字集合。
    var strings = ComposerStrings(
        placeholder: "iMessage",
        send: "Send",
        addAttachment: "Add attachment",
        audio: "Audio",
        dictate: "Dictate",
        stopDictation: "Stop dictation",
        stopRecording: "Stop recording",
        cancelAudio: "Cancel audio",
        playAudio: "Play audio",
        pauseAudio: "Pause audio",
        recordingRequiresEmptyDraft: "To record audio, clear the input field."
    )
    /// 驱动录音、听写和预览控件显示的媒体状态。
    var composerState: ComposerState = .idle
    /// 当前有序媒体草稿；提示只改变展示，导入结果继续通过 `applyMediaDraft` 更新。
    var mediaDraft: MediaDraftPresentation?
    var hasVisibleMediaDraft: Bool { mediaDraft?.hasVisibleItems == true }
    /// 媒体草稿及预览操作使用的本地化文字集合。
    var mediaStrings = MediaStrings(
        photo: "Photos",
        itemsFormat: "%d items",
        image: "Image",
        animatedImage: "Animated image",
        video: "Video",
        videoDurationFormat: "Video, duration %@",
        importing: "Importing",
        remove: "Remove",
        play: "Play",
        openPreview: "Open preview",
        close: "Close",
        firstItem: "First item",
        lastItem: "Last item",
        positionFormat: "%d of %d"
    )
    /// 最近一次测量得到的文本输入高度，单位为点。
    var currentInputHeight = Metrics.textInputHeight
    /// 指示正在回填识别文本的布尔值，避免将更新误判为手动输入。
    var isApplyingTranscription = false
    /// 按稳定身份保存的活跃 TextKit 附件对象。
    var textAttachments: [UUID: TextAttachment] = [:]
    /// 指示正在核对编辑器附件身份的布尔值，用于阻止递归核对。
    var isReconcilingAttachments = false
    /// 指示混合内容替换事务尚未结束的布尔值，用于忽略中间编辑回调。
    var isInsertingContents = false

    /// 提示属于输入栏展示状态，不占用音频控制器或麦克风。
    var isShowingRecordingUnavailableHint = false
    /// 可注入的等待操作，让测试无需真实等待两秒。
    var recordingHintSleeper: @MainActor @Sendable (Duration) async throws -> Void = {
        try await Task.sleep(for: $0)
    }
    /// 控制录音不可用提示自动结束的延时任务。
    var recordingHintTask: Task<Void, Never>?
    /// 录音提示操作的递增版本，用于忽略旧任务的完成回调。
    var recordingHintGeneration = 0
    /// 提示期间保留的文本滚动偏移，在恢复布局后应用。
    var retainedTextContentOffset: CGPoint?

    /// 附件菜单按钮使用的玻璃背景容器。
    lazy var attachmentGlassView: QuickLayoutVisualEffectView = {
        let effect = UIGlassEffect(style: .regular)
        effect.isInteractive = true
        let glassView = QuickLayoutVisualEffectView(
            effect: effect
        ) { [unowned self] in
            attachmentButton.resizable().frame(width: 44, height: 44)
        }
        glassView.cornerConfiguration = .capsule()
        return glassView
    }()

    /// 组织文本编辑器、媒体草稿与操作区域的布局容器。
    lazy var editorContainer: QuickLayoutView = QuickLayoutView { [self] in
        ZStack(alignment: .topLeading) { [unowned self] in
            self.textView.resizable()
            self.placeholderLabel
                .resizable(axis: .horizontal)
                .fixedSize(axis: .vertical)
                .padding(.horizontal, 8)
                .frame(
                    maxWidth: .infinity,
                    maxHeight: .infinity,
                    alignment: .leading
                )
            self.recordingUnavailableLabel
                .resizable()
                .padding(.horizontal, 8)
        }
    }

    /// 持续挂载的底部操作容器，让淡出的旧按钮也跟随底部布局。
    lazy var textActionContainer = ComposerActionContainer { [unowned self] in
        textActionContent.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
    }

    /// 常规文本输入区域使用的玻璃背景容器。
    lazy var inputGlassView: QuickLayoutVisualEffectView = {
        let effect = UIGlassEffect(style: .regular)
        effect.isInteractive = true
        return QuickLayoutVisualEffectView(effect: effect) { [unowned self] in
            VStack(spacing: 0) {
                // 保留零高度的裁剪容器，让首张入场也有真实的旧几何。
                // 动画中临时挂入固定高度视图会直接盖到下方文本行。
                mediaDraftStripView
                    .resizable()
                    .frame(height: hasVisibleMediaDraft && !isShowingRecordingUnavailableHint
                        ? Metrics.mediaDraftHeight : 0)
                    .padding(.horizontal, 4)
                    .padding(.top, hasVisibleMediaDraft && !isShowingRecordingUnavailableHint ? 4 : 0)
                if hasVisibleMediaDraft && !isShowingRecordingUnavailableHint {
                    mediaDraftSeparatorView
                        .resizable(axis: .horizontal)
                        .frame(height: hairlineHeight)
                        .padding(.horizontal, 16)
                        .padding(.top, 4)
                        .padding(
                            .bottom,
                            Metrics.mediaDraftSpacing
                                - 4
                                - hairlineHeight
                        )
                }
                VStack(spacing: 0) {
                    if documentActionHeight > 0 {
                        // 附件占用完整编辑宽度，发送操作只占下方一行。
                        textEditorLayout
                        textActionLayout.frame(maxWidth: .infinity, alignment: .trailing)
                    } else {
                        HStack(alignment: .bottom, spacing: Metrics.textActionSpacing) {
                            textEditorLayout
                            textActionLayout
                        }
                    }
                }
                .padding(.leading, Metrics.textLeadingPadding)
                .padding(.trailing, Metrics.textTrailingPadding)
            }
        }
    }()

    /// 录音状态使用的玻璃背景容器。
    lazy var recordingGlassView: QuickLayoutVisualEffectView = {
        let effect = UIGlassEffect(style: .regular)
        effect.isInteractive = true
        let glassView = QuickLayoutVisualEffectView(
            effect: effect
        ) { [unowned self] in
            HStack(
                alignment: .center,
                spacing: Metrics.recordingHorizontalSpacing
            ) {
                recordingWaveformView
                    .resizable(axis: .horizontal)
                    .frame(height: 30)
                    .padding(
                        .leading,
                        Metrics.recordingWaveformLeadingInset
                    )
                recordingDurationLabel.fixedSize()
                recordingStopButton
                    .resizable()
                    .frame(
                        width: Metrics.mediaControlSize,
                        height: Metrics.mediaControlSize
                    )
            }
            .padding(Metrics.mediaContentPadding)
        }
        glassView.cornerConfiguration = .capsule()
        return glassView
    }()

    /// 音频预览状态使用的玻璃背景容器。
    lazy var previewGlassView: QuickLayoutVisualEffectView = {
        let effect = UIGlassEffect(style: .regular)
        effect.isInteractive = true
        let glassView = QuickLayoutVisualEffectView(
            effect: effect
        ) { [unowned self] in
            HStack(spacing: Metrics.previewHorizontalSpacing) {
                audioPlayButton
                    .resizable()
                    .frame(
                        width: Metrics.mediaControlSize,
                        height: Metrics.mediaControlSize
                    )
                previewWaveformView
                    .resizable(axis: .horizontal)
                    .frame(height: 30)
                previewDurationContainer.fixedSize()
                audioSendButton
                    .resizable()
                    .frame(
                        width: Metrics.sendButtonWidth,
                        height: Metrics.sendButtonHeight
                    )
            }
            .padding(Metrics.mediaContentPadding)
        }
        glassView.cornerConfiguration = .capsule()
        return glassView
    }()

    /// 音频取消按钮使用的独立玻璃背景容器。
    lazy var audioCancelGlassView: QuickLayoutVisualEffectView = {
        let effect = UIGlassEffect(style: .regular)
        effect.isInteractive = true
        let glassView = QuickLayoutVisualEffectView(
            effect: effect
        ) { [unowned self] in
            audioCancelButton
                .resizable()
                .frame(
                    width: Metrics.mediaControlHitSize,
                    height: Metrics.mediaControlHitSize
                )
        }
        glassView.cornerConfiguration = .capsule()
        return glassView
    }()

    /// 固定音频预览时长标签布局的容器。
    lazy var previewDurationContainer = QuickLayoutView { [unowned self] in
        self.previewDurationLabel
            .fixedSize()
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
    }

    /// 定义 `ComposerView` 的布局层级、间距和对齐方式。
    @LayoutBuilder
    override var body: Layout {
        ZStack(alignment: .bottom) {
            HStack(alignment: .bottom, spacing: 8) {
                attachmentGlassView.frame(width: 44, height: 44)
                inputGlassView
                    .resizable(axis: .horizontal)
                    .frame(height: retainedTextInputHeight)
            }

            switch composerState {
            case .recording:
                recordingGlassView
                    .resizable(axis: .horizontal)
                    .frame(height: Metrics.mediaInputHeight)

            case .audioPreview where textAttachments.isEmpty:
                HStack(alignment: .center, spacing: 8) {
                    audioCancelGlassView.frame(
                        width: Metrics.mediaControlHitSize,
                        height: Metrics.mediaControlHitSize
                    )
                    previewGlassView
                        .resizable(axis: .horizontal)
                        .frame(height: Metrics.mediaInputHeight)
                }

            case .idle, .preparingSpeech, .dictating, .audioPreview:
                Spacer().frame(width: 0, height: 0)
            }
        }
        .padding(.horizontal, Metrics.horizontalPadding)
        .padding(.vertical, Metrics.verticalPadding)
    }

    /// 使用指定初始边框创建 `ComposerView`，并配置其子视图和默认外观。
    ///
    /// - Parameter frame: 在父视图坐标系中指定的初始边框。
    override init(frame: CGRect) {
        super.init(frame: frame)
        configureViews()
    }

    /// 不支持从归档创建 `ComposerView`。
    ///
    /// 请使用代码初始化方法创建此对象。
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    /// 在输入栏释放时取消录音提示的延时任务。
    deinit {
        recordingHintTask?.cancel()
    }

    /// 进入窗口后重新测量文本；离开窗口时使粘贴任务和录音提示失效。
    override func didMoveToWindow() {
        super.didMoveToWindow()
        guard window != nil else {
            pasteCoordinator.invalidate()
            dismissRecordingUnavailableHint()
            return
        }
        inputBinding.refresh()
        DispatchQueue.main.async { [weak self] in
            self?.updateTextHeight()
        }
    }

    /// 根据当前边界更新 `ComposerView` 的子视图布局与图层几何。
    override func layoutSubviews() {
        super.layoutSubviews()
        geometryDidLayout?()
        if !isShowingRecordingUnavailableHint, let retainedTextContentOffset {
            textView.setContentOffset(retainedTextContentOffset, animated: false)
            self.retainedTextContentOffset = nil
        }
    }

    /// 在动态字体类别变化后刷新附件尺寸、TextKit 布局与输入高度。
    override func traitCollectionDidChange(
        _ previousTraitCollection: UITraitCollection?
    ) {
        super.traitCollectionDidChange(previousTraitCollection)
        guard previousTraitCollection?.preferredContentSizeCategory
                != traitCollection.preferredContentSizeCategory else {
            return
        }
        refreshTextAttachments()
        if let manager = textView.textLayoutManager, let content = manager.textContentManager {
            manager.invalidateLayout(for: content.documentRange)
        }
        updateTextHeight()
    }

    /// `ComposerView` 在当前内容与布局约束下的固有尺寸。
    override var intrinsicContentSize: CGSize {
        CGSize(
            width: UIView.noIntrinsicMetric,
            height: resolvedContentHeight + Metrics.verticalPadding * 2
        )
    }

    /// 返回 `ComposerView` 在指定建议尺寸下所需的大小。
    ///
    /// - Parameter size: 父视图提供的建议尺寸。
    /// - Returns: 当前内容对应的适配尺寸。
    override func sizeThatFits(_ size: CGSize) -> CGSize {
        CGSize(
            width: size.width,
            height: resolvedContentHeight + Metrics.verticalPadding * 2
        )
    }

    /// 悬浮输入栏周围的透明留白允许触摸到达下方时间线。
    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        let target = super.hitTest(point, with: event)
        return target === self ? nil : target
    }
}

#if DEBUG
/// 创建指定草稿、媒体状态和布局方向的输入栏预览，可选择显示录音不可用提示。
@available(iOS 26.0, *)
@MainActor
private func makeChatComposerPreview(
    text: String,
    state: ComposerState,
    direction: UIUserInterfaceLayoutDirection,
    showsRecordingHint: Bool = false
) -> UIViewController {
    let backgroundView = UIView()
    backgroundView.backgroundColor = .systemBackground
    let composerView = ComposerView(frame: .zero)
    composerView.configure(strings: ConversationPreviewData.composerStrings)
    composerView.applyLayoutDirection(direction)
    composerView.textView.text = text
    composerView.textViewDidChange(composerView.textView)
    composerView.applyState(state)
    if showsRecordingHint {
        // Canvas 保持提示外观；真实页面仍使用默认两秒等待。
        composerView.recordingHintSleeper = { _ in
            try await Task.sleep(for: .seconds(3_600))
        }
        _ = composerView.validateAudioRecordingRequest()
    }
    return QuickLayoutHostingController {
        ZStack(alignment: .bottom) {
            backgroundView.resizable()
            composerView
                .resizable(axis: .horizontal)
                .fixedSize(axis: .vertical)
        }
        .frame(width: 390, height: 170)
    }
}

@available(iOS 26.0, *)
#Preview("消息输入栏 · 空白") {
    makeChatComposerPreview(
        text: "",
        state: .idle,
        direction: .leftToRight
    )
}

@available(iOS 26.0, *)
#Preview("消息输入栏 · 多行") {
    makeChatComposerPreview(
        text: ConversationPreviewData.composerMultilineText,
        state: .idle,
        direction: .leftToRight
    )
}

@available(iOS 26.0, *)
#Preview("消息输入栏 · 录音") {
    makeChatComposerPreview(
        text: "",
        state: .recording(
            elapsed: 3,
            waveform: ConversationPreviewData.recordingWaveform
        ),
        direction: .leftToRight
    )
}

@available(iOS 26.0, *)
#Preview("消息输入栏 · 音频预览") {
    makeChatComposerPreview(
        text: "",
        state: .audioPreview(
            attachment: ConversationPreviewData.audioAttachment,
            isPlaying: false,
            progress: 0
        ),
        direction: .leftToRight
    )
}

@available(iOS 26.0, *)
#Preview("消息输入栏 · RTL") {
    makeChatComposerPreview(
        text: ConversationPreviewData.composerRTLText,
        state: .idle,
        direction: .rightToLeft
    )
}

@available(iOS 26.0, *)
#Preview("消息输入栏 · 录音前清空提示") {
    makeChatComposerPreview(
        text: ConversationPreviewData.composerMultilineText,
        state: .idle,
        direction: .leftToRight,
        showsRecordingHint: true
    )
}

@available(iOS 26.0, *)
#Preview("消息输入栏 · 录音前清空提示 RTL") {
    makeChatComposerPreview(
        text: ConversationPreviewData.composerRTLText,
        state: .idle,
        direction: .rightToLeft,
        showsRecordingHint: true
    )
}
#endif
