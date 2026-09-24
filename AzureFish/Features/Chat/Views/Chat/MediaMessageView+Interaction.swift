//
//  MediaMessageView+Interaction.swift
//  Demo
//

import AVKit
import ImageIO
import QuickLayout
import QuickLayoutKit
import UIKit

/// 处理用户操作与组件事件。
extension MediaMessageView {

    /// 按卡片真实局部坐标命中媒体；拖动和收尾期间不打开预览。
    @objc func handleTap(_ gesture: UITapGestureRecognizer) {
        guard gesture.state == .ended, let group,
              !isAnimating, interaction == nil else { return }
        let location = gesture.location(in: self)
        let hitsTitle = hasMultipleItems
            && (itemCountLabel.frame.contains(location) || itemCountIcon.frame.contains(location))
        guard let index = mediaIndex(at: location) ?? (hitsTitle ? frontMediaIndex : nil) else { return }
        previewRequested?(messageID, group, index)
    }

    /// 返回指定位置最上方的实际卡片，不使用旋转后的外接矩形命中。
    func mediaIndex(at location: CGPoint) -> Int? {
        guard !isAnimating, interaction == nil else { return nil }
        return cards.sorted { $0.layer.zPosition > $1.layer.zPosition }
            .first { !$0.isHidden && $0.point(inside: $0.convert(location, from: self), with: nil) }?
            .mediaIndex
    }

    /// 将系统手势生命周期传入可测试的同一条交互路径。
    @objc func handlePan(_ gesture: UIPanGestureRecognizer) {
        handlePan(
            state: gesture.state,
            translationX: gesture.translation(in: self).x,
            velocityX: gesture.velocity(in: self).x
        )
    }

    /// 更新临时展示；仅正常松手允许确认索引，系统取消始终恢复原位。
    func handlePan(
        state: UIGestureRecognizer.State,
        translationX: CGFloat,
        velocityX: CGFloat,
        animated: Bool = true
    ) {
        guard let group, group.items.count > 1, !isAnimating else { return }
        switch state {
        case .began:
            guard interaction == nil else { return }
            layoutIfNeeded()
            guard let frontCard, frontCard.bounds.width > 0 else { return }
            interaction = .init(
                startIndex: frontMediaIndex, itemCount: group.items.count,
                cardWidth: frontCard.bounds.width
            )
            interaction?.update(translationX: translationX)
            applyInteraction()
        case .changed:
            guard interaction != nil else { return }
            interaction?.update(translationX: translationX)
            applyInteraction()
        case .ended:
            guard interaction != nil else { return }
            interaction?.update(translationX: translationX)
            applyInteraction()
            let targetIndex = interaction?.committedIndex(velocityX: velocityX)
            settle(to: targetIndex, animated: animated, velocityX: velocityX)
        case .cancelled, .failed:
            guard interaction != nil else { return }
            settle(to: nil, animated: animated)
        default:
            break
        }
    }

    /// 从静止姿态重建可逆预览；不会重新绑定媒体或发布封面变化。
    func applyInteraction() {
        guard let interaction,
              let movingCard = cards.first(where: { $0.mediaIndex == interaction.startIndex && !$0.isHidden })
        else { return }
        for card in cards where !card.isHidden {
            card.center = CGPoint(x: card.restingFrame.midX, y: card.restingFrame.midY)
            card.transform = card.restingTransform
            card.layer.zPosition = CGFloat(30 - abs(card.mediaIndex - interaction.startIndex))
        }
        let progress = interaction.progress
        let reducedMotion = UIAccessibility.isReduceMotionEnabled
        let scale = reducedMotion ? 1 : 1 - 0.28 * progress
        let angle = reducedMotion ? 0 : (interaction.translationX < 0 ? -1.0 : 1.0) * 10 * progress * .pi / 180
        movingCard.center.x += interaction.displayedTranslationX
        movingCard.transform = CGAffineTransform(rotationAngle: angle).scaledBy(x: scale, y: scale)
        guard let candidate = cards.first(where: {
            $0.mediaIndex == interaction.candidateIndex && !$0.isHidden
        }) else { return }
        let restingAngle = atan2(candidate.restingTransform.b, candidate.restingTransform.a)
        candidate.transform = CGAffineTransform(rotationAngle: reducedMotion ? 0 : restingAngle * (1 - progress))
        candidate.center.y += (movingCard.restingFrame.midY - candidate.restingFrame.midY) * progress
        candidate.layer.zPosition = interaction.isReordered ? 31 : 29
    }

