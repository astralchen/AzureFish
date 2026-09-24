//
//  AudioController+ReplySynthesis.swift
//  Demo
//

import AVFAudio
import Foundation
import Speech
import UIKit

/// 将模拟回复文本生成为可在消息气泡中回放的本地音频附件。
///
/// 实现负责文件创建、波形提取和取消清理。调用方只接收值类型附件，不持有
/// `AVSpeechSynthesizer` 或 `AVAudioFile`。协议引用可传入子任务，所有实现状态仍受主 Actor 保护。
@MainActor
protocol ReplyAudioSynthesizing: AnyObject, Sendable {
    /// 使用指定语言合成一条模拟回复音频。
    ///
    /// - Parameters:
    ///   - text: 已按发送时语言解析的回复文本。
    ///   - locale: 决定系统声线的语音处理区域设置。
    /// - Returns: 位于页面临时目录内的可回放音频附件。
    func synthesizeReplyAudio(
        text: String,
        locale: Locale
    ) async throws -> AudioAttachment
}

/// 文本转音频回复在生成本地附件时可能产生的错误。
nonisolated enum ReplyAudioSynthesisError: Error, Equatable {
    /// 输入文本移除首尾空白后为空。
    case emptyText

    /// 当前系统没有与目标语言匹配的可用声线。
    case voiceUnavailable

    /// 系统没有返回可写入且具有有效时长的 PCM 缓冲区。
    case invalidBuffer

    /// 临时音频文件无法创建、写入或重新打开校验。
    case fileWriteFailed
}

/// 将非 Sendable 的音频回调缓冲区安全转交给主 Actor。
///
/// `AVSpeechSynthesizer` 的回调队列不属于页面状态机；包装对象只负责跨越任务
/// 边界，缓冲区仍只会在主 Actor 上读取。
private final class ReplyAudioBufferBox: @unchecked Sendable {
    /// 从语音合成回调转交给主 Actor 读取的缓冲区。
    let buffer: AVAudioBuffer

    /// 持有指定音频缓冲区，以便跨任务边界传递。
    init(_ buffer: AVAudioBuffer) {
        self.buffer = buffer
    }
}

/// 保存单次文本转音频操作的文件写入状态。
nonisolated final class ReplyAudioSynthesisContext {
    /// 标识单次合成操作的令牌，用于拒绝过期缓冲区回调。
    let generation: UUID
    /// 本次合成操作写入的本地音频文件 URL。
    let fileURL: URL
    /// 用于创建输出音频文件的格式设置。
    let fileSettings: [String: Any]
    /// 等待附件合成结果的延续；操作结束后清空并恢复一次。
    var continuation: CheckedContinuation<
        AudioAttachment,
        any Error
    >?
    /// 正在写入的音频文件；关闭后才能重新打开校验。
    var audioFile: AVAudioFile?
    /// 已写入缓冲区的累计时长，单位为秒。
    var duration: TimeInterval = 0
    /// 按写入顺序收集的归一化波形采样。
    var waveformSamples: [Float] = []

    /// 创建单次合成的资源上下文，记录操作身份、输出设置和等待结果的延续。
    init(
        generation: UUID,
        fileURL: URL,
        fileSettings: [String: Any],
        continuation: CheckedContinuation<
            AudioAttachment,
            any Error
        >
    ) {
        self.generation = generation
        self.fileURL = fileURL
        self.fileSettings = fileSettings
        self.continuation = continuation
    }
}

/// 提供将模拟回复文本合成为本地音频附件的实现。
@available(iOS 26.0, *)
extension AudioController: ReplyAudioSynthesizing {

