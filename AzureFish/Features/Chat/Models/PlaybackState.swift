//
//  PlaybackState.swift
//  Demo
//

import Foundation

/// 所有可见及可复用音频消息 Cell 共享的播放状态。
nonisolated struct PlaybackState: Equatable, Sendable {
    /// 当前与播放器关联的消息；没有关联消息时为 `nil`。
    let messageID: Int?

    /// 当前与播放器关联的附件；没有关联附件时为 `nil`。
    let attachmentID: UUID?

    /// 指示音频当前是否正在播放的布尔值。
    let isPlaying: Bool

    /// 位于 `0...1` 范围内的归一化播放位置。
    let progress: Double

    /// 没有关联消息、没有播放且进度为零的初始状态。
    static let idle = PlaybackState(
        messageID: nil,
        attachmentID: nil,
        isPlaying: false,
        progress: 0
    )
}
