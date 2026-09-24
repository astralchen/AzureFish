//
//  MediaMessageView+Rendering.swift
//  Demo
//

import AVKit
import ImageIO
import QuickLayout
import QuickLayoutKit
import UIKit

/// 更新界面内容与展示状态。
extension MediaMessageView {

    /// 为当前可见索引窗口匹配已有卡片，保留相同媒体身份并复用其他卡片。
    func bindCards() {
        guard let group, !group.items.isEmpty else { return }
        let visibleIndices = MediaStackPolicy.visibleIndices(
            frontIndex: frontMediaIndex,
            itemCount: group.items.count
        )
        var reusableCards = cards
        var orderedCards: [CardView] = []
        for index in visibleIndices {
            let item = group.items[index]
            let card: CardView
            if let existingIndex = reusableCards.firstIndex(where: {
                $0.represents(
                    messageID: messageID,
                    groupID: group.id,
                    itemID: item.id
                )
            }) {
                card = reusableCards.remove(at: existingIndex)
            } else {
                // 返回上一窗口时，新首项不能抢走后续仍需保留的卡片身份。
                let spareIndex = reusableCards.firstIndex { candidate in
                    !visibleIndices.contains { requiredIndex in
                        candidate.represents(
                            messageID: messageID, groupID: group.id,
                            itemID: group.items[requiredIndex].id
                        )
                    }
                }!
                card = reusableCards.remove(at: spareIndex)
            }
            orderedCards.append(card)
            card.isHidden = false
            // 可复用卡片拥有自己的 QuickLayout 环境，显式同步消息的有效方向。
            card.semanticContentAttribute = effectiveUserInterfaceLayoutDirection == .rightToLeft
                ? .forceRightToLeft : .forceLeftToRight
            card.configure(
                item,
                index: index,
                identity: CardView.BindingIdentity(
                    messageID: messageID,
                    groupID: group.id,
                    itemID: item.id,
                    frontIndex: frontMediaIndex
                ),
                badgeLeadingInset: 12 + (group.items.count == 1 && direction == .incoming ? Metrics.singleTailWidth : 0)
            )
            card.layer.zPosition = CGFloat(30 - abs(index - frontMediaIndex))
            card.alpha = 1
        }
        cards = orderedCards + reusableCards
        reusableCards.forEach { $0.reset(); $0.isHidden = true }
    }

    /// 将卡片池增减到所需数量，并清理移出窗口的多余卡片。
    func ensureCardCount(_ count: Int) {
        while cards.count < count {
            let card = CardView()
            cards.append(card)
        }
        while cards.count > count {
            let card = cards.removeLast()
            card.reset()
        }
    }

    /// 按封面位置计算 QuickLayout 使用的静止边框，并更新旋转和层级。
    func updateCardGeometry() {
        guard let group, !group.items.isEmpty else { return }
        let isGroup = group.items.count > 1
        let isRTL = effectiveUserInterfaceLayoutDirection == .rightToLeft
        let outwardSign: CGFloat = direction == .outgoing
            ? (isRTL ? -1 : 1)
            : (isRTL ? 1 : -1)

        if isGroup {
            let cardY = Metrics.titleHeight + Metrics.titleSpacing
            let scale = min(1, bounds.width / max(1, resolvedSize.width))
            let visibleIndices = MediaStackPolicy.visibleIndices(
                frontIndex: frontMediaIndex,
                itemCount: group.items.count
            )
            for card in cards where !card.isHidden {
                // 收尾阶段仍保留原窗口；离开窗口的卡片也连续移动到新封面背后。
                let position = card.mediaIndex - (visibleIndices.first ?? 0)
                let visualPosition = outwardSign > 0
                    ? position
                    : visibleIndices.count - position - 1
                let depth = abs(card.mediaIndex - frontMediaIndex)
                let relativeDirection = CGFloat(
                    card.mediaIndex == frontMediaIndex
                        ? 0
                        : card.mediaIndex > frontMediaIndex ? 1 : -1
                )
                let physicalSide = relativeDirection * outwardSign
                let rotationAngle = -physicalSide * Metrics.groupRotationAngle(depth: depth)
                card.mask = nil
                card.layer.cornerRadius = Metrics.cornerRadius
                let restingFrame = CGRect(
                    x: CGFloat(visualPosition) * Metrics.groupOffset.x * scale,
                    y: cardY + CGFloat(depth) * Metrics.groupOffset.y * scale,
                    width: Metrics.groupCardSize.width * scale,
                    height: Metrics.groupCardSize.height * scale
                )
                card.restingFrame = restingFrame
                card.restingTransform = CGAffineTransform(
                    rotationAngle: rotationAngle
                )
                card.transform = card.restingTransform
                card.layer.zPosition = CGFloat(30 - depth)
            }
        } else {
            let card = cards[0]
            // 单张媒体由完整气泡遮罩裁剪，卡片圆角不能再次截断尾巴。
            card.layer.cornerRadius = 0
            card.transform = .identity
            card.restingFrame = bounds
            card.restingTransform = .identity
        }
    }

