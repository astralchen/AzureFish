//
//  AudioController+Playback.swift
//  Demo
//

import AVFAudio
import Foundation
import Speech
import UIKit

/// 管理音频播放与进度发布。
@available(iOS 26.0, *)
extension AudioController {

    /// 切换输入栏预览中附件的播放状态。
    func togglePreviewPlayback() {
        guard case .audioPreview(
            let attachment,
            let isPlaying,
            _
        ) = state else {
            return
        }
        let target = PlaybackTarget.preview(attachment.id)
        if playbackTarget == target, isPlaying || playbackTask.isRunning {
            pausePlayback()
        } else if playbackTarget == target, player != nil {
            resumePlayback()
        } else {
            play(
                attachment,
                target: target
            )
        }
    }

    /// 切换时间线中音频消息的播放状态。
    ///
    /// - Parameters:
    ///   - messageID: 消息的稳定身份。
    ///   - attachment: 要播放的音频附件。
    func toggleMessagePlayback(
        messageID: Int,
        attachment: AudioAttachment
    ) {
        let target = PlaybackTarget.message(
            id: messageID,
            attachmentID: attachment.id
        )
        if playbackTarget == target, player?.isPlaying == true || playbackTask.isRunning {
            pausePlayback()
        } else if playbackTarget == target, player != nil {
            resumePlayback()
        } else {
            play(attachment, target: target)
        }
    }

    /// 停止原播放目标，校验附件文件并开始播放指定草稿或消息。
    ///
    /// 失败时清理播放状态，并通过媒体错误回调通知界面。
    private func play(
        _ attachment: AudioAttachment,
        target: PlaybackTarget
    ) {
        stopPlayback()
        guard fileManager.fileExists(atPath: attachment.fileURL.path) else {
            failureDidOccur?(.playbackFailed)
            return
        }
        playbackTarget = target
        playbackCoordinator.acquire(owner: playbackOwner) { [weak self] in self?.stopAll() }
        playbackTask.run { [weak self] operation in
            guard let self else { return }
            try await configurePlaybackSession()
            try operation.checkCancellation()
            let player = try await AudioPreparation.player(at: attachment.fileURL)
            // 即使准备操作不响应取消，迟到创建的播放器也必须停止。
            do { try operation.checkCancellation() }
            catch { player.stop(); throw error }
            player.delegate = self
            guard player.play() else { throw CocoaError(.fileReadUnknown) }
            self.player = player
            publishPlayback(isPlaying: true, progress: 0)
            try operation.checkCancellation()
            startPlaybackTimer()
        } onError: { [weak self] _ in
            self?.stopPlayback()
            self?.failureDidOccur?(.playbackFailed)
        }
    }

    /// 后台重新准备暂停目标并恢复位置，避免会话停用后 play 内部同步重建音频队列。
    private func resumePlayback() {
        guard let previousPlayer = player, playbackTarget != nil else { return }
        guard validatePlaybackFile(previousPlayer), let url = previousPlayer.url else { return }
        cancelPendingPlayback()
        playbackCoordinator.acquire(owner: playbackOwner) { [weak self] in self?.stopAll() }
        let position = previousPlayer.currentTime
        playbackTask.run { [weak self] operation in
            guard let self else { return }
            try await configurePlaybackSession()
            try operation.checkCancellation()
            let player = try await AudioPreparation.player(at: url)
            do { try operation.checkCancellation() }
            catch { player.stop(); throw error }
            guard self.player === previousPlayer else { player.stop(); return }
            previousPlayer.stop()
            player.delegate = self
            player.currentTime = position
            guard player.play() else { throw CocoaError(.fileReadUnknown) }
            self.player = player
            publishPlayback(isPlaying: true, progress: player.duration > 0 ? player.currentTime / player.duration : 0)
            try operation.checkCancellation()
            startPlaybackTimer()
        } onError: { [weak self] _ in
            self?.stopPlayback()
            self?.failureDidOccur?(.playbackFailed)
        }
    }

    /// 使等待会话的播放任务失效；系统层已入队操作由会话队列负责有序收尾。
    private func cancelPendingPlayback() {
        playbackTask.cancel()
    }

