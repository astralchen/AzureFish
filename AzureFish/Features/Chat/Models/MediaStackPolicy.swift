//
//  MediaStackPolicy.swift
//  Demo
//

import Foundation
import CoreGraphics

/// 层叠媒体的纯展示算法。所有结果都只基于索引计算，不改变附件数组。
nonisolated enum MediaStackPolicy {
    /// 媒体堆叠同时保留的最大卡片数量。
    static let maximumVisibleCardCount = 5

    /// 返回从当前封面开始、再接回集合起点的完整媒体索引顺序。
    static func renderOrder(frontIndex: Int, itemCount: Int) -> [Int] {
        guard itemCount > 0 else { return [] }
        let front = min(max(0, frontIndex), itemCount - 1)
        return Array(front..<itemCount) + Array(0..<front)
    }

    /// 返回围绕当前封面的连续可见窗口。
    ///
    /// 窗口最多保留五项：中间位置优先在当前项两侧各保留两项；接近首尾时，
    /// 空出来的名额让给另一侧。结果始终按原始媒体索引递增，不改变附件顺序。
    static func visibleIndices(frontIndex: Int, itemCount: Int) -> [Int] {
        guard itemCount > 0 else { return [] }
        let front = min(max(0, frontIndex), itemCount - 1)
        let visibleCount = min(maximumVisibleCardCount, itemCount)
        var lowerBound = max(0, front - visibleCount / 2)
        var upperBound = min(itemCount, lowerBound + visibleCount)
        lowerBound = max(0, upperBound - visibleCount)
        upperBound = min(itemCount, lowerBound + visibleCount)
        return Array(lowerBound..<upperBound)
    }

    /// 返回手势速度是否以水平方向为主，用于避免抢占时间线纵向滚动。
    static func isHorizontalPan(velocity: CGPoint) -> Bool {
        abs(velocity.x) > abs(velocity.y) * 1.2
    }

    /// 根据水平位移或速度返回相邻目标索引。
    ///
    /// 媒体不足两项、没有有效方向或将越过集合边界时返回 `nil`。
    static func targetIndex(
        frontIndex: Int,
        itemCount: Int,
        translationX: CGFloat,
        velocityX: CGFloat
    ) -> Int? {
        guard itemCount > 1 else { return nil }
        let directionalX = abs(translationX) >= 8 ? translationX : velocityX
        guard directionalX != 0 else { return nil }
        let target = frontIndex + (directionalX < 0 ? 1 : -1)
        return (0..<itemCount).contains(target) ? target : nil
    }

    /// 返回已进入换层状态或同向速度是否允许在松手时提交。
    static func shouldCommit(
        translationX: CGFloat,
        velocityX: CGFloat,
        isReordered: Bool
    ) -> Bool {
        let velocityMatchesTranslation = translationX == 0
            || velocityX == 0
            || (translationX < 0) == (velocityX < 0)
        let passedVelocity = abs(velocityX) >= 550 && velocityMatchesTranslation
        return isReordered || passedVelocity
    }

    /// 一次拖动的纯预览状态；开始索引固定，换层不代表已提交封面。
    struct Interaction: Equatable {
        /// 手指开始拖动时已确认的封面索引。
        let startIndex: Int
        /// 手势开始时的媒体数量。
        let itemCount: Int
        /// 手势开始时卡片的实际宽度，单位为点。
        let cardWidth: CGFloat
        /// 相对手势起点的原始水平位移。
        private(set) var translationX: CGFloat = 0
        /// 当前拖动方向的相邻媒体；越界或没有方向时为 `nil`。
        private(set) var candidateIndex: Int?
        /// 候选卡片是否临时盖在原封面上方。
        private(set) var isReordered = false

        /// 根据位移更新候选项和临时层级；换层与恢复共用同一临界值，不使用速度预览换层。
        mutating func update(translationX: CGFloat) {
            self.translationX = translationX
            let candidate = MediaStackPolicy.targetIndex(
                frontIndex: startIndex, itemCount: itemCount,
                translationX: translationX, velocityX: translationX
            )
            candidateIndex = candidate
            guard candidate != nil, cardWidth > 0 else {
                isReordered = false
                return
            }
            isReordered = abs(translationX) >= cardWidth * 0.60
        }

        /// 有效相邻卡片的展开进度；边界阻尼不展开候选卡片。
        var progress: CGFloat {
            guard candidateIndex != nil, cardWidth > 0 else { return 0 }
            return min(1, abs(translationX) / (cardWidth * 0.60))
        }

        /// 实际应用的水平位移；集合首尾将拖动限制在十八点内。
        var displayedTranslationX: CGFloat {
            candidateIndex == nil ? max(-18, min(18, translationX * 0.2)) : translationX
        }

        /// 松手后应提交的相邻索引；仅此方法允许速度参与短甩判定。
        func committedIndex(velocityX: CGFloat) -> Int? {
            guard MediaStackPolicy.shouldCommit(
                translationX: translationX, velocityX: velocityX, isReordered: isReordered
            ) else { return nil }
            return isReordered ? candidateIndex : MediaStackPolicy.targetIndex(
                frontIndex: startIndex, itemCount: itemCount,
                translationX: translationX, velocityX: velocityX
            )
        }
    }
}
