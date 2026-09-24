//
//  ComposerView+Layout.swift
//  Demo
//

import AppLocalization
import QuickLayout
import QuickLayoutKit
import UIKit

/// 组织布局规则、尺寸计算与组件几何。
@available(iOS 26.0, *)
extension ComposerView {

    /// 将内容、按钮和最终高度一起提交；嵌套的附件回调只参与当前事务。
    /// 新操作从当前呈现位置接续，过期完成回调不能隐藏新状态的提示文字。
    func performPresentationUpdate(duration: TimeInterval = 0.22,
                                   animated shouldAnimate: Bool = true,
                                   _ updates: @escaping @MainActor () -> Void) {
        guard !isUpdatingPresentation else { updates(); return }
        superview?.layoutIfNeeded()
        let animated = shouldAnimate && window != nil && UIView.areAnimationsEnabled
            && !UIAccessibility.isReduceMotionEnabled
        if animated {
            // 隐藏标签先以原 alpha 参与渲染，下一事务才有可插值的透明起点。
            placeholderLabel.isHidden = false
            recordingUnavailableLabel.isHidden = false
        }
        presentationGeneration += 1
        let generation = presentationGeneration
        let changes = { [self] in
            isUpdatingPresentation = true
            isAnimatingPresentation = animated
            updates()
            isUpdatingPresentation = false
            isAnimatingPresentation = false
            if hasPendingPresentationHeightChange {
                hasPendingPresentationHeightChange = false
                heightDidChange?(.immediate)
            }
            // 单行文字变化也会切换麦克风/发送按钮，不能仅依赖高度回调。
            quickLayoutIfNeeded()
            superview?.layoutIfNeeded()
        }
        let finish = { [weak self] in
            guard let self, presentationGeneration == generation else { return }
            placeholderLabel.isHidden = placeholderLabel.alpha == 0
            recordingUnavailableLabel.isHidden = recordingUnavailableLabel.alpha == 0
        }
        guard animated else { UIView.performWithoutAnimation(changes); finish(); return }
        UIView.animate(withDuration: duration, delay: 0, usingSpringWithDamping: 1,
                       initialSpringVelocity: 0,
                       options: [.beginFromCurrentState, .allowUserInteraction],
                       animations: changes) { _ in finish() }
    }

    /// 状态事务内只记录高度失效，待最终内容确定后再通知页面一次。
    func notifyHeightChange(_ change: HeightChange) {
        guard !isUpdatingPresentation else {
            hasPendingPresentationHeightChange = true
            return
        }
        heightDidChange?(change)
    }

    /// 会改变输入栏视图层级或固有高度的展示模式。
    ///
    /// 录音计量和播放进度属于同一模式内的数据更新，不应触发 Composer
    /// 重新布局，否则高频刷新会使玻璃背景和固定内边距产生视觉抖动。
    enum LayoutMode: Equatable {
        /// 显示常规文本输入与附件入口。
        case idle
        /// 显示语音识别准备状态。
        case preparingSpeech
        /// 显示活动听写状态。
        case dictating
        /// 显示录音波形、时长与停止操作。
        case recording
        /// 显示音频草稿预览与发送操作。
        case preview
        /// 显示照片或视频草稿条带。
        case mediaDraft
        /// 显示草稿非空时的短暂录音不可用提示。
        case recordingUnavailable
        /// 显示包含内联文档卡片的文本编辑器。
        case documentAttachments
    }

    /// 输入栏各状态共用的布局尺寸，长度单位均为点。
    enum Metrics {
        /// 输入栏内容相对页面左右边缘的内边距。
        static let horizontalPadding: CGFloat = 16
        /// 输入栏内容相对上下边缘的内边距。
        static let verticalPadding: CGFloat = 8
        /// 单行文本输入区域的基准高度。
        static let textInputHeight: CGFloat = 44
        /// 文本操作区域为发送或听写按钮保留的宽度。
        static let textActionWidth: CGFloat = 44