    /// 通过辅助功能请求相邻封面；交互过程中不接受重复切换。
    func move(to index: Int, animated: Bool) {
        guard let group, interaction == nil, !isAnimating else { return }
        guard group.items.indices.contains(index) else {
            let announcement = index < 0 ? strings?.firstItem : strings?.lastItem
            if let announcement {
                UIAccessibility.post(notification: .announcement, argument: announcement)
            }
            return
        }
        guard index != frontMediaIndex else { return }
        settle(to: index, animated: animated)
    }

    /// 从当前姿态连续收拢，并在收尾后整理可见窗口；提交回调在动画前仅发出一次。
    private func settle(to targetIndex: Int?, animated: Bool, velocityX: CGFloat = 0) {
        guard let group else { return }
        let bindingMessageID = messageID
        let cardWidth = interaction?.cardWidth ?? frontCard?.bounds.width ?? 1
        interaction = nil
        isAnimating = true
        transitionGeneration &+= 1
        let generation = transitionGeneration
        if let targetIndex {
            frontMediaIndex = targetIndex
            updateAccessibilityPosition()
            frontIndexDidChange?(bindingMessageID, targetIndex)
        }
        // 回调可能同步触发列表刷新、复用或再次配置，必须在继续动画前重验身份。
        guard generation == transitionGeneration, messageID == bindingMessageID, self.group == group else { return }
        let completion: (Bool) -> Void = { [weak self] _ in
            guard let self, self.transitionGeneration == generation,
                  self.messageID == bindingMessageID, self.group == group else { return }
            self.isAnimating = false
            self.bindCards()
            self.layoutCards()
            if targetIndex != nil { self.announcePosition(in: group) }
        }
        let changes = { [weak self] in self?.layoutCards() }
        guard animated else {
            changes()
            completion(true)
            return
        }
        if UIAccessibility.isReduceMotionEnabled {
            UIView.animate(withDuration: 0.16, animations: { changes() }, completion: completion)
        } else {
            UIView.animate(
                withDuration: targetIndex == nil ? 0.22 : 0.28,
                delay: 0,
                usingSpringWithDamping: targetIndex == nil ? 0.78 : 0.86,
                initialSpringVelocity: min(8, abs(velocityX) / max(1, cardWidth)),
                options: [.beginFromCurrentState, .allowUserInteraction],
                animations: { changes() }, completion: completion
            )
        }
    }

    /// 取消交互并使旧动画回调失效；已在松手时确认的索引不会回退。
    func invalidateInteraction() {
        transitionGeneration &+= 1
        interaction = nil
        isAnimating = false
        cards.forEach { $0.layer.removeAllAnimations() }
        if panGesture.state == .began || panGesture.state == .changed {
            panGesture.isEnabled = false
            panGesture.isEnabled = (group?.items.count ?? 0) > 1
        }
    }

    /// 同步已确认封面的辅助功能类型和位置，预览换层不调用此方法。
    private func updateAccessibilityPosition() {
        updateAccessibilityLabel()
        accessibilityValue = String(
            format: strings?.positionFormat ?? "%d/%d",
            frontMediaIndex + 1,
            group?.items.count ?? 0
        )
    }

    /// 有效提交收尾后给出一次触觉和辅助功能反馈；不再次发布索引。
    private func announcePosition(in group: MediaGroupAttachment) {
        UISelectionFeedbackGenerator().selectionChanged()
        let kind = group.items[frontMediaIndex].kind.isVideo ? strings?.video : strings?.image
        UIAccessibility.post(
            notification: .announcement,
            argument: [accessibilityValue, kind].compactMap { $0 }.joined(separator: ", ")
        )
    }
}
