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

extension MomentsComposerViewController {
    /// 连接状态渲染与页面导航，媒体选择等系统呈现仍由控制器处理。
    func bind() {
        viewModel.render = { [weak self] _ in self?.updateControls() }
        viewModel.didFinish = { [weak self] in self?.dismiss(animated: true) }
        composerView.action = { [weak self] action in
            guard let self else { return }
            switch action {
            case .chooseMedia: chooseMedia()
            case .editVideo: editVideo()
            case .playVideo:
                if let video = draft.video { present(MomentsVideoViewController(runtime: runtime, local: video), animated: true) }
            case .close: close()
            default: viewModel.handle(action)
            }
        }
    }
    func updateControls() {
        composerView.apply(viewModel.state)
        navigationItem.rightBarButtonItem?.title = Localization.text(draft.publication == nil ? "moments.publish" : "moments.retry")
        navigationItem.rightBarButtonItem?.isEnabled = viewModel.state.canPublish
        navigationItem.leftBarButtonItem?.isEnabled = !busy
    }
}