        /// 文本和音频预览发送按钮共用的横向胶囊视觉尺寸。
        ///
        /// 该尺寸来自 iPhone 16 Pro 设计图的 @3x 像素测量；按钮命中区域
        /// 仍由 ``ComposerHitButton`` 扩展到 44 × 44 点。
        static let sendButtonWidth: CGFloat = 38
        /// 发送按钮的视觉高度。
        static let sendButtonHeight: CGFloat = 28
        /// 文本听写按钮的布局高度。
        static let textDictationButtonHeight: CGFloat = 40
        /// 文本操作控件之间的间距。
        static let textActionSpacing: CGFloat = 4
        /// 文本操作区域语义起始侧的额外内边距。
        static let textLeadingPadding: CGFloat = 4
        /// 文本操作区域语义结束侧的额外内边距。
        static let textTrailingPadding: CGFloat = 6

        /// 文本发送按钮与输入玻璃底边之间的设计间距。
        ///
        /// 此值只用于文本输入玻璃；录音面板继续使用独立的 64 点胶囊布局。
        static let textSendBottomPadding: CGFloat = 6

        /// 麦克风按钮用于保持与文本发送按钮相同的尾部布局高度。
        static let textDictationBottomPadding: CGFloat = 2
        /// 录音和音频预览胶囊的高度。
        static let mediaInputHeight: CGFloat = 64
        /// 录音波形与控制区域之间的水平间距。
        static let recordingHorizontalSpacing: CGFloat = 12

        /// 录音和预览玻璃内所有内容共用的四边基础内边距。
        ///
        /// 两种媒体状态必须从相同的内容边界开始布局，避免状态切换时玻璃内
        /// 控件产生水平或垂直跳动。
        static let mediaContentPadding: CGFloat = 14

        /// 实时录音波形在共享内容边界内使用的额外起始留白。
        ///
        /// 该留白用于匹配设计图中没有前置播放按钮时的波形视觉起点；停止按钮
        /// 仍然只使用共享的 14 点结束内边距。
        static let recordingWaveformLeadingInset: CGFloat = 14
        /// 媒体控制按钮的视觉尺寸。
        static let mediaControlSize: CGFloat = 36
        /// 媒体控制按钮的最小布局触控尺寸。
        static let mediaControlHitSize: CGFloat = 44
        /// 音频预览控件之间的水平间距。
        static let previewHorizontalSpacing: CGFloat = 8
        /// 照片和视频草稿条带的固定高度。
        static let mediaDraftHeight = MediaDraftAppearance.itemHeight
        /// 媒体草稿条带与其余输入内容之间的间距。
        static let mediaDraftSpacing: CGFloat = 8
    }

    /// 固定当前编辑高度并观察可用宽度变化的文本编辑区域布局。
    @LayoutBuilder
    var textEditorLayout: Layout {
        editorContainer
            .resizable(axis: .horizontal)
            .frame(height: isShowingRecordingUnavailableHint ? Metrics.textInputHeight : currentInputHeight)
            .onGeometryChange(
                for: CGFloat.self,
                of: { max(0, $0.size.width - 8) },
                action: { [weak self] width in self?.updateTextHeight(availableWidth: width) }
            )
    }

    /// 内联附件模式下独立操作行的高度，单位为点。
    var documentActionHeight: CGFloat {
        guard !textAttachments.isEmpty && !isShowingRecordingUnavailableHint else { return 0 }
        switch composerState {
        case .preparingSpeech, .dictating:
            return Metrics.textDictationButtonHeight + Metrics.textDictationBottomPadding
        case .idle, .recording, .audioPreview:
            return Metrics.sendButtonHeight + Metrics.textSendBottomPadding
        }
    }

