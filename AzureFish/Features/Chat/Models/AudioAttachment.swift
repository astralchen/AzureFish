//
//  AudioAttachment.swift
//  Demo
//

import Foundation

/// 本地音频文件及时间线展示所需的元数据。
///
/// 附件不持有播放器或其他 UIKit 对象。页面中的附件文件由页面级存储管理；
/// 草稿存储另持有独立副本，恢复时再复制到新页面。用户录音使用 AAC `.m4a`，模拟语音回复使用本地
/// `.caf` 文件；两种格式使用相同的播放和展示模型。
nonisolated struct AudioAttachment: Codable, Equatable, Hashable, Sendable {
    /// 用于播放和 ListKit 刷新身份的稳定标识符。
    let id: UUID

    /// 包含录音或合成回复的本地可回放音频文件。
    let fileURL: URL

    /// 录音的精确时长，单位为秒。
    let duration: TimeInterval

    /// 位于 `0.08...1.0` 范围内的归一化波形采样。
    let waveform: [Float]

    /// 整段文件识别完成后的文本；未识别或没有有效结果时为 nil。
    var transcript: String?

    /// 使用本地可回放文件创建音频附件。
    ///
    /// - Parameters:
    ///   - id: 附件的稳定标识符。
    ///   - fileURL: 本地音频文件的 URL。
    ///   - duration: 音频时长，单位为秒。
    ///   - waveform: 归一化波形采样。超出支持范围的值会被截断。
    ///   - transcript: 可选的完整识别文本；空白文本按无结果处理。
    init(
        id: UUID = UUID(),
        fileURL: URL,
        duration: TimeInterval,
        waveform: [Float],
        transcript: String? = nil
    ) {
        self.id = id
        self.fileURL = fileURL
        self.duration = duration
        self.waveform = waveform.map { min(1, max(0.08, $0)) }
        let text = transcript?.trimmingCharacters(in: .whitespacesAndNewlines)
        self.transcript = text?.isEmpty == false ? text : nil
    }
}
