//
//  MediaStrings.swift
//  Demo
//

import Foundation

/// 照片草稿、媒体消息与全屏预览共用的本地化文字。
nonisolated struct MediaStrings: Equatable, Sendable {
    /// 照片选择入口的标题。
    let photo: String
    /// 媒体项目数量的格式字符串，使用整数占位符。
    let itemsFormat: String
    /// 静态图片的辅助功能类型名称。
    let image: String
    /// 动态图像或 Live Photo 的辅助功能类型名称。
    let animatedImage: String
    /// 视频的辅助功能类型名称。
    let video: String
    /// 包含视频时长的格式字符串，使用字符串占位符。
    let videoDurationFormat: String
    /// 媒体导入期间显示或朗读的状态文字。
    let importing: String
    /// 删除媒体草稿操作的标签。
    let remove: String
    /// 播放视频操作的标签。
    let play: String
    /// 打开全屏媒体预览的辅助功能提示。
    let openPreview: String
    /// 关闭全屏预览操作的标签。
    let close: String
    /// 尝试越过媒体集合首项时朗读的提示。
    let firstItem: String
    /// 尝试越过媒体集合末项时朗读的提示。
    let lastItem: String
    /// 媒体当前位置与总数的格式字符串，使用两个整数占位符。
    let positionFormat: String
}