    /// 在卡片完成布局后，将单图轮廓交给框架形状视图生成。
    func updateSingleMask() {
        guard group?.items.count == 1, let card = cards.first else { return }
        let isRTL = effectiveUserInterfaceLayoutDirection == .rightToLeft
        let tailOnRight = direction == .outgoing ? !isRTL : isRTL
        card.mask = singleMaskView
        singleMaskView.frame = card.bounds
        singleMaskView.shape = QuickLayoutAnyShape { rect in
            Self.bubblePath(in: rect, tailOnRight: tailOnRight)
        }
        singleMaskView.layoutIfNeeded()
    }

    /// 长按沿用单张气泡的完整尾部轮廓，媒体组则使用前卡片的圆角。
    ///
    /// 路径位于当前 `previewSourceView` 的 bounds 坐标空间，尾部方向同时考虑消息方向与 RTL。
    /// 无法取得当前来源卡片时返回 `nil`；窗口、可见性与目标身份由菜单协调对象另行校验。
    var menuPreviewPath: UIBezierPath? {
        guard let card = previewSourceView else { return nil }
        guard group?.items.count == 1 else {
            return UIBezierPath(roundedRect: card.bounds, cornerRadius: Metrics.cornerRadius)
        }
        let isRTL = effectiveUserInterfaceLayoutDirection == .rightToLeft
        let tailOnRight = direction == .outgoing ? !isRTL : isRTL
        return UIBezierPath(cgPath: Self.bubblePath(in: card.bounds, tailOnRight: tailOnRight))
    }

    /// 根据当前封面的媒体类型与时长更新辅助功能描述。
    func updateAccessibilityLabel() {
        guard let group, let strings, !group.items.isEmpty else { return }
        let item = group.items[frontMediaIndex]
        let kind = item.isLivePhoto ? Localization.text("imessage.media.livePhoto") : (item.kind.isVideo ? strings.video : strings.image)
        if group.items.count == 1 {
            accessibilityLabel = kind
        } else {
            accessibilityLabel = "\(String(format: strings.itemsFormat, group.items.count)), \(kind)"
        }
    }

