//
//  ChatViewController+Binding.swift
//  Demo
//

import Combine
import AppLocalization
import QuickLayout
import QuickLayoutKit
import UIKit
import QuickLook

/// 绑定会话状态与底部遮挡变化。
@available(iOS 26.0, *)
extension ChatViewController {

    /// 绑定视图模型更新，将新状态渲染到时间线并提交待转写的音频文件。
    func bindViewModel() {
        viewModel.bind { [weak self] state, reason in
            guard let self else { return }
            conversationView.render(state, reason: reason)
            audioTranscription.enqueue(state, locale: SpeechConfiguration.recognitionLocale(
                for: Localization.localizationController.currentLocale.locale
            ))
        }
    }

    /// 观察键盘事件，更新照片面板高度缓存并按遮挡协调结果决定是否跟随滚动。
    func observeKeyboard() {
        keyboardObserver.$context
            .dropFirst()
            .sink { [weak self] context in
                guard let self else { return }
                _ = bottomObstructionCoordinator.updateKeyboard(
                    context
                )
                // 已展示的面板保留原有档位；尤其不能在切回键盘的关闭动画中重算高度。
                // 更新下一次使用的缓存后，仍由协调器决定本次通知是否可驱动页面布局。
                photoController.updateKeyboardHeight(
                    bottomObstructionCoordinator.storedKeyboardContentHeight,
                    invalidatingPresentedDetent: !photoController.isPresented
                )
            }
            .store(in: &cancellables)
    }

    /// 绑定有效遮挡高度变化，按动画来源更新输入栏位置并保留历史消息阅读位置。
    func configureBottomObstruction() {
        bottomObstructionCoordinator.heightDidChange = { [weak self] height, context in
            guard let self else { return }
            conversationView.debugLogScroll("obstruction.changed", detail: "old=\(bottomObstruction) new=\(height) animationDuration=\(context?.animationDuration ?? 0)")
            conversationView.prepareForViewportChange()
            bottomObstruction = height
            setNeedsQuickLayout()
            let updates: () -> Void = { [weak self] in
                self?.layoutChatContent()
            }
            if let context, context.animationDuration > 0 {
                // 只有键盘通知携带动画目标；beginFromCurrentState 允许新通知接续正在进行的动画。
                UIView.animate(
                    withDuration: context.animationDuration,
                    delay: 0,
                    options: context.animationOptions.union(.beginFromCurrentState),
                    animations: updates
                )
            } else {
                // 显示链接提供的是当前呈现位置，必须立即布局，不能逐帧叠加新动画导致滞后。
                updates()
            }
        }
        bottomObstructionCoordinator.refreshGeometry()
    }

    /// 按当前应用语言生成媒体界面共用的文字集合。
    func makeMediaStrings() -> MediaStrings {
        MediaStrings(
            photo: Localization.text("imessage.attachment.photo"),
            itemsFormat: Localization.text("imessage.media.items"),
            image: Localization.text("imessage.media.image"),
            animatedImage: Localization.text(
                "imessage.media.animatedImage"
            ),
            video: Localization.text("imessage.media.video"),
            videoDurationFormat: Localization.text(
                "imessage.media.videoDuration"
            ),
            importing: Localization.text("imessage.media.importing"),
            remove: Localization.text("imessage.media.remove"),
            play: Localization.text("imessage.media.play"),
            openPreview: Localization.text("imessage.media.openPreview"),
            close: Localization.text("imessage.media.close"),
            firstItem: Localization.text("imessage.media.first"),
            lastItem: Localization.text("imessage.media.last"),
            positionFormat: Localization.text("imessage.media.position")
        )
    }

    /// 针对媒体操作失败呈现本地化的恢复信息。
    ///
    /// 权限失败包含前往“设置”的操作。其他失败均采用非破坏性处理，并完整保留当前
    /// 草稿。
    ///
    /// - Parameter failure: 媒体控制器报告的失败。
    func presentMediaFailure(_ failure: MediaFailure) {
        let messageKey: String = switch failure {
        case .microphonePermissionDenied:
            "imessage.error.microphonePermission"
        case .speechPermissionDenied:
            "imessage.error.speechPermission"
        case .recordingTooShort:
            "imessage.error.recordingTooShort"
        case .recordingFailed:
            "imessage.error.recordingFailed"
        case .playbackFailed:
            "imessage.error.playbackFailed"
        case .speechUnavailable:
            "imessage.error.speechUnavailable"
        case .speechFailed:
            "imessage.error.speechFailed"
        case .mediaImportFailed:
            "imessage.error.mediaImportFailed"
        case .mediaInvalid:
            "imessage.error.mediaInvalid"
        }
        let alert = UIAlertController(
            title: Localization.text("imessage.error.title"),
            message: Localization.text(messageKey),
            preferredStyle: .alert
        )
        let presenter = presentedViewController ?? self
        guard !(presenter is UIAlertController),
              presenter.presentedViewController == nil else { return }
        alert.addAction(
            UIAlertAction(
                title: Localization.text("imessage.action.ok"),
                style: .cancel
            )
        )
        if failure == .microphonePermissionDenied
            || failure == .speechPermissionDenied {
            alert.addAction(
                UIAlertAction(
                    title: Localization.text("imessage.action.settings"),
                    style: .default
                ) { [weak self] _ in
                    guard let url = URL(
                        string: UIApplication.openSettingsURLString
                    ) else { return }
                    self?.viewIfLoaded?.window?.windowScene?.open(url, options: nil, completionHandler: nil)
                }
            )
        }
        presenter.present(alert, animated: true)
    }
}
