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

#if DEBUG
@available(iOS 17.0, *)
#Preview("默认头像") { AccountAvatarView() }
#endif
