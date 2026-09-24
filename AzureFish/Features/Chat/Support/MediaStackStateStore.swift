//
//  MediaStackStateStore.swift
//  Demo
//

import AVKit
import ImageIO
import QuickLayout
import QuickLayoutKit
import UIKit

/// 按消息身份保存媒体堆叠封面位置，使状态跨单元格复用保留的对象。
@MainActor
final class MediaStackStateStore {
    /// 消息标识符到当前封面索引的映射。
    private var indices: [Int: Int] = [:]

    /// 返回指定消息的封面索引，并将结果限制在当前媒体数量内。
    func index(for messageID: Int, itemCount: Int) -> Int {
        guard itemCount > 0 else { return 0 }
        return min(max(0, indices[messageID] ?? 0), itemCount - 1)
    }

    /// 保存经边界修正的封面索引；媒体集合为空时移除记录。
    func setIndex(_ index: Int, for messageID: Int, itemCount: Int) {
        guard itemCount > 0 else {
            indices.removeValue(forKey: messageID)
            return
        }
        indices[messageID] = min(max(0, index), itemCount - 1)
    }

    /// 仅保留仍存在于时间线中的消息封面记录。
    func retainMessages(_ messageIDs: Set<Int>) {
        indices = indices.filter { messageIDs.contains($0.key) }
    }
}
