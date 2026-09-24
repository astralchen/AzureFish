//
//  MediaMessageView+CardView.swift
//  Demo
//

import AVKit
import ImageIO
import QuickLayout
import QuickLayoutKit
import UIKit

/// 定义媒体堆叠使用的内部卡片视图。
extension MediaMessageView {

    /// 持有单个媒体缩略图并校验异步加载身份的可复用卡片。
    final class CardView: QuickLayoutView {
        /// 绑定消息、媒体组、项目及封面位置的图像加载身份。
        struct BindingIdentity: Equatable, Sendable {
            /// 卡片当前所属消息的稳定标识符。
            let messageID: Int
            /// 卡片当前所属媒体组的稳定标识符。
            let groupID: UUID
            /// 卡片当前显示的媒体项目标识符。
            let itemID: UUID
            /// 本次绑定时的媒体组封面索引。
            let frontIndex: Int
        }

        /// 显示当前媒体图像的图像视图。
        let imageView = MediaImageView()
        /// 实况照片的纯白色系统标志，作为照片内容上的装饰，不单独截获手势。
        let livePhotoBadge = UIImageView(image: UIImage(systemName: "livephoto"))
        private var badgeLeadingInset: CGFloat = 12
        /// 视频播放符号背后的模糊材质容器。
        lazy var playBackground = QuickLayoutVisualEffectView(
            effect: UIBlurEffect(style: .systemUltraThinMaterialLight)
        ) { [playImageView] in
            playImageView.resizable().frame(width: 18, height: 22)
        }
        /// 覆盖在视频缩略图上的播放符号。
        let playImageView = UIImageView(image: UIImage(systemName: "play.fill"))
        /// 卡片对应媒体项目在原始附件数组中的索引。
        var mediaIndex = 0
        /// 卡片结束拖动后恢复的基准边框。
        var restingFrame: CGRect = .zero
        /// 卡片结束拖动后恢复的堆叠变换。
        var restingTransform: CGAffineTransform = .identity
        /// 当前缩略图加载绑定的完整身份，用于丢弃旧请求结果。
        private var representedIdentity: BindingIdentity?
        /// 当前媒体是否需要显示视频播放标记。
        private var isVideo = false

        /// 缩略图填满卡片，视频播放标记居中，实况标志固定在顶部前缘。
        override var body: Layout {
            ZStack {
                imageView.resizable()
                if isVideo {
                    playBackground.resizable().frame(width: 48, height: 48)
                }
                if !livePhotoBadge.isHidden {
                    livePhotoBadge.resizable().frame(width: 18, height: 18)
                        .padding(.leading, badgeLeadingInset).padding(.top, 12)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                }
            }
        }

        /// 返回卡片是否仍绑定指定消息、媒体组与媒体项目。
        func represents(
            messageID: Int,
            groupID: UUID,
            itemID: UUID
        ) -> Bool {
            representedIdentity?.messageID == messageID
                && representedIdentity?.groupID == groupID
                && representedIdentity?.itemID == itemID
        }

        /// 使用指定初始边框创建 `CardView`，并配置其子视图和默认外观。
        ///
        /// - Parameter frame: 在父视图坐标系中指定的初始边框。
        override init(frame: CGRect = .zero) {
            super.init(frame: frame)
            clipsToBounds = true
            layer.cornerRadius = Metrics.cornerRadius
            layer.cornerCurve = .continuous
            backgroundColor = .secondarySystemFill
            imageView.contentMode = .scaleAspectFill
            imageView.clipsToBounds = true
            livePhotoBadge.isHidden = true
            livePhotoBadge.contentMode = .scaleAspectFit
            livePhotoBadge.tintColor = .white
            livePhotoBadge.isUserInteractionEnabled = false
            livePhotoBadge.isAccessibilityElement = false
            livePhotoBadge.layer.shadowColor = UIColor.black.cgColor
            livePhotoBadge.layer.shadowOpacity = 0.35
            livePhotoBadge.layer.shadowRadius = 2
            livePhotoBadge.layer.shadowOffset = .zero
            playBackground.clipsToBounds = true
            playBackground.layer.cornerRadius = 24
            playImageView.tintColor = .label
            playImageView.contentMode = .scaleAspectFit
        }

        /// 不支持从归档创建 `CardView`。
        ///
        /// 请使用代码初始化方法创建此对象。
        required init?(coder: NSCoder) {
            fatalError("init(coder:) has not been implemented")
        }

        /// 绑定媒体项目及完整加载身份，并在异步图像返回时校验身份后显示。
        func configure(
            _ item: MediaItem,
            index: Int,
            identity: BindingIdentity,
            badgeLeadingInset: CGFloat = 12
        ) {
            let keepsCurrentImage = represents(
                messageID: identity.messageID,
                groupID: identity.groupID,
                itemID: identity.itemID
            )
            mediaIndex = index
            representedIdentity = identity
            if !keepsCurrentImage { imageView.setThumbnail(nil) }
            isVideo = item.kind.isVideo
            livePhotoBadge.isHidden = !item.isLivePhoto
            self.badgeLeadingInset = badgeLeadingInset
            imageView.setThumbnail(item.thumbnailFileURL)
            setNeedsQuickLayout()
        }

        /// 取消图像任务并清空绑定内容、动画及复用状态。
        func reset() {
            imageView.setThumbnail(nil)
            representedIdentity = nil
            imageView.image = nil
            isVideo = false
            livePhotoBadge.isHidden = true
            badgeLeadingInset = 12
            mask = nil
            restingFrame = .zero
            restingTransform = .identity
            transform = .identity
            alpha = 1
            layer.zPosition = 0
            setNeedsQuickLayout()
        }
    }
}