    /// 容器始终底部对齐，按钮切换不会改变普通输入行的操作容器高度。
    @LayoutBuilder
    var textActionLayout: Layout {
        textActionContainer
            .resizable()
            .frame(width: Metrics.textActionWidth, height: documentActionHeight > 0
                ? documentActionHeight : max(Metrics.textInputHeight, singleLineInputHeight))
    }

    /// 根据草稿是否存在与听写状态选择按钮；导入中保留发送入口，仅禁用发送。
    @LayoutBuilder
    var textActionContent: Layout {
        switch composerState {
        case .preparingSpeech, .dictating:
            dictationButton
                .resizable()
                .frame(
                    width: Metrics.textActionWidth,
                    height: Metrics.textDictationButtonHeight
                )
                .padding(.bottom, dictationButtonBottomPadding)
        case .idle, .recording, .audioPreview:
            if isShowingRecordingUnavailableHint || mediaDraft != nil || !textAttachments.isEmpty || hasSendableContent {
                sendButton
                    .resizable()
                    .frame(
                        width: Metrics.sendButtonWidth,
                        height: Metrics.sendButtonHeight
                    )
                    .frame(
                        width: Metrics.textActionWidth,
                        alignment: .trailing
                    )
                    .padding(.bottom, sendButtonBottomPadding)
            } else {
                dictationButton
                    .resizable()
                    .frame(
                        width: Metrics.textActionWidth,
                        height: Metrics.textDictationButtonHeight
                    )
                    .padding(.bottom, dictationButtonBottomPadding)
            }
        }
    }

    /// 单行输入及临时提示中，发送按钮在输入胶囊内上下等距。
    private var sendButtonBottomPadding: CGFloat {
        if isShowingRecordingUnavailableHint {
            return (Metrics.textInputHeight - Metrics.sendButtonHeight) / 2
        }
        if !textAttachments.isEmpty { return Metrics.textSendBottomPadding }
        return currentInputHeight <= singleLineInputHeight + 0.5
            ? (currentInputHeight - Metrics.sendButtonHeight) / 2
            : Metrics.textSendBottomPadding
    }

    private var dictationButtonBottomPadding: CGFloat {
        guard textAttachments.isEmpty else { return Metrics.textDictationBottomPadding }
        return currentInputHeight <= singleLineInputHeight + 0.5
            ? (currentInputHeight - Metrics.textDictationButtonHeight) / 2
            : Metrics.textDictationBottomPadding
    }

    private var singleLineInputHeight: CGFloat {
        let font = textView.font ?? .preferredFont(forTextStyle: .body)
        return max(
            Metrics.textInputHeight,
            ceil(font.lineHeight) + textView.textContainerInset.top
                + textView.textContainerInset.bottom
        )
    }

    /// 根据录音、预览、提示及媒体草稿状态解析的内容高度。
    var resolvedContentHeight: CGFloat {
        // 提示临时覆盖附件展示；外层高度必须与内部的单行提示保持一致。
        if isShowingRecordingUnavailableHint { return Metrics.textInputHeight }
        if !textAttachments.isEmpty { return currentInputHeight + mediaDraftAdditionalHeight + documentActionHeight }
        return switch composerState {
        case .idle, .preparingSpeech, .dictating:
            currentInputHeight + mediaDraftAdditionalHeight
        case .recording, .audioPreview:
            Metrics.mediaInputHeight
        }
    }

    /// 返回当前媒体状态对应的稳定布局模式。
    var layoutMode: LayoutMode {
        if isShowingRecordingUnavailableHint { return .recordingUnavailable }
        if !textAttachments.isEmpty { return .documentAttachments }
        return switch composerState {
        case .idle:
            mediaDraft == nil ? .idle : .mediaDraft
        case .preparingSpeech:
            .preparingSpeech
        case .dictating:
            .dictating
        case .recording:
            .recording
        case .audioPreview:
            .preview
        }
    }

