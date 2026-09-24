import AVFAudio
import Foundation

/// 后台准备音频设备；prepareToPlay 和 prepareToRecord 内部也会同步激活会话。
@MainActor
enum AudioPreparation {
    /// 创建并准备播放器，完成前调用方不能访问其状态或启动播放。
    static func player(at url: URL) async throws -> AVAudioPlayer {
        try Task.checkCancellation()
        let prepared = try await AudioSessionOperationQueue.shared.enqueue {
            let player = try AVAudioPlayer(contentsOf: url)
            guard player.prepareToPlay() else { throw CocoaError(.fileReadUnknown) }
            return PreparedAudioResource(player)
        }.value
        return prepared.value
    }

    /// 创建并准备单声道 AAC 录音器，完成后才允许安装代理并开始录音。
    static func recorder(at url: URL) async throws -> AVAudioRecorder {
        try Task.checkCancellation()
        let prepared = try await AudioSessionOperationQueue.shared.enqueue {
            let recorder = try AVAudioRecorder(url: url, settings: [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVSampleRateKey: 44_100,
                AVNumberOfChannelsKey: 1,
                AVEncoderBitRateKey: 96_000,
                AVEncoderAudioQualityKey: AVAudioQuality.high.rawValue,
            ])
            guard recorder.prepareToRecord() else { throw CocoaError(.fileWriteUnknown) }
            return PreparedAudioResource(recorder)
        }.value
        return prepared.value
    }
}

/// 仅用于后台准备完成后的单向所有权交接，不使 AVFAudio 对象获得并发访问能力。
///
/// 对象在后台创建且完成准备后才装入盒子；后台随后不再访问对象，等待结果的
/// MainActor 是唯一使用者。盒子不进入共享存储，也不提供任何后台变更操作。
nonisolated private final class PreparedAudioResource<Value>: @unchecked Sendable {
    /// 已完成准备、等待交给 MainActor 的唯一媒体对象。
    let value: Value
    /// 在后台准备结束时封装媒体对象。
    init(_ value: Value) { self.value = value }
}
