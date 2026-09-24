//
//  RecordingPolicy.swift
//  Demo
//

import Foundation

/// 生成实时录音面板使用的固定槽位波形。
///
/// 固定槽位可以保证录音开始、采样增长和滚动期间的柱宽不变，避免波形内容变化
/// 被误认为 Composer 胶囊的内边距发生变化。
nonisolated enum RecordingWaveform {
    /// 录音面板固定显示的细柱槽位数量。
    ///
    /// 六十个 2 点柱形与 2 点间距会占用 238 点宽度，对应 iPhone 16 Pro
    /// 设计图中的整行录音波形。
    static let displaySampleCount = 60

    /// 返回包含固定数量槽位的实时波形。
    ///
    /// 最新采样位于语义结束侧；采样不足时从语义起始侧补入最低振幅，超过上限时
    /// 仅保留最新采样。
    ///
    /// - Parameter samples: 按采集顺序排列的归一化音量采样。
    /// - Returns: 始终包含 ``displaySampleCount`` 个元素的波形。
    static func displaySamples(_ samples: [Float]) -> [Float] {
        let visibleSamples = Array(samples.suffix(displaySampleCount))
        let placeholderCount = displaySampleCount - visibleSamples.count
        return Array(repeating: 0.08, count: placeholderCount)
            + visibleSamples
    }
}

/// 定义音频消息录制所使用的时长边界。
nonisolated enum RecordingPolicy {
    /// 允许保留和发送录音的最短时长，单位为秒。
    static let minimumDuration: TimeInterval = 1
    /// 触发自动停止录音的最长时长，单位为秒。
    static let maximumDuration: TimeInterval = 120

    /// 返回录音是否满足预览和发送条件。
    ///
    /// - Parameters:
    ///   - duration: 录音时长，单位为秒。
    ///   - fileExists: 指示编码后的文件是否可用的布尔值。
    /// - Returns: 时长达到最小值且文件可用时为 `true`；否则为 `false`。
    static func accepts(
        duration: TimeInterval,
        fileExists: Bool
    ) -> Bool {
        fileExists && duration >= minimumDuration
    }

    /// 返回是否应在指定的已录制时长停止录音。
    static func shouldStop(elapsed: TimeInterval) -> Bool {
        elapsed >= maximumDuration
    }
}
