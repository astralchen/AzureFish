import AppLocalization
import AzureFishAPI
import AzureFishMoments
import ListKit
import QuickLayout
import QuickLayoutKit
import UIKit

/// 相册页头快照及封面操作回调；回调携带实际封面按钮供弹出菜单锚定。
struct MomentsHeaderConfiguration: UIContentConfiguration {
    let album: MomentsAlbum
    let media: MomentsMediaProvider
    let open: (UIView) -> Void
    func makeContentView() -> UIView & UIContentView { MomentsHeaderView(configuration: self) }
    func updated(for state: UIConfigurationState) -> Self { self }
}
/// 展示封面、头像和所有者名称，仅允许当前账号操作自己的封面入口。
final class MomentsHeaderView: QuickLayoutContentView {
    private let cover = UIButton(type: .custom)
    private let name = UILabel()
    private let avatar = AccountAvatarView()
    private let imageBinding = MomentsImageBinding()
    override init(configuration: UIContentConfiguration) {
        super.init(configuration: configuration)
        cover.backgroundColor = .secondarySystemFill; cover.clipsToBounds = true; cover.imageView?.contentMode = .scaleAspectFill
        cover.setImage(UIImage(systemName: "mountain.2"), for: .normal)
        name.font = .preferredFont(forTextStyle: .title2); name.adjustsFontForContentSizeCategory = true; name.numberOfLines = 0
        applyCurrentContentConfiguration()
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override var body: Layout {
        VStack(alignment: .leading, spacing: 12) {
            cover.resizable().frame(height: 220).frame(maxWidth: .infinity)
            HStack(spacing: 12) { name.resizable(axis: .horizontal).frame(maxWidth: .infinity); avatar.resizable().frame(width: 56, height: 56) }.padding(.horizontal, 20)
        }.padding(.bottom, 20)
    }
    override func applyContentConfiguration(_ configuration: UIContentConfiguration) {
        guard let config = configuration as? MomentsHeaderConfiguration else { return }
        name.text = config.album.owner.nickname
        config.media.configure(avatar, user: config.album.owner)
        cover.isEnabled = config.album.owner.id == config.media.userID
        cover.accessibilityLabel = Localization.text("moments.cover"); cover.accessibilityIdentifier = "moments.cover"
        cover.removeAction(identifiedBy: .init("cover"), for: .touchUpInside)
        cover.addAction(UIAction(identifier: .init("cover")) { [weak self] _ in if let self { config.open(self.cover) } }, for: .touchUpInside)
        config.media.bind(imageBinding, to: cover, asset: config.album.cover, target: config.album.owner.id, cover: true)
        setNeedsQuickLayout()
    }
}

#if DEBUG
@available(iOS 17.0, *)
#Preview("朋友圈封面") {
    MomentsHeaderView(configuration: MomentsHeaderConfiguration(album: .init(owner: MomentsPreviewData.user), media: MomentsMediaProvider(runtime: MomentsPreviewData.runtime()), open: { _ in }))
}
#endif
