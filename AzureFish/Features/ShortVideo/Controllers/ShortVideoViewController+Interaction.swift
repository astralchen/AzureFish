import AVFoundation
import AzureFishAPI
import UIKit

/// 将控件操作路由到业务模型或系统呈现，并协调播放暂停。
extension ShortVideoViewController {
    func refreshCurrent() { viewModel.refreshCurrent() }
    @objc func doubleTapLike() {
        guard current?.liked == false else { return }
        viewModel.setLike()
    }
    func likeVideo() { viewModel.setLike() }
    func obscure() {
        state.obscured = true
        if player != nil {
            // 底部面板覆盖时保留当前帧与租约；后台、切页和账号退出仍走完整释放路径。
            loadTask?.cancel(); loadTask = nil; player?.pause(); feedView.loading.stopAnimating()
            audioReady = false
            if audioActive { audio.deactivate(); audioActive = false }
        } else { unload() }
    }
    func revealed() { state.obscured = false; restorePlayback(); refreshCurrent() }
    func openComments() {
        guard let item = current else { return }; obscure()
        let model = commentModels[item.id] ?? ShortVideoCommentsViewModel(runtime: runtime, video: item.id)
        commentModels[item.id] = model
        let page = ShortVideoCommentsViewController(viewModel: model)
        page.commentCount = item.commentCount
        model.changed = { [weak self, weak page] item in
            self?.viewModel.update(item); page?.commentCount = item.commentCount
        }
        page.closed = { [weak self] in self?.revealed() }
        let navigation = AppNavigationController(rootViewController: page)
        if let sheet = navigation.sheetPresentationController { sheet.detents = [.medium(), .large()]; sheet.prefersGrabberVisible = true; sheet.preferredCornerRadius = 16 }
        present(navigation, animated: true); navigation.presentationController?.delegate = self
    }
    func shareVideo() {
        guard let item = current, let url = URL(string: item.sourceURL) else { return }; obscure()
        let controller = UIActivityViewController(activityItems: [url], applicationActivities: nil)
        controller.popoverPresentationController?.sourceView = controlsView.share; controller.popoverPresentationController?.sourceRect = controlsView.share.bounds
        controller.completionWithItemsHandler = { [weak self] _, _, _, _ in Task { @MainActor in self?.revealed() } }
        present(controller, animated: true)
    }
    func showInformation() {
        obscure()
        let alert = UIAlertController(title: Localization.text("shortVideo.about"),
            message: Localization.text("shortVideo.aboutDescription"), preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: Localization.text("common.close"), style: .cancel) { [weak self] _ in self?.revealed() })
        present(alert, animated: true)
    }
    func openSource() {
        guard let item = current, let url = URL(string: item.sourceURL) else { return }
        state.paused = true; unload(); render(); UIApplication.shared.open(url)
    }
    func presentationControllerDidDismiss(_ presentationController: UIPresentationController) { revealed() }
}