    /// 常规输入层保留的高度，用于在媒体状态切换期间稳定布局。
    var retainedTextInputHeight: CGFloat {
        if isShowingRecordingUnavailableHint { return Metrics.textInputHeight }
        if !textAttachments.isEmpty { return currentInputHeight + mediaDraftAdditionalHeight + documentActionHeight }
        return switch composerState {
        case .idle, .preparingSpeech, .dictating:
            currentInputHeight + mediaDraftAdditionalHeight
        case .recording, .audioPreview:
            Metrics.textInputHeight
        }
    }

    /// 媒体草稿存在时需要额外预留的条带与间距高度。
    private var mediaDraftAdditionalHeight: CGFloat {
        !hasVisibleMediaDraft
            ? 0
            : Metrics.mediaDraftHeight + Metrics.mediaDraftSpacing + 4
    }

    /// 当前显示环境的单个物理像素，避免 iOS 26 已弃用的全局屏幕查询。
    var hairlineHeight: CGFloat {
        1 / max(1, traitCollection.displayScale)
    }

    /// 按可用宽度测量文本内容，并在有效高度变化时通知页面更新布局。
    func updateTextHeight(availableWidth: CGFloat? = nil, animated: Bool = false) {
        guard !isShowingRecordingUnavailableHint else { return }
        let font = textView.font ?? .preferredFont(forTextStyle: .body)
        let width = max(1, availableWidth ?? textView.bounds.width)
        let previousInsets = textView.textContainerInset
        let measuredContentHeight = max(0, textView.sizeThatFits(
            CGSize(width: width, height: .greatestFiniteMagnitude)
        ).height - previousInsets.top - previousInsets.bottom)
        // 44 点胶囊比单行排版高，把剩余高度平分到上下；多行仍使用 8 点。
        // 先扣除旧内边距，避免连续测量把上一轮居中留白重复计入高度。
        let verticalInset = max(8, (Metrics.textInputHeight - measuredContentHeight) / 2)
        if abs(previousInsets.top - verticalInset) > 0.01
            || abs(previousInsets.bottom - verticalInset) > 0.01 {
            textView.textContainerInset = UIEdgeInsets(
                top: verticalInset, left: previousInsets.left,
                bottom: verticalInset, right: previousInsets.right
            )
            editorContainer.setNeedsQuickLayout()
        }
        let attachmentWidth = max(1, width - textView.textContainerInset.left
            - textView.textContainerInset.right - textView.textContainer.lineFragmentPadding * 2)
        let attachmentHeight = textAttachments.values.reduce(CGFloat.zero) { total, attachment in
            total + attachment.preferredSize(maximumWidth: attachmentWidth,
                layoutManager: textView.textLayoutManager).height + ceil(font.lineHeight)
        }
        let contentLimit = attachmentHeight + ceil(font.lineHeight * 5)
            + textView.textContainerInset.top
            + textView.textContainerInset.bottom
        // 多附件不能把整页推出窗口；超过可见预算后仍由原 UITextView 滚动编辑。
        let viewportLimit = textAttachments.isEmpty ? contentLimit
            : max(180, (window?.bounds.height ?? 874) * 0.42) - documentActionHeight
        let maximumHeight = min(contentLimit, viewportLimit)
        let measuredHeight = measuredContentHeight + verticalInset * 2
        let resolvedHeight = min(max(44, ceil(measuredHeight)), maximumHeight)
        textView.isScrollEnabled = measuredHeight > maximumHeight + 0.5

        guard abs(resolvedHeight - currentInputHeight) > 0.5 else { return }
        currentInputHeight = resolvedHeight
        textActionContainer.setNeedsQuickLayout()
        inputGlassView.setNeedsQuickLayout()
        setNeedsQuickLayout()
        invalidateIntrinsicContentSize()
        superview?.setNeedsLayout()
        let shouldAnimate = animated && window != nil && !UIAccessibility.isReduceMotionEnabled
            && UIView.areAnimationsEnabled
        notifyHeightChange(shouldAnimate ? .textInput : .immediate)
    }
}
