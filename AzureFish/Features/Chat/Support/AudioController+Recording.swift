//
//  AudioController+Recording.swift
//  Demo
//

import AVFAudio
import Foundation
import Speech
import UIKit

/// 管理录音、波形采样与草稿交付。
@available(iOS 26.0, *)
extension AudioController {

    /// 恢复已结束录音的预览，不激活音频会话或开始播放。
    ///
    /// 用于新页面批量恢复草稿，预览暂停且进度归零，不恢复录音或麦克风会话。
    /// - Parameter attachment: 文件已复制到页面存储目录的有效语音附件，保留原身份、时长及波形。
    func restoreDraft(_ attachment: AudioAttachment) {
        attachmentStore.registerDraft(.audio(attachment))
        state = .audioPreview(attachment: attachment, isPlaying: false, progress: 0)
    }

    /// 请求麦克风访问权限并开始录制音频消息。
    func startRecording() {
        guard state == .idle else { return }
        stopPlayback()
        playbackCoordinator.acquire(owner: playbackOwner) { [weak self] in self?.stopAll() }
        operationTask?.cancel()
        operationTask = Task { [weak self] in
            guard let self else { return }
            let microphoneGranted = await permissionProvider.requestMicrophonePermission()
            guard !Task.isCancelled else { return }
            guard microphoneGranted else {
                operationTask = nil
                finishAudioSession()
                failureDidOccur?(.microphonePermissionDenied)
                return
            }
            guard !Task.isCancelled else { return }
            do {
                try await configureCaptureSession()
                try Task.checkCancellation()
                try await beginRecording()
                operationTask = nil
            } catch {
                guard !Task.isCancelled else { return }
                operationTask = nil
                finishAudioSession()
                if !(error is CancellationError) { failureDidOccur?(.recordingFailed) }
            }
        }
    }

    /// 停止录音并生成预览；会话尚在准备时取消启动，不等待麦克风真正开始。
    func stopRecording() {
        guard recorder != nil else {
            if state == .idle {
                operationTask?.cancel()
                operationTask = nil
                finishAudioSession()
            }
            return
        }
        finishRecording(keepValidRecording: true)
    }

    /// 取消当前录音或预览，并删除其本地文件。
    func cancelRecordingOrPreview() {
        operationTask?.cancel()
        operationTask = nil
        speechTranscriber.stop()
        if recorder != nil {
            finishRecording(keepValidRecording: false)
        }
        if case .audioPreview(let attachment, _, _) = state {
            stopPlayback()
            attachmentStore.discardDraft(id: attachment.id)
        }
        state = .idle
        finishAudioSession()
    }

    /// 交出未提交文件；接收方必须立即在同一页面存储中登记文件附件。
    /// 停止播放器但不删除文件，之后的录音回调不能再持有该草稿。
    func takePreviewForFileAttachment() -> AudioAttachment? {
        guard case .audioPreview(let attachment, _, _) = state else { return nil }
        stopPlayback()
        state = .idle
        finishAudioSession()
        return attachment
    }

    /// 当前音频预览所表示的页面附件。
    ///
    /// 读取不会改变预览状态。调用方应先让 ViewModel 接受附件，再调用
    /// ``commitPreviewAttachment(id:)``，保证发送失败时草稿仍可重试或取消。
    var previewAttachment: Attachment? {
        guard case .audioPreview(let attachment, _, _) = state else {
            return nil
        }
        return .audio(attachment)
    }

    /// 提交已经成功进入消息时间线的音频预览。
    ///
    /// - Parameter id: ViewModel 已接受附件的稳定标识符。
    /// - Returns: 当前预览与标识符一致且成功提交时为 `true`。
    @discardableResult
    func commitPreviewAttachment(id: UUID) -> Bool {
        guard case .audioPreview(let attachment, _, _) = state,
              attachment.id == id else {
            return false
        }
        if !attachmentStore.commitDraft(id: id) {
            // 状态中的有效附件已经被 ViewModel 接受。即使测试替身或恢复流程
            // 没有保留草稿登记，也要把文件转为页面已提交所有权，避免消息存在
            // 但预览无法退出。
            attachmentStore.registerCommitted(.audio(attachment))
        }
        stopPlayback()
        state = .idle
        finishAudioSession()
        return true
    }