    /// 使用系统声线把本地化回复文本写入页面临时音频文件。
    ///
    /// 此方法只生成文件，不通过扬声器朗读，也不会激活页面的录音或播放音频
    /// 会话。任务取消时会停止当前合成并删除尚未完成的文件。
    ///
    /// - Parameters:
    ///   - text: 已按发送时应用语言解析的回复文本。
    ///   - locale: 用于选择系统声线的语音处理区域设置。
    /// - Returns: 包含精确时长和固定槽位波形的本地音频附件。
    func synthesizeReplyAudio(
        text: String,
        locale: Locale
    ) async throws -> AudioAttachment {
        let trimmedText = text.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        guard !trimmedText.isEmpty else {
            throw ReplyAudioSynthesisError.emptyText
        }
        guard let voice = AVSpeechSynthesisVoice(
            language: SpeechConfiguration.speechVoiceLanguage(
                for: locale
            )
        ) else {
            throw ReplyAudioSynthesisError.voiceUnavailable
        }

        cancelReplyAudioSynthesis()
        try Task.checkCancellation()

        let generation = UUID()
        let fileURL = attachmentStore.makeFileURL(
            prefix: "reply-\(generation.uuidString)",
            pathExtension: "caf"
        )
        let utterance = AVSpeechUtterance(string: trimmedText)
        utterance.voice = voice
        let synthesizer = AVSpeechSynthesizer()
        replyAudioSynthesizer = synthesizer

        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                let context = ReplyAudioSynthesisContext(
                    generation: generation,
                    fileURL: fileURL,
                    fileSettings: voice.audioFileSettings,
                    continuation: continuation
                )
                replyAudioSynthesisContext = context
                synthesizer.write(utterance) { [weak self] buffer in
                    let bufferBox = ReplyAudioBufferBox(buffer)
                    Task { @MainActor [weak self, bufferBox] in
                        self?.consumeReplyAudioBuffer(
                            bufferBox.buffer,
                            generation: generation
                        )
                    }
                }
                if Task.isCancelled {
                    cancelReplyAudioSynthesis(generation: generation)
                }
            }
        } onCancel: {
            Task { @MainActor [weak self] in
                self?.cancelReplyAudioSynthesis(generation: generation)
            }
        }
    }

    /// 接收系统合成缓冲区并写入当前回复文件。
    ///
    /// 零帧缓冲区表示本次合成结束。迟到或属于已取消代次的缓冲区会被忽略。
    private func consumeReplyAudioBuffer(
        _ buffer: AVAudioBuffer,
        generation: UUID
    ) {
        guard let context = replyAudioSynthesisContext,
              context.generation == generation else {
            return
        }
        guard let pcmBuffer = buffer as? AVAudioPCMBuffer else {
            finishReplyAudioSynthesis(
                generation: generation,
                result: .failure(
                    ReplyAudioSynthesisError.invalidBuffer
                )
            )
            return
        }

        guard pcmBuffer.frameLength > 0 else {
            completeReplyAudioSynthesis(generation: generation)
            return
        }

        do {
            if context.audioFile == nil {
                context.audioFile = try AVAudioFile(
                    forWriting: context.fileURL,
                    settings: context.fileSettings
                )
            }
            try context.audioFile?.write(from: pcmBuffer)
            let sampleRate = pcmBuffer.format.sampleRate
            guard sampleRate > 0 else {
                throw ReplyAudioSynthesisError.invalidBuffer
            }
            context.duration += TimeInterval(pcmBuffer.frameLength)
                / sampleRate
            context.waveformSamples.append(
                contentsOf: Self.replyWaveformSamples(from: pcmBuffer)
            )
        } catch {
            finishReplyAudioSynthesis(
                generation: generation,
                result: .failure(
                    ReplyAudioSynthesisError.fileWriteFailed
                )
            )
        }
    }

    /// 校验已写入的回复文件并生成音频附件。
    private func completeReplyAudioSynthesis(generation: UUID) {
        guard let context = replyAudioSynthesisContext,
              context.generation == generation else {
            return
        }
        context.audioFile = nil
        do {
            let audioFile = try AVAudioFile(forReading: context.fileURL)
            guard audioFile.length > 0, context.duration > 0 else {
                throw ReplyAudioSynthesisError.invalidBuffer
            }
            let attachment = AudioAttachment(
                fileURL: context.fileURL,
                duration: context.duration,
                waveform: Self.condensedWaveform(
                    context.waveformSamples,
                    count: 36
                )
            )
            attachmentStore.registerCommitted(.audio(attachment))
            finishReplyAudioSynthesis(
                generation: generation,
                result: .success(attachment)
            )
        } catch {
            finishReplyAudioSynthesis(
                generation: generation,
                result: .failure(
                    ReplyAudioSynthesisError.fileWriteFailed
                )
            )
        }
    }

    /// 结束当前合成并仅恢复一次等待中的 continuation。
    private func finishReplyAudioSynthesis(
        generation: UUID,
        result: Result<AudioAttachment, any Error>
    ) {
        guard let context = replyAudioSynthesisContext,
              context.generation == generation else {
            return
        }
        replyAudioSynthesisContext = nil
        replyAudioSynthesizer = nil
        context.audioFile = nil
        let continuation = context.continuation
        context.continuation = nil

        if case .failure = result {
            attachmentStore.removeFile(at: context.fileURL)
        }
        continuation?.resume(with: result)
    }

    /// 取消正在生成的回复音频并删除部分文件。
    func cancelReplyAudioSynthesis() {
        let context = replyAudioSynthesisContext
        replyAudioSynthesisContext = nil
        let synthesizer = replyAudioSynthesizer
        replyAudioSynthesizer = nil
        let continuation = context?.continuation
        context?.continuation = nil
        context?.audioFile = nil

        synthesizer?.stopSpeaking(at: .immediate)
        if let fileURL = context?.fileURL {
            attachmentStore.removeFile(at: fileURL)
        }
        continuation?.resume(throwing: CancellationError())
    }

    /// 取消指定代次的回复音频生成。
    ///
    /// 旧任务的取消处理可能晚于下一次合成回到主 Actor。只有当前上下文仍属于
    /// 指定代次时才执行取消，避免旧任务误删新回复的临时文件。
    ///
    /// - Parameter generation: 发起合成时创建的稳定代次标识。
    func cancelReplyAudioSynthesis(generation: UUID) {
        guard replyAudioSynthesisContext?.generation == generation else {
            return
        }
        cancelReplyAudioSynthesis()
    }

    /// 从合成 PCM 缓冲区提取用于消息气泡的振幅采样。
    static func replyWaveformSamples(
        from buffer: AVAudioPCMBuffer
    ) -> [Float] {
        guard let channelData = buffer.floatChannelData else { return [] }
        let frameCount = Int(buffer.frameLength)
        let channelCount = Int(buffer.format.channelCount)
        guard frameCount > 0, channelCount > 0 else { return [] }

        let bucketSize = 256
        var samples: [Float] = []
        var start = 0
        while start < frameCount {
            let end = min(frameCount, start + bucketSize)
            var peak: Float = 0
            for channel in 0..<channelCount {
                for frame in start..<end {
                    peak = max(peak, abs(channelData[channel][frame]))
                }
            }
            samples.append(min(1, max(0.08, sqrt(peak))))
            start = end
        }
        return samples
    }
}