    /// 替换播放计时器，以 50 毫秒间隔在主运行循环发布进度。
    private func startPlaybackTimer() {
        playbackTimer?.invalidate()
        playbackTimer = Timer.scheduledTimer(
            withTimeInterval: 0.05,
            repeats: true
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.samplePlayback()
            }
        }
        RunLoop.main.add(playbackTimer!, forMode: .common)
    }

    /// 校验当前播放文件，并将播放位置归一化到 `0...1` 后发布。
    private func samplePlayback() {
        guard let player else { return }
        guard validatePlaybackFile(player) else { return }
        let progress = player.duration > 0
            ? min(1, max(0, player.currentTime / player.duration))
            : 0
        publishPlayback(isPlaying: player.isPlaying, progress: progress)
    }

    /// 暂停播放器，保留当前播放位置并在无录音占用时释放音频会话。
    func pausePlayback() {
        cancelPendingPlayback()
        playbackTimer?.invalidate()
        playbackTimer = nil
        player?.pause()
        let progress: Double
        if let player, player.duration > 0 {
            progress = min(1, max(0, player.currentTime / player.duration))
        } else {
            progress = 0
        }
        publishPlayback(isPlaying: false, progress: progress)
        finishAudioSession()
    }

    /// 停止并重置当前音频，不取消页面任务、不删除录音草稿或已发送附件。
    func stopPlayback() {
        cancelPendingPlayback()
        playbackTimer?.invalidate()
        playbackTimer = nil
        player?.stop()
        // 切换目标属于停止而非暂停：旧目标的按钮、波形和时间一并归零。
        publishPlayback(isPlaying: false, progress: 0)
        player = nil
        playbackTarget = nil
        playbackState = .idle
        finishAudioSession()
    }

    /// 返回当前播放器引用的文件是否仍可读。
    ///
    /// 文件丢失时停止播放并发布播放失败；无文件 URL 的播放器不在此处判为失败。
    private func validatePlaybackFile(_ player: AVAudioPlayer) -> Bool {
        guard let url = player.url, !fileManager.isReadableFile(atPath: url.path) else { return true }
        stopPlayback()
        failureDidOccur?(.playbackFailed)
        return false
    }

    /// 将播放进度发布到匹配身份的草稿状态或时间线状态。
    func publishPlayback(isPlaying: Bool, progress: Double) {
        switch playbackTarget {
        case .preview(let attachmentID):
            if case .audioPreview(let attachment, _, _) = state,
               attachment.id == attachmentID {
                state = .audioPreview(
                    attachment: attachment,
                    isPlaying: isPlaying,
                    progress: progress
                )
            }
        case .message(let messageID, let attachmentID):
            playbackState = PlaybackState(
                messageID: messageID,
                attachmentID: attachmentID,
                isPlaying: isPlaying,
                progress: progress
            )
        case nil:
            break
        }
    }
}

/// 处理音频解码错误与播放结束的系统代理回调。
@available(iOS 26.0, *)
extension AudioController {
    /// 在音频解码失败时转回主 Actor 清理播放，并报告错误。
    nonisolated func audioPlayerDecodeErrorDidOccur(_ player: AVAudioPlayer, error: (any Error)?) {
        // 仅保留引用用于身份比较，避免对象释放后地址复用；不通过此引用读写播放器状态。
        #if compiler(<6.4)
        nonisolated(unsafe) let player = player
        #endif
        Task { @MainActor [weak self] in
            guard let self, self.player === player else { return }
            self.stopPlayback()
            self.failureDidOccur?(.playbackFailed)
        }
    }

    /// 在播放结束时重置播放状态；非正常结束时报告播放失败。
    nonisolated func audioPlayerDidFinishPlaying(
        _ player: AVAudioPlayer,
        successfully flag: Bool
    ) {
        // 仅保留引用用于身份比较，播放器的所有状态操作仍通过主 Actor 上的 self.player 完成。
        #if compiler(<6.4)
        nonisolated(unsafe) let player = player
        #endif
        Task { @MainActor [weak self] in
            guard let self, self.player === player else { return }
            self.publishPlayback(isPlaying: false, progress: 0)
            self.playbackTimer?.invalidate()
            self.playbackTimer = nil
            self.player = nil
            self.playbackTarget = nil
            self.playbackState = .idle
            self.finishAudioSession()
            if !flag {
                self.failureDidOccur?(.playbackFailed)
            }
        }
    }
}