    /// 创建单声道 AAC 录音文件，并以 50 毫秒间隔采样音量。
    ///
    /// 录音器无法准备或启动时抛出错误，交由调用方恢复状态。
    private func beginRecording() async throws {
        let url = attachmentStore.makeFileURL(
            prefix: "audio",
            pathExtension: "m4a"
        )
        let generation = audioSessionGeneration
        let recorder: AVAudioRecorder
        do {
            recorder = try await AudioPreparation.recorder(at: url)
            guard !Task.isCancelled, audioSessionGeneration == generation else {
                recorder.stop()
                throw CancellationError()
            }
            recorder.delegate = self
            recorder.isMeteringEnabled = true
            guard recorder.record() else { throw CocoaError(.fileWriteUnknown) }
        } catch {
            try? fileManager.removeItem(at: url)
            throw error
        }
        self.recorder = recorder
        recordingURL = url
        recordingSamples = []
        state = .recording(
            elapsed: 0,
            waveform: RecordingWaveform.displaySamples([])
        )
        recordingTimer = Timer.scheduledTimer(
            withTimeInterval: 0.05,
            repeats: true
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.sampleRecording()
            }
        }
        RunLoop.main.add(recordingTimer!, forMode: .common)
    }

    /// 读取当前录音时长和音量，并在达到最长时限时保留有效录音。
    private func sampleRecording() {
        guard let recorder else { return }
        recorder.updateMeters()
        let normalized = Self.normalizedPower(
            recorder.averagePower(forChannel: 0)
        )
        recordingSamples.append(normalized)
        let elapsed = recorder.currentTime
        state = .recording(
            elapsed: elapsed,
            waveform: RecordingWaveform.displaySamples(
                recordingSamples
            )
        )
        if RecordingPolicy.shouldStop(elapsed: elapsed) {
            finishRecording(keepValidRecording: true)
        }
    }

    /// 停止录音，并根据保留策略提交草稿预览或删除临时文件。
    ///
    /// - Parameter keepValidRecording: 是否保留达到最短时长的有效文件；为 `false` 时直接丢弃。
    func finishRecording(keepValidRecording: Bool) {
        recordingTimer?.invalidate()
        recordingTimer = nil
        guard let recorder else { return }
        let duration = recorder.currentTime
        let url = recordingURL ?? recorder.url
        self.recorder = nil
        recordingURL = nil
        recorder.stop()

        guard keepValidRecording,
              RecordingPolicy.accepts(
                  duration: duration,
                  fileExists: fileManager.fileExists(atPath: url.path)
              )
        else {
            try? fileManager.removeItem(at: url)
            state = .idle
            finishAudioSession()
            if keepValidRecording {
                failureDidOccur?(.recordingTooShort)
            }
            return
        }

        let attachment = AudioAttachment(
            fileURL: url,
            duration: duration,
            waveform: Self.condensedWaveform(recordingSamples, count: 36)
        )
        attachmentStore.registerDraft(.audio(attachment))
        recordingSamples = []
        state = .audioPreview(
            attachment: attachment,
            isPlaying: false,
            progress: 0
        )
        finishAudioSession()
    }

    /// 将分贝功率转换为 `0.08...1` 范围的波形振幅；非有限值使用最小振幅。
    private static func normalizedPower(_ power: Float) -> Float {
        guard power.isFinite else { return 0.08 }
        return min(1, max(0.08, pow(10, power / 40)))
    }

    /// 按分桶峰值压缩波形到指定采样数，并用最小振幅补足槽位。
    ///
    /// 原始采样为空或目标数量无效时返回默认占位波形。
    static func condensedWaveform(
        _ samples: [Float],
        count: Int
    ) -> [Float] {
        guard !samples.isEmpty, count > 0 else { return placeholderWaveform }
        let bucketSize = max(1, Int(ceil(Double(samples.count) / Double(count))))
        var result: [Float] = []
        var index = 0
        while index < samples.count {
            let end = min(samples.count, index + bucketSize)
            result.append(samples[index..<end].max() ?? 0.08)
            index = end
        }
        if result.count < count {
            result.append(contentsOf: repeatElement(0.08, count: count - result.count))
        }
        return Array(result.prefix(count))
    }
}

/// 处理录音编码失败，并将系统回调转交主 Actor。
@available(iOS 26.0, *)
extension AudioController {
    /// 在录音编码失败时停止当前操作并发布录音失败状态。
    nonisolated func audioRecorderEncodeErrorDidOccur(
        _ recorder: AVAudioRecorder,
        error: (any Error)?
    ) {
        Task { @MainActor [weak self] in
            guard let self, self.recorder === recorder else { return }
            self.finishRecording(keepValidRecording: false)
            self.failureDidOccur?(.recordingFailed)
        }
    }
}
