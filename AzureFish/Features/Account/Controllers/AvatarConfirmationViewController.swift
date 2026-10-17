import PhotosUI
import QuickLayoutKit
import QuickLayout
import UIKit

/// 正方形预览与提交使用同一 JPEG，上传失败保留预览供重试。
final class AvatarConfirmationViewController: AccountScreen {
    private let session: SessionCoordinator
    private let changed: () -> Void
    private let jpeg: Data
    private let valid: Bool
    private var submit: UIButton!
    private var task: Task<Void, Never>?
    private let feedback = UILabel()
    override var localizedTitleKey: String? { "account.design.changePhoto" }
    init(session: SessionCoordinator, image: UIImage?, changed: @escaping () -> Void) {
        self.session = session; self.changed = changed
        if let image, image.size.width > 0, image.size.height > 0 {
            let format = UIGraphicsImageRendererFormat(); format.scale = 1; format.opaque = true
            let cropped = UIGraphicsImageRenderer(size: CGSize(width: 512, height: 512), format: format).image { _ in
                UIColor.systemBackground.setFill(); UIRectFill(CGRect(x: 0, y: 0, width: 512, height: 512))
                let scale = max(512 / image.size.width, 512 / image.size.height)
                let size = CGSize(width: image.size.width * scale, height: image.size.height * scale)
                image.draw(in: CGRect(x: (512 - size.width) / 2, y: (512 - size.height) / 2, width: size.width, height: size.height))
            }
            jpeg = cropped.jpegData(compressionQuality: 0.75) ?? Data()
        } else { jpeg = Data() }
        valid = image == nil || (!jpeg.isEmpty && jpeg.count <= 256 * 1024)
        super.init(nibName: nil, bundle: nil)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func viewDidLoad() {
        super.viewDidLoad()
        let image = UIImageView(image: UIImage(data: jpeg) ?? UIImage(systemName: "person.crop.circle.fill"))
        image.contentMode = .scaleAspectFit; image.accessibilityLabel = Localization.text("account.avatar.preview")
        let preview = QuickLayoutView { image.resizable().frame(height: 240).frame(maxWidth: .infinity) }
        feedback.numberOfLines = 0; feedback.font = .preferredFont(forTextStyle: .body); feedback.adjustsFontForContentSizeCategory = true
        content = [preview, label("account.avatar.help", secondary: true), feedback]
        submit = button(jpeg.isEmpty ? "account.avatar.reset" : "account.avatar.use", primary: true) { [weak self] in self?.send() }
        actions = [submit]
        submit.isEnabled = valid
        if !valid { feedback.text = Localization.text("account.avatar.invalid") }
        navigationItem.leftBarButtonItem = UIBarButtonItem(title: Localization.text("account.design.cancel"), primaryAction: UIAction { [weak self] _ in self?.dismiss(animated: true) })
    }
    private func send() {
        guard task == nil else { return }
        submit.isEnabled = false; submit.configuration?.showsActivityIndicator = true
        navigationItem.leftBarButtonItem?.isEnabled = false; navigationController?.isModalInPresentation = true
        task = Task { [weak self] in
            guard let self else { return }
            defer { task = nil; submit.isEnabled = true; submit.configuration?.showsActivityIndicator = false; navigationItem.leftBarButtonItem?.isEnabled = true; navigationController?.isModalInPresentation = false }
            do { try await session.updateAvatar(jpeg); changed(); dismiss(animated: true) }
            catch { feedback.text = Localization.text(AccountFailure.key(for: error)); setNeedsQuickLayout() }
        }
    }
}

#if DEBUG
@available(iOS 17.0, *)
#Preview("默认头像确认") { AppNavigationController(rootViewController: AvatarConfirmationViewController(session: .configured(), image: nil, changed: {})) }
#endif
