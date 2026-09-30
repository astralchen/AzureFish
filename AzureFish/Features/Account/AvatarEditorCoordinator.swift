import PhotosUI
import QuickLayoutKit
import QuickLayout
import UIKit

/// 头像视图按资源身份过滤复用后的迟到响应，用户图片不随 RTL 镜像。
final class AccountAvatarView: UIImageView {
    private var loading: Task<Void, Never>?
    private var identity: String?
    private var scope: AccountAvatarLoader.Scope?
    private var invalidation: NSObjectProtocol?
    init() {
        super.init(image: UIImage(systemName: "person.crop.circle.fill"))
        contentMode = .scaleAspectFill; clipsToBounds = true
        invalidation = NotificationCenter.default.addObserver(forName: .accountAvatarsInvalidated, object: nil, queue: .main) { [weak self] note in
            let scope = note.userInfo?["scope"] as? AccountAvatarLoader.Scope
            MainActor.assumeIsolated { if self?.scope == scope { self?.reset() } }
        }
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func layoutSubviews() { super.layoutSubviews(); layer.cornerRadius = min(bounds.width, bounds.height) / 2 }
    func reset() {
        identity = nil; scope = nil; loading?.cancel(); loading = nil
        image = UIImage(systemName: "person.crop.circle.fill")
    }
    func configure(session: SessionCoordinator, user: UUID, asset: String?) {
        accessibilityLabel = Localization.text(asset == nil ? "account.default.avatar" : "account.avatar.preview")
        let id = user.uuidString + ":" + (asset ?? "default")
        let scope = session.avatarScope
        guard id != identity || self.scope != scope else { return }
        reset(); identity = id; self.scope = scope
        guard let asset, scope != nil else { return }
        if let cached = session.cachedAvatar(user: user, asset: asset) { image = cached; return }
        loading = Task { [weak self] in
            do {
                let image = try await session.avatar(user: user, asset: asset)
                guard !Task.isCancelled, self?.identity == id, self?.scope == scope else { return }
                guard let image else { self?.identity = nil; return }
                self?.image = image
            } catch {
                // 保留默认图，允许资料刷新或重连后的下一次配置重试。
                if !Task.isCancelled, self?.identity == id, self?.scope == scope { self?.identity = nil }
            }
        }
    }
    isolated deinit {
        loading?.cancel()
        if let invalidation { NotificationCenter.default.removeObserver(invalidation) }
    }
}

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
@available(iOS 17.0, *)
#Preview("默认头像") { AccountAvatarView() }
#endif
