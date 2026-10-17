import PhotosUI
import QuickLayoutKit
import QuickLayout
import UIKit

/// 选择器只负责取图，确认页独立提交头像，不改变资料文字草稿。
@MainActor
final class AvatarEditorCoordinator: NSObject, PHPickerViewControllerDelegate {
    private weak var host: UIViewController?
    private let session: SessionCoordinator
    private let changed: () -> Void
    init(host: UIViewController, session: SessionCoordinator, changed: @escaping () -> Void) {
        self.host = host; self.session = session; self.changed = changed
    }
    func choose(from source: UIView) {
        guard let host, host.presentedViewController == nil else { return }
        let menu = UIAlertController(title: Localization.text("account.design.changePhoto"), message: nil, preferredStyle: .actionSheet)
        menu.addAction(UIAlertAction(title: Localization.text("account.avatar.choose"), style: .default) { [weak self] _ in self?.pick() })
        if session.profile?.avatarID != nil {
            menu.addAction(UIAlertAction(title: Localization.text("account.avatar.reset"), style: .destructive) { [weak self] _ in self?.review(nil) })
        }
        menu.addAction(UIAlertAction(title: Localization.text("account.design.cancel"), style: .cancel))
        menu.popoverPresentationController?.sourceView = source
        menu.popoverPresentationController?.sourceRect = source.bounds
        host.present(menu, animated: true)
    }
    private func pick() {
        var configuration = PHPickerConfiguration(); configuration.filter = .images; configuration.selectionLimit = 1
        let picker = PHPickerViewController(configuration: configuration); picker.delegate = self
        host?.present(picker, animated: true)
    }
    func picker(_ picker: PHPickerViewController, didFinishPicking results: [PHPickerResult]) {
        picker.dismiss(animated: true) { [weak self] in
            guard let self, let provider = results.first?.itemProvider else { return }
            guard provider.canLoadObject(ofClass: UIImage.self) else { self.showError(); return }
            provider.loadObject(ofClass: UIImage.self) { [weak self] object, error in
                let image = object as? UIImage
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    guard error == nil, let image else { showError(); return }
                    review(image)
                }
            }
        }
    }
    private func review(_ image: UIImage?) {
        guard let host else { return }
        let page = AvatarConfirmationViewController(session: session, image: image, changed: changed)
        host.present(AppNavigationController(rootViewController: page), animated: true)
    }
    private func showError() {
        let alert = UIAlertController(title: Localization.text("account.avatar.invalid"), message: nil, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: Localization.text("account.design.done"), style: .default))
        host?.present(alert, animated: true)
    }
}
