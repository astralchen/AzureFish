//
//  ComposerView+Configuration.swift
//  Demo
//

import AppLocalization
import QuickLayout
import QuickLayoutKit
import UIKit

/// 配置子视图外观与控件属性。
@available(iOS 26.0, *)
extension ComposerView {

    /// 配置输入控件、动态字体、辅助功能标识和操作回调。
    func configureViews() {
        pasteCoordinator.insertAttachments = { [weak self] sources in
            guard let self, !isShowingRecordingUnavailableHint else { return }
            pasteAttachments?(sources)
        }
        pasteCoordinator.textDidChange = { [weak self] in
            guard let self else { return }
            textViewDidChange(textView)
        }
        accessibilityIdentifier = "imessage.composer"
        backgroundColor = .clear
        quickLayoutHorizontalFlexibility = .fullyFlexible
        quickLayoutVerticalFlexibility = .fixedSize

        mediaDraftSeparatorView.backgroundColor = .separator
        mediaDraftSeparatorView.isAccessibilityElement = false

        for glassView in [
            attachmentGlassView,
            inputGlassView,
            recordingGlassView,
            previewGlassView,
            audioCancelGlassView,
        ] {
            glassView.backgroundColor = .clear
            glassView.clipsToBounds = true
            glassView.layer.cornerCurve = .continuous
            glassView.layer.cornerRadius = 22
        }
        recordingGlassView.layer.cornerRadius = Metrics.mediaInputHeight / 2
        previewGlassView.layer.cornerRadius = Metrics.mediaInputHeight / 2
        audioCancelGlassView.layer.cornerRadius = Metrics.mediaControlHitSize / 2

        textView.backgroundColor = .clear
        textView.font = .preferredFont(forTextStyle: .body)
        textView.adjustsFontForContentSizeCategory = true
        textView.textColor = .label
        inputBinding.refresh()
        textView.textContainerInset = UIEdgeInsets(
            top: 8,
            left: 8,
            bottom: 8,
            right: 4
        )
        textView.textContainer.lineFragmentPadding = 0
        textView.keyboardDismissMode = .interactive
        textView.delegate = self
        textView.accessibilityIdentifier = "imessage.composer.text"

        placeholderLabel.font = .preferredFont(forTextStyle: .body)
        placeholderLabel.adjustsFontForContentSizeCategory = true
        placeholderLabel.textColor = .placeholderText
        placeholderLabel.numberOfLines = 1
        placeholderLabel.lineBreakMode = .byTruncatingTail
        placeholderLabel.isAccessibilityElement = false

        // 提示始终只有 44 点高；限制字号后再按宽度缩放，避免辅助功能字号
        // 下截断“清除输入栏”这一关键说明。VoiceOver 始终读取完整文案。
        recordingUnavailableLabel.font = UIFontMetrics(forTextStyle: .subheadline)
            .scaledFont(for: .systemFont(ofSize: 15), maximumPointSize: 20)
        recordingUnavailableLabel.adjustsFontForContentSizeCategory = true
        recordingUnavailableLabel.textColor = .secondaryLabel
        recordingUnavailableLabel.textAlignment = .center
        recordingUnavailableLabel.numberOfLines = 1
        recordingUnavailableLabel.adjustsFontSizeToFitWidth = true
        recordingUnavailableLabel.minimumScaleFactor = 0.5
        recordingUnavailableLabel.text = strings.recordingRequiresEmptyDraft
        recordingUnavailableLabel.accessibilityIdentifier = "imessage.composer.recordingUnavailable"

        configurePlainButton(
            attachmentButton,
            symbolName: "plus",
            identifier: "imessage.composer.attachment",
            action: nil
        )
        attachmentButton.cornerConfiguration = .capsule()
        attachmentButton.showsMenuAsPrimaryAction = true

        configureProminentButton(
            sendButton,
            symbolName: "arrow.up",
            color: .systemBlue,
            identifier: "imessage.composer.send",
            action: #selector(sendButtonDidTap)
        )
        configurePlainButton(
            dictationButton,
            symbolName: "mic.fill",
            identifier: "imessage.composer.dictation",
            action: #selector(dictationButtonDidTap)
        )
        configureTintedButton(
            recordingStopButton,
            symbolName: "stop.fill",
            color: .systemRed,
            identifier: "imessage.composer.recording.stop",
            action: #selector(recordingStopButtonDidTap)
        )
        configurePlainButton(
            audioCancelButton,
            symbolName: "xmark",
            identifier: "imessage.composer.audio.cancel",
            action: #selector(audioCancelButtonDidTap)
        )
        configureGrayButton(
            audioPlayButton,
            symbolName: "play.fill",
            identifier: "imessage.composer.audio.play",
            action: #selector(audioPlayButtonDidTap)
        )
        configureProminentButton(
            audioSendButton,
            symbolName: "arrow.up",
            color: .systemBlue,
            identifier: "imessage.composer.audio.send",
            action: #selector(audioSendButtonDidTap)
        )

        recordingWaveformView.playedColor = .systemRed
        recordingWaveformView.unplayedColor = UIColor.systemRed
            .withAlphaComponent(0.3)
        recordingWaveformView.minimumBarHeight = 2
        recordingWaveformView.maximumBarHeight = 12
        recordingWaveformView.barWidth = 2
        recordingWaveformView.barSpacing = 2
        recordingWaveformView.fadedLeadingFraction = 0.28
        previewWaveformView.playedColor = .label
        previewWaveformView.unplayedColor = .tertiaryLabel
        previewWaveformView.minimumBarHeight = 2
        previewWaveformView.maximumBarHeight = 12
        previewWaveformView.barWidth = 2
        previewWaveformView.barSpacing = 2

        previewDurationContainer.backgroundColor = .secondarySystemFill
        previewDurationContainer.clipsToBounds = true
        previewDurationContainer.layer.cornerCurve = .continuous
        previewDurationContainer.layer.cornerRadius = 14

        configureDurationLabel(recordingDurationLabel)
        configureDurationLabel(previewDurationLabel)
        recordingDurationLabel.textColor = .systemRed
        previewDurationLabel.textColor = .label
        for button in [
            sendButton,
            recordingStopButton,
            audioPlayButton,
            audioSendButton,
        ] {
            button.minimumHitSize = CGSize(
                width: Metrics.mediaControlHitSize,
                height: Metrics.mediaControlHitSize
            )
        }
        mediaDraftStripView.previewRequested = { [weak self] id in _ = self?.actionRequested?(.openMediaDraftItem(id)) }
        mediaDraftStripView.removeRequested = { [weak self] id in
            guard let self, !isShowingRecordingUnavailableHint else { return }
            _ = actionRequested?(.removeMediaDraftItem(id))
        }
        updateComposerState()
    }