    /// 根据媒体数量和原始宽高比返回单图气泡或堆叠视图的尺寸。
    static func size(for group: MediaGroupAttachment) -> CGSize {
        guard group.items.count == 1, let item = group.items.first else {
            let backCardCount = min(
                group.items.count,
                MediaStackPolicy.maximumVisibleCardCount
            ) - 1
            let angle = Metrics.groupRotationAngle(depth: max(0, backCardCount))
            let rotatedHeight = Metrics.groupCardSize.width * sin(angle)
                + Metrics.groupCardSize.height * cos(angle)
            // 保持封面与卡片偏移不变，只为旋转后向下伸出的边缘预留真实高度。
            // 按整个可见窗口的最大深度测量，切换封面时消息行不会跟着变高变矮。
            let bottomOverflow = ceil(max(0, (rotatedHeight - Metrics.groupCardSize.height) / 2))
            return CGSize(
                width: Metrics.groupCardSize.width
                    + Metrics.groupOffset.x * CGFloat(backCardCount),
                height: Metrics.titleHeight + Metrics.titleSpacing
                    + Metrics.groupCardSize.height
                    + Metrics.groupOffset.y * CGFloat(backCardCount)
                    + bottomOverflow
            )
        }
        let rawRatio = item.pixelSize.width / max(1, item.pixelSize.height)
        let ratio = min(1.55, max(0.70, rawRatio))
        var width = Metrics.singleMaximumWidth
        var height = width / ratio
        if height > Metrics.singleMaximumHeight {
            height = Metrics.singleMaximumHeight
            width = max(Metrics.singleMinimumEdge, height * ratio)
        }
        return CGSize(width: ceil(width), height: ceil(height))
    }

    /// 当前显示在堆叠最前方、响应拖动的卡片视图。
    var frontCard: CardView? {
        cards.first { !$0.isHidden && $0.mediaIndex == frontMediaIndex }
    }

    /// 返回指定区域的媒体气泡轮廓，并按物理方向选择尾部位置。
    nonisolated private static func bubblePath(in rect: CGRect, tailOnRight: Bool) -> CGPath {
        guard rect.width > 0, rect.height > 0 else { return CGMutablePath() }
        let width = rect.width
        let height = rect.height
        let scale = min(1, width / (Metrics.singleTailWidth + 2 * Metrics.cornerRadius),
                        height / (2 * Metrics.cornerRadius))
        let tail = Metrics.singleTailWidth * scale
        let radius = Metrics.cornerRadius * scale
        let path = UIBezierPath()

        // 主体与尾巴沿同一条闭合轮廓绘制，避免叠加子路径的绕向抵消填充。
        // 先绘制左尾气泡，再镜像整个轮廓，保证收发与 RTL 使用完全一致的几何。
        path.move(to: CGPoint(x: tail + radius, y: 0))
        path.addLine(to: CGPoint(x: width - radius, y: 0))
        path.addArc(withCenter: CGPoint(x: width - radius, y: radius),
                    radius: radius, startAngle: -.pi / 2, endAngle: 0, clockwise: true)
        path.addLine(to: CGPoint(x: width, y: height - radius))
        path.addArc(withCenter: CGPoint(x: width - radius, y: height - radius),
                    radius: radius, startAngle: 0, endAngle: .pi / 2, clockwise: true)
        path.addLine(to: CGPoint(x: tail + radius, y: height))
        path.addCurve(
            to: CGPoint(x: tail + 10 * scale, y: height - 6 * scale),
            controlPoint1: CGPoint(x: tail + 16 * scale, y: height),
            controlPoint2: CGPoint(x: tail + 13 * scale, y: height - 2 * scale)
        )
        path.addCurve(
            to: CGPoint(x: 0, y: height - 2 * scale),
            controlPoint1: CGPoint(x: 15 * scale, y: height),
            controlPoint2: CGPoint(x: 7 * scale, y: height)
        )
        path.addCurve(
            to: CGPoint(x: tail, y: height - radius),
            controlPoint1: CGPoint(x: 10 * scale, y: height - 9 * scale),
            controlPoint2: CGPoint(x: tail, y: height - 13 * scale)
        )
        path.addLine(to: CGPoint(x: tail, y: radius))
        path.addArc(withCenter: CGPoint(x: tail + radius, y: radius),
                    radius: radius, startAngle: .pi, endAngle: .pi * 1.5, clockwise: true)
        path.close()
        if tailOnRight {
            path.apply(CGAffineTransform(a: -1, b: 0, c: 0, d: 1, tx: width, ty: 0))
        }
        path.apply(CGAffineTransform(translationX: rect.minX, y: rect.minY))
        return path.cgPath
    }
}
