import AVFoundation
import QuickLayout
import QuickLayoutKit
import UIKit

/// 单页视频画布；AVPlayerLayer 的精确几何随 contentView 的本地 bounds 更新。
final class ShortVideoCell: UICollectionViewCell {
    let poster = UIImageView()
    let playerLayer = AVPlayerLayer()
    override init(frame: CGRect) {
        super.init(frame: frame)
        contentView.backgroundColor = .black
        poster.contentMode = .scaleAspectFit
        contentView.addSubview(poster); contentView.layer.addSublayer(playerLayer)
        playerLayer.videoGravity = .resizeAspect
        isAccessibilityElement = false
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func layoutSubviews() {
        super.layoutSubviews()
        // 播放器 layer 与封面必须逐像素共用同一个画布，不参与文字排版。
        poster.frame = contentView.bounds
        CATransaction.begin(); CATransaction.setDisableActions(true); playerLayer.frame = contentView.bounds; CATransaction.commit()
    }
    override func prepareForReuse() { super.prepareForReuse(); playerLayer.player = nil; poster.image = nil }
}
#if DEBUG
@available(iOS 17.0, *)
#Preview("短视频画布") { ShortVideoCell(frame: CGRect(x: 0, y: 0, width: 320, height: 560)) }
#endif