    /// 配置固定高度媒体面板中显示的时钟标签。
    ///
    /// 字体随 Dynamic Type 缩放，但最大字号限制为 24 点，避免辅助功能字号
    /// 完全挤占波形；时长仍保持单行并优先获得完整的水平空间。
    private func configureDurationLabel(_ label: UILabel) {
        let baseFont = UIFont.monospacedDigitSystemFont(
            ofSize: 17,
            weight: .regular
        )
        label.font = UIFontMetrics(forTextStyle: .body).scaledFont(
            for: baseFont,
            maximumPointSize: 24
        )
        label.adjustsFontForContentSizeCategory = true
        label.adjustsFontSizeToFitWidth = true
        label.minimumScaleFactor = 0.8
        label.numberOfLines = 1
        label.lineBreakMode = .byClipping
        label.setContentCompressionResistancePriority(
            .required,
            for: .horizontal
        )
    }

    /// 配置在普通态、按下态和菜单高亮态均保持胶囊形状的图标按钮。
    private func configurePlainButton(
        _ button: UIButton,
        symbolName: String,
        identifier: String,
        action: Selector?
    ) {
        var configuration = UIButton.Configuration.plain()
        configuration.image = UIImage(systemName: symbolName)
        configuration.contentInsets = .zero
        configuration.cornerStyle = .capsule
        button.configuration = configuration
        button.tintColor = .label
        button.accessibilityIdentifier = identifier
        if let action {
            button.addTarget(self, action: action, for: .touchUpInside)
        }
    }

    /// 配置带强调背景的符号按钮，并绑定辅助功能标识与目标动作。
    private func configureProminentButton(
        _ button: UIButton,
        symbolName: String,
        color: UIColor,
        identifier: String,
        action: Selector
    ) {
        var configuration = UIButton.Configuration.prominentGlass()
        configuration.image = UIImage(
            systemName: symbolName,
            withConfiguration: UIImage.SymbolConfiguration(
                pointSize: 17,
                weight: .bold
            )
        )
        configuration.cornerStyle = .capsule
        configuration.baseForegroundColor = .white
        button.configuration = configuration
        button.cornerConfiguration = .capsule()
        button.tintColor = color
        button.accessibilityIdentifier = identifier
        button.addTarget(self, action: action, for: .touchUpInside)
    }

    /// 配置使用浅色强调背景的媒体控制按钮。
    private func configureTintedButton(
        _ button: UIButton,
        symbolName: String,
        color: UIColor,
        identifier: String,
        action: Selector
    ) {
        var configuration = UIButton.Configuration.tinted()
        configuration.image = UIImage(
            systemName: symbolName,
            withConfiguration: UIImage.SymbolConfiguration(
                pointSize: 13,
                weight: .bold
            )
        )
        configuration.contentInsets = .zero
        configuration.cornerStyle = .capsule
        configuration.baseForegroundColor = color
        configuration.baseBackgroundColor = color
        button.configuration = configuration
        button.accessibilityIdentifier = identifier
        button.addTarget(self, action: action, for: .touchUpInside)
    }

    /// 配置使用系统次级填充背景的媒体控制按钮。
    private func configureGrayButton(
        _ button: UIButton,
        symbolName: String,
        identifier: String,
        action: Selector
    ) {
        var configuration = UIButton.Configuration.gray()
        configuration.image = UIImage(
            systemName: symbolName,
            withConfiguration: UIImage.SymbolConfiguration(
                pointSize: 13,
                weight: .bold
            )
        )
        configuration.contentInsets = .zero
        configuration.cornerStyle = .capsule
        configuration.baseForegroundColor = .label
        button.configuration = configuration
        button.accessibilityIdentifier = identifier
        button.addTarget(self, action: action, for: .touchUpInside)
    }
}
